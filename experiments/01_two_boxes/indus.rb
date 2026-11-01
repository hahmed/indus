# Indus, experiment 1: two boxes.
#
#   Ruby source -> Prism AST -> arm64 machine code in executable memory -> jump
#
# No C, no LLVM, no assembler, no linker, no bytecode, no runtime.
# Run: ruby experiments/01_two_boxes/indus.rb

gem "prism", "= 1.8.2" rescue nil
require "prism"
require "fiddle"

# ---------------------------------------------------------------- arm64 encoder
# Each method appends one 32-bit instruction. Only what fib needs.
class Asm
  attr_reader :words

  def initialize
    @words = []
    @labels = {}
    @fixups = []
  end

  def pos = @words.size
  def emit(w) = @words << (w & 0xFFFFFFFF)

  # label: a name bound to an instruction index, resolved at the end
  def label(name) = (@labels[name] = pos)
  def fixup(name, kind) = @fixups << [pos, name, kind]

  # prologue: stp x29,x30,[sp,#-32]! ; mov x29,sp ; str x0,[sp,#16]
  def prologue
    emit 0xA9BE7BFD
    emit 0x910003FD
    emit 0xF9000BE0
  end

  # epilogue: ldp x29,x30,[sp],#32 ; ret
  def epilogue
    emit 0xA8C27BFD
    emit 0xD65F03C0
  end

  def ldr_x0_param = emit(0xF9400BA0)        # ldr x0,[x29,#16]
  def push_x0      = emit(0xF81F0FE0)        # str x0,[sp,#-16]!
  def pop_x0       = emit(0xF84107E0)        # ldr x0,[sp],#16
  def mov_x1_x0    = emit(0xAA0003E1)        # mov x1,x0
  def add_x0_x0_x1 = emit(0x8B010000)
  def sub_x0_x0_x1 = emit(0xCB010000)
  def cmp_x0_x1    = emit(0xEB01001F)
  def cset_x0_lt   = emit(0x9A9FA7E0)

  def mov_x0_imm(v)
    raise "literal out of range: #{v}" unless (0..0xFFFFFFFF).cover?(v)
    emit 0xD2800000 | ((v & 0xFFFF) << 5)                  # movz x0,#lo
    emit 0xF2A00000 | (((v >> 16) & 0xFFFF) << 5) if v > 0xFFFF # movk x0,#hi,lsl 16
  end

  def cbz_x0(name) = (fixup(name, :cbz); emit 0xB4000000)
  def b(name)      = (fixup(name, :b);   emit 0x14000000)
  def bl(name)     = (fixup(name, :bl);  emit 0x94000000)

  def resolve!
    @fixups.each do |at, name, kind|
      target = @labels.fetch(name) { raise "undefined: #{name}" }
      off = target - at
      @words[at] |= case kind
                    when :cbz then (off & 0x7FFFF) << 5
                    else           (off & 0x3FFFFFF)
                    end
    end
    @words.pack("V*")
  end
end

# ---------------------------------------------------------------- compiler
# Walks the Prism AST, emits into Asm. Every expression leaves its value in x0.
class Indus
  def initialize(src)
    @asm = Asm.new
    @ast = Prism.parse(src).value
    @methods = {}
  end

  def compile
    defs, top = @ast.statements.body.partition { _1.is_a?(Prism::DefNode) }
    defs.each { |d| @methods[d.name] = d.parameters&.requireds&.first&.name }

    # top-level becomes `main`: returns the last expression's value in x0
    @asm.label(:main)
    @asm.prologue
    top.each { expr(_1) }
    @asm.epilogue

    defs.each do |d|
      @asm.label(d.name)
      @asm.prologue
      @param = @methods[d.name]
      d.body.body.each { expr(_1) }
      @asm.epilogue
    end

    @asm.resolve!
  end

  private

  def expr(n)
    case n
    when Prism::IntegerNode        then @asm.mov_x0_imm(n.value)
    when Prism::LocalVariableReadNode
      raise "unknown local #{n.name}" unless n.name == @param
      @asm.ldr_x0_param
    when Prism::ParenthesesNode    then n.body.body.each { expr(_1) }
    when Prism::IfNode             then if_node(n)
    when Prism::CallNode           then call(n)
    else raise "unsupported: #{n.class}"
    end
  end

  def binop(n)
    expr(n.receiver)
    @asm.push_x0
    expr(n.arguments.arguments.first)
    @asm.mov_x1_x0
    @asm.pop_x0
    yield
  end

  def call(n)
    case n.name
    when :+ then binop(n) { @asm.add_x0_x0_x1 }
    when :- then binop(n) { @asm.sub_x0_x0_x1 }
    when :< then binop(n) { @asm.cmp_x0_x1; @asm.cset_x0_lt }
    when :puts then expr(n.arguments.arguments.first) # host prints x0
    else
      raise "unknown method #{n.name}" unless @methods.key?(n.name)
      expr(n.arguments.arguments.first)
      @asm.bl(n.name)
    end
  end

  def if_node(n)
    els = :"else_#{@asm.pos}"; fin = :"end_#{@asm.pos}"
    expr(n.predicate)
    @asm.cbz_x0(els)
    n.statements.body.each { expr(_1) }
    @asm.b(fin)
    @asm.label(els)
    n.subsequent&.statements&.body&.each { expr(_1) }
    @asm.label(fin)
  end
end

# ---------------------------------------------------------------- loader
# mmap RW, copy, mprotect RX, invalidate icache, call. No file ever touched.
module Metal
  LIBC = Fiddle::Handle::DEFAULT
  MMAP     = Fiddle::Function.new(LIBC["mmap"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_LONG], Fiddle::TYPE_VOIDP)
  MPROTECT = Fiddle::Function.new(LIBC["mprotect"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
  ICACHE   = Fiddle::Function.new(LIBC["sys_icache_invalidate"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T], Fiddle::TYPE_VOID)
  PROT_READ, PROT_WRITE, PROT_EXEC = 1, 2, 4
  MAP_PRIVATE, MAP_ANON = 0x02, 0x1000

  def self.run(code)
    size = (code.bytesize + 4095) & ~4095
    mem = MMAP.call(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
    raise "mmap failed" if mem.to_i == -1
    mem[0, code.bytesize] = code
    raise "mprotect failed" unless MPROTECT.call(mem, size, PROT_READ | PROT_EXEC).zero?
    ICACHE.call(mem, size)
    Fiddle::Function.new(mem, [], Fiddle::TYPE_LONG).call
  end
end

# ---------------------------------------------------------------- go
src = ARGV[0] ? File.read(ARGV[0]) : <<~RUBY
  def fib(n)
    if n < 2
      n
    else
      fib(n - 1) + fib(n - 2)
    end
  end

  puts fib(35)
RUBY

code = Indus.new(src).compile
t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = Metal.run(code)
dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t

puts result
$stderr.puts "indus: #{code.bytesize} bytes of arm64, ran in #{(dt * 1000).round(1)} ms"
