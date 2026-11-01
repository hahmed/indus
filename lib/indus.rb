# Indus: Ruby -> SSA -> arm64. No C, no LLVM, no assembler, no linker.
#
#   lib/indus/ir.rb       SSA values, blocks, functions
#   lib/indus/lower.rb    Prism AST -> SSA
#   lib/indus/types.rb    type inference (int/float/arrays), conversions
#   lib/indus/passes.rb   SSA passes (trivial phis, return sinking, accumulator loops)
#   lib/indus/asm.rb      arm64 encoder + hand-written runtime routines
#   lib/indus/regalloc.rb linear-scan register allocation over dataflow liveness
#   lib/indus/codegen.rb  layout, frames, instruction selection
#   lib/indus/metal.rb    run in-process
#   lib/indus/macho.rb    standalone Mach-O writer
#   lib/indus/elf.rb      standalone Linux ELF writer
#
# See experiments/ for how it got here.
gem "prism", "= 1.8.2" rescue nil
require "prism"
require "fiddle"
%w[ir lower types passes asm regalloc codegen metal macho elf].each { require_relative "indus/#{_1}" }

module Indus
  # standalone: nil (run in-process via libc write), :darwin or :linux
  def self.compile(src, standalone: nil)
    lower = Lower.new(src)
    funcs = lower.run
    Types.run(funcs, lower.classes)
    funcs.each { Passes.run(_1) unless ENV["NOPASS"] }
    $stderr.puts funcs.map(&:dump) if ENV["DUMP"]
    asm = Asm.new
    asm.write_addr = Metal::LIBC["write"].to_i unless standalone
    asm.emit_start_linux if standalone == :linux
    funcs.each { Codegen.new(asm, lower.classes).func(_1) }
    asm.emit_puts_i
    asm.emit_putc
    asm.emit_array_new
    asm.emit_array_set_slow
    asm.emit_object_new
    asm.emit_ipow
    asm.emit_syscalls(standalone) if standalone
    asm.resolve!
  end
end
