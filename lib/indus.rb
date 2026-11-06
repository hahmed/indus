# Indus: Ruby -> SSA -> arm64. No C, no LLVM, no assembler, no linker.
#
#   lib/indus/ir.rb       SSA values, blocks, functions, classes
#   lib/indus/pretype.rb  coarse kinds over the AST, before lowering (receiver kinds for blocks/send)
#   lib/indus/lower.rb    Prism AST -> SSA
#   lib/indus/types.rb    type inference (int/float/arrays/classes/poly), conversions
#   lib/indus/passes.rb   SSA passes (trivial phis, return sinking, accumulator loops)
#   lib/indus/peephole.rb string peepholes (byte compare, in-place append)
#   lib/indus/escape.rb   escape analysis -> stack objects, loop regions
#   lib/indus/gc.rb       the collector's compile-time half: type descriptors, frame maps
#   lib/indus/rt/         what rides into every binary: runtime.s (primitives, assembled
#                         once by tools/build-rt into blob.rb) and the Ruby preludes
#                         gc.rb (the collector), core.rb (String/dyn helpers), grisu.rb
#   lib/indus/asm.rb      arm64 encoder
#   lib/indus/regalloc.rb linear-scan register allocation over dataflow liveness
#   lib/indus/codegen.rb  layout, frames, instruction selection
#   lib/indus/metal.rb    run in-process; hosts the resident compiler for seams
#   lib/indus/macho.rb    standalone Mach-O writer
#   lib/indus/elf.rb      standalone Linux ELF writer
#
# test/check    every test/programs/*.rb and bench/*.rb prints what CRuby prints
# tools/sieve   pour programs through; see what compiles and what blocks the rest
# See experiments/ for how it got here.
gem "prism", "= 1.8.2" rescue nil
require "prism"
require "fiddle"
%w[ir regex pretype lower types ranges passes peephole escape gc magic rt/blob asm regalloc codegen metal macho elf].each { require_relative "indus/#{_1}" }

module Indus
  # everything a compiled program knows about itself: enough for the
  # resident compiler to add to it later
  Unit = Struct.new(:code, :asm, :lower, :funcs) do
    def seams = asm.seams
    def globals = asm.globals
    def label(n) = asm.labels.fetch(n)
  end

  # standalone: nil (run in-process via libc write), :darwin or :linux
  PRELUDE_GC = File.read(File.join(__dir__, "indus/rt/gc.rb"))
  PRELUDE_CORE = %w[grisu core big format enum libm regex].map { File.read(File.join(__dir__, "indus/rt/#{_1}.rb")) }.join("\n")

  # require_relative "x" / require "./x" splice the file in, once, where the call is (a
  # program is one compilation unit). require of a library name: a few are built in (set is
  # a prelude class; json/time... are not), the rest refuse with the name.
  BUILTIN_LIBS = %w[set].freeze
  def self.expand_requires(src, dir, seen = {})
    src.gsub(/^[ \t]*require(_relative)?[ (]\s*["']([^"']+)["']\)?[ \t]*$/) do
      rel, name = $1, $2
      if !rel && !name.start_with?(".", "/")
        next "" if BUILTIN_LIBS.include?(name)
        raise "require '#{name}': only files (require_relative) and #{BUILTIN_LIBS.join(', ')} are available; no load path"
      end
      path = File.expand_path(name.end_with?(".rb") ? name : "#{name}.rb", dir)
      raise "#{rel ? 'require_relative' : 'require'} '#{name}': no such file #{path}" unless File.exist?(path)
      next "" if seen[path]
      seen[path] = true
      "# -- #{path}\n" + expand_requires(File.read(path), File.dirname(path), seen) + "\n"
    end
  end

  def self.compile(src, standalone: nil, file: nil)
    src = expand_requires(src, file ? File.dirname(File.expand_path(file)) : Dir.pwd)
    src = PRELUDE_CORE + "\n" + src          # Float#to_s and friends, in Ruby
    src = PRELUDE_GC + "\n" + src if GC.enabled? # the collector rides along as Ruby
    Types.reset!
    lower = Lower.new(src)
    funcs = lower.run
    funcs.each { Passes.trivial_phis(_1) } # dead statement-valued phis would confuse typing
    Types.standalone = standalone
    Types.run(funcs, lower.classes, lower)
    funcs = Passes.prune(funcs)
    funcs.each { Passes.run(_1) unless ENV["NOPASS"] }
    funcs.each { Peephole.run(_1) unless ENV["NOPEEP"] }
    funcs.each { Ranges.run(_1) unless ENV["NORANGES"] } # overflow checks that cannot fire
    GC.mark_allocators(funcs)
    Escape.run(funcs, lower.classes) unless ENV["NOESCAPE"]
    $stderr.puts funcs.map(&:dump) if ENV["DUMP"]
    asm = Asm.new
    asm.gc_table = GC::Table.new(lower.classes)
    asm.write_addr = Metal::LIBC["write"].to_i unless standalone
    (asm.mmap_addr = Metal::LIBC["mmap"].to_i; asm.munmap_addr = Metal::LIBC["munmap"].to_i) unless standalone
    asm.libm = %i[sin cos pow cbrt hypot log2 log10 log exp atan2 atan tan asin acos clock_gettime open creat read write close unlink exit].to_h { [_1, Metal::LIBC[_1.to_s].to_i] } unless standalone
    asm.os = standalone
    asm.emit_start_linux if standalone == :linux
    funcs.each { Codegen.new(asm, lower.classes).func(_1) }
    asm.emit_runtime_blob
    asm.emit_overflow_trap
    asm.emit_gc_tables if GC.enabled?
    asm.emit_syscalls(standalone || :darwin) # write/mmap entry points exist in-process too
    raise "this program has a seam (class_eval); a standalone binary needs the resident compiler" if standalone && !asm.seams.empty?
    Unit.new(asm.resolve!, asm, lower, funcs)
  end

  def self.diff_tables((iv0, c0), (iv1, c1))
    out = []
    iv1.each { |k, h| h.each { |ix, t| out << "#{k} ivar #{ix}: #{iv0.dig(k, ix).inspect} -> #{t.inspect}" if iv0.dig(k, ix) != t } }
    c1.each { |k, t| out << "#{k}: #{c0[k].inspect} -> #{t.inspect}" if c0[k] != t }
    out.join(", ")
  end

  # The resident compiler: compile one redefined method against the running
  # program's types, place it in new executable memory, return its address.
  # Calls out of the new code go through absolute addresses into the old.
  def self.compile_method(unit, base, klass, src)
    d = Prism.parse(src).value.statements.body.grep(Prism::DefNode).first
    old = klass.find_method(d.name)
    f = unit.lower.lower_method(klass, d, old)
    Passes.trivial_phis(f)
    before = Types.snapshot
    Types.run([f], unit.lower.classes)
    after = Types.snapshot
    if before != after # world-age, type edition: dependents would need recompiling
      raise "redefinition of #{klass.name}##{d.name} changes a type the program was compiled against (#{diff_tables(before, after)}); not supported yet"
    end
    Passes.run(f)
    Peephole.run(f) unless ENV["NOPEEP"]
    GC.mark_allocators(unit.funcs + [f])
    Escape.run([f], unit.lower.classes) unless ENV["NOESCAPE"]
    raise "redefinition changed #{f.name}'s signature" unless f.ptypes == old.ptypes && f.rtype == old.rtype
    asm = Asm.new
    asm.gc_table = unit.asm.gc_table
    asm.write_addr = Metal::LIBC["write"].to_i
    asm.externs = unit.asm.labels.transform_values { base + _1 * 4 }
    asm.instance_variable_set(:@globals, unit.globals) # same slots
    f.name = :"#{old.name}@#{unit.seams.size}" # fresh label
    asm.label(:__text_base)
    Codegen.new(asm, unit.lower.classes).func(f)
    asm.emit_overflow_trap            # checked arithmetic branches here (b.vs is pc-relative: per unit)
    asm.emit_gc_tables if GC.enabled? # this unit's frame maps, with the (grown) type table
    code = asm.resolve!
    [code, asm.labels.fetch(f.name) * 4, f, GC.enabled? ? asm.labels.fetch(:__gc_tables) * 4 : nil]
  end
end
