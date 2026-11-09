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
  BUILTIN_LIBS = %w[set].freeze # the prelude's own versions
  # `require "x"` resolves like CRuby: the prelude's builtins, then the pure-Ruby standard library
  # (RbConfig's rubylibdir) and $LOAD_PATH entries (INDUS_LOAD_PATH, colon-separated). The library
  # is compiled as user code: the compiler takes it or refuses at a line.
  def self.load_path
    @load_path ||= begin
      require "rbconfig"
      gems = Dir[File.join(Gem.default_dir, "gems", "*", "lib")].sort # the bundled gems' pure-Ruby parts (abbrev, benchmark, ostruct, erb, ...)
      # lib/indus/stdlib first: Indus's own versions of files CRuby generates or implements in C (rbconfig, ...)
      (ENV["INDUS_LOAD_PATH"].to_s.split(":") + [File.join(__dir__, "indus", "stdlib"), RbConfig::CONFIG["rubylibdir"], *gems]).reject(&:empty?)
    end
  end
  def self.expand_requires(src, dir, seen = {})
    src.gsub(/^[ \t]*require(_relative)?[ (]\s*["']([^"']+)["']\)?[ \t]*(?:#.*)?$/) do
      rel, name = $1, $2
      if !rel && !name.start_with?(".", "/")
        next "" if BUILTIN_LIBS.include?(name)
        found = load_path.map { |d| File.join(d, name.end_with?(".rb") ? name : "#{name}.rb") }.find { File.exist?(_1) }
        raise "require '#{name}': not found in the prelude or on the load path (#{load_path.join(':')}); C extensions are not available" unless found
        next "" if seen[found]
        seen[found] = true
        next "# -- #{found}\n" + expand_requires(File.read(found), File.dirname(found), seen) + "\n"
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
    funcs.each { Codegen.new(asm, lower.classes, funcs).func(_1) }
    asm.emit_runtime_blob
    asm.emit_overflow_trap
    asm.emit_gc_tables if GC.enabled?
    asm.emit_syscalls(standalone || :darwin) # write/mmap entry points exist in-process too
    raise "this program has a seam (class_eval); a standalone binary needs the resident compiler" if standalone && !asm.seams.empty?
    Unit.new(asm.resolve!, asm, lower, funcs)
  end

  def self.ivars_in(node, out = [])
    return out unless node.is_a?(Prism::Node)
    out << node.name if node.is_a?(Prism::InstanceVariableReadNode) || node.is_a?(Prism::InstanceVariableWriteNode) || node.is_a?(Prism::InstanceVariableOrWriteNode) || node.is_a?(Prism::InstanceVariableOperatorWriteNode) || node.is_a?(Prism::InstanceVariableAndWriteNode)
    node.compact_child_nodes.each { ivars_in(_1, out) }
    out.uniq
  end

  def self.diff_tables((iv0, c0), (iv1, c1), typed_only = false)
    out = []
    iv1.each { |k, h| h.each { |ix, t| out << "#{k} ivar #{ix}: #{iv0.dig(k, ix).inspect} -> #{t.inspect}" if iv0.dig(k, ix) != t && !(typed_only && iv0.dig(k, ix).nil?) } }
    c1.each { |k, t| out << "#{k}: #{c0[k].inspect} -> #{t.inspect}" if c0[k] != t && !(typed_only && c0[k].nil?) }
    out.join(", ")
  end

  # The resident compiler: compile one redefined method against the running
  # program's types, place it in new executable memory, return its address.
  # Calls out of the new code go through absolute addresses into the old.
  def self.compile_method(unit, base, klass, d)
    old = klass.find_method(d.name) or raise "class_eval at run time: #{klass.name}##{d.name} is new; only a method the program already has can be redefined (nothing could call a new one)"
    old = old.primary || old
    ivars_in(d).each { |iv| klass.claim_spare(iv) unless klass.ivars.include?(iv) } # a new ivar: a spare slot
    f = unit.lower.lower_method(klass, d, old)
    Passes.trivial_phis(f)
    # library functions the new code needs that the program never did: compiled into the same blob (typed already; pruned before)
    callees = ->(g) { g.all.flat_map { |i| i.op == :call || i.op == :zcheck ? [i.args[0]] : i.op == :pcall || i.op == :sendsw ? i.args[0].filter_map { _2 == :call ? _3 : nil } : i.op == :dsend ? i.args.grep(Func) : [] }.uniq }
    # typing turns method calls into library calls, which may need further library functions: to a fixpoint
    extra = []
    before = Types.snapshot
    loop do
      Types.run([f, *extra], unit.lower.classes)
    if f.rtype == :dyn && old.rtype != :dyn # the callers expect the old return type: narrow at every return (a trap when the value is something else)
        conv = { int: :__dyn_int, int?: :__dyn_int, str: :__dyn_str, float: :__dyn_float }[old.rtype] or raise "redefinition of #{klass.name}##{d.name} returns a dynamic value where the program expects #{old.rtype.inspect}; not supported yet"
        cf = unit.lower.demand(conv)
        f.blocks.each do |b|
          b.insts = b.insts.flat_map do |i|
            next [i] unless i.op == :ret
            c = Inst.new(:call, [cf, i.args[0]]); c.ty = old.rtype; c.block = b
            i.args[0] = c; [c, i]
          end
        end
        f.rtype = old.rtype
      end
      work = [f, *extra].flat_map(&callees); added = false
      until work.empty?
        g = work.pop
        next if extra.include?(g) || unit.funcs.include?(g) || g.equal?(f)
        raise "redefinition of #{klass.name}##{d.name} calls #{g.name}, which has no body in this program" if g.blocks.empty?
        extra << g; added = true; work.concat(callees.(g))
      end
      break unless added
    end
    after = Types.snapshot
    # world-age, type edition: a slot the program typed and compiled against cannot change (dependents would need
    # recompiling). A slot never typed (nil: no code ever wrote it) may take a type now -- its only readers are new.
    unless (bad = diff_tables(before, after, true)).empty?
      raise "redefinition of #{klass.name}##{d.name} changes a type the program was compiled against (#{bad}); not supported yet"
    end
    [f, *extra].each { Passes.run(_1) }
    [f, *extra].each { Peephole.run(_1) unless ENV["NOPEEP"] }
    extra.each { Ranges.run(_1) unless ENV["NORANGES"] }
    GC.mark_allocators(unit.funcs + [f, *extra])
    Escape.run(unit.funcs + [f, *extra], unit.lower.classes) unless ENV["NOESCAPE"] # the callees' summaries are needed
    raise "redefinition changed #{f.name}'s signature" unless f.ptypes == old.ptypes && f.rtype == old.rtype
    asm = Asm.new
    asm.gc_table = unit.asm.gc_table
    asm.write_addr = Metal::LIBC["write"].to_i
    asm.mmap_addr = unit.asm.mmap_addr; asm.munmap_addr = unit.asm.munmap_addr; asm.libm = unit.asm.libm; asm.os = unit.asm.os
    asm.externs = unit.asm.labels.transform_values { base + _1 * 4 }
    asm.instance_variable_set(:@globals, unit.globals) # same slots
    f.name = :"#{old.name}@#{unit.seams.size}" # fresh label
    asm.label(:__text_base)
    $stderr.puts f.dump if ENV["DUMP"]
    [f, *extra].each { Codegen.new(asm, unit.lower.classes).func(_1) }
    asm.emit_overflow_trap            # checked arithmetic branches here (b.vs is pc-relative: per unit)
    asm.emit_gc_tables if GC.enabled? # this unit's frame maps, with the (grown) type table
    code = asm.resolve!
    [code, asm.labels.fetch(f.name) * 4, f, GC.enabled? ? asm.labels.fetch(:__gc_tables) * 4 : nil]
  end
end
