# Indus: Ruby -> SSA -> arm64. No C, no LLVM, no assembler, no linker.
#
#   lib/indus/ir.rb       SSA values, blocks, functions, classes
#   lib/indus/lower.rb    Prism AST -> SSA
#   lib/indus/types.rb    type inference (int/float/arrays/classes/poly), conversions
#   lib/indus/passes.rb   SSA passes (trivial phis, return sinking, accumulator loops)
#   lib/indus/peephole.rb string peepholes (byte compare, in-place append)
#   lib/indus/escape.rb   escape analysis -> stack objects, loop regions
#   lib/indus/runtime.s   runtime routines in assembly -> runtime_blob.rb (tools/build_runtime.sh)
#   lib/indus/asm.rb      arm64 encoder
#   lib/indus/regalloc.rb linear-scan register allocation over dataflow liveness
#   lib/indus/codegen.rb  layout, frames, instruction selection
#   lib/indus/metal.rb    run in-process; hosts the resident compiler for seams
#   lib/indus/macho.rb    standalone Mach-O writer
#   lib/indus/elf.rb      standalone Linux ELF writer
#
# See experiments/ for how it got here.
gem "prism", "= 1.8.2" rescue nil
require "prism"
require "fiddle"
%w[ir lower types passes peephole escape gc runtime_blob asm regalloc codegen metal macho elf].each { require_relative "indus/#{_1}" }

module Indus
  # everything a compiled program knows about itself: enough for the
  # resident compiler to add to it later
  Unit = Struct.new(:code, :asm, :lower, :funcs) do
    def seams = asm.seams
    def globals = asm.globals
    def label(n) = asm.labels.fetch(n)
  end

  # standalone: nil (run in-process via libc write), :darwin or :linux
  PRELUDE_GC = File.read(File.join(__dir__, "indus/prelude/gc.rb"))

  def self.compile(src, standalone: nil)
    src = PRELUDE_GC + "\n" + src if GC.enabled? # the collector rides along as Ruby
    lower = Lower.new(src)
    funcs = lower.run
    funcs.each { Passes.trivial_phis(_1) } # dead statement-valued phis would confuse typing
    Types.run(funcs, lower.classes, lower)
    funcs.each { Passes.run(_1) unless ENV["NOPASS"] }
    funcs.each { Peephole.run(_1) unless ENV["NOPEEP"] }
    Escape.run(funcs, lower.classes) unless ENV["NOESCAPE"]
    GC.mark_allocators(funcs) if GC.enabled?
    $stderr.puts funcs.map(&:dump) if ENV["DUMP"]
    asm = Asm.new
    asm.gc_table = GC::Table.new(lower.classes)
    asm.write_addr = Metal::LIBC["write"].to_i unless standalone
    asm.libm = %i[sin cos pow].to_h { [_1, Metal::LIBC[_1.to_s].to_i] } unless standalone
    asm.emit_start_linux if standalone == :linux
    funcs.each { Codegen.new(asm, lower.classes).func(_1) }
    asm.emit_runtime_blob
    asm.emit_gc_tables if GC.enabled?
    asm.emit_syscalls(standalone) if standalone
    raise "this program has a seam (class_eval); a standalone binary needs the resident compiler" if standalone && !asm.seams.empty?
    Unit.new(asm.resolve!, asm, lower, funcs)
  end

  # The resident compiler: compile one redefined method against the running
  # program's types, place it in new executable memory, return its address.
  # Calls out of the new code go through absolute addresses into the old.
  def self.compile_method(unit, base, klass, src)
    d = Prism.parse(src).value.statements.body.grep(Prism::DefNode).first
    old = klass.find_method(d.name)
    f = unit.lower.lower_method(klass, d, old)
    Types.run([f], unit.lower.classes)
    Passes.run(f)
    raise "redefinition changed #{f.name}'s signature" unless f.ptypes == old.ptypes && f.rtype == old.rtype
    asm = Asm.new
    asm.gc_table = unit.asm.gc_table
    asm.write_addr = Metal::LIBC["write"].to_i
    asm.externs = unit.asm.labels.transform_values { base + _1 * 4 }
    asm.instance_variable_set(:@globals, unit.globals) # same slots
    f.name = :"#{old.name}@#{unit.seams.size}" # fresh label
    Codegen.new(asm, unit.lower.classes).func(f)
    code = asm.resolve!
    [code, asm.labels.fetch(f.name) * 4, f]
  end
end
