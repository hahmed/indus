# Indus, experiment 3: the third box.
#
#   Ruby source -> Prism AST -> SSA IR -> passes -> arm64 in memory -> jump
#
# The IR exists so a pass can see a whole function at once. First pass:
# accumulator tail-recursion to loop, the transform clang does to fib.
# Run: ruby experiments/03_ssa/indus.rb [file.rb]

gem "prism", "= 1.8.2" rescue nil
require "prism"
require "fiddle"

# ================================================================ IR
# A Value is an instruction that produces something. Blocks hold phis then
# instructions and end in a terminator (:br, :condbr, :ret).
class Inst
  attr_accessor :op, :args, :block, :reg
  attr_reader :id
  @@n = 0
  def initialize(op, args = []) = (@op, @args, @id = op, args, @@n += 1)
  def term? = %i[br condbr ret].include?(op)
  def to_s = "v#{id}"
end

class Block
  attr_accessor :name, :phis, :insts
  def initialize(name) = (@name, @phis, @insts = name, [], [])
  def term = insts.last
  def <<(i) = (i.block = self; insts << i; i)
  # phi: args = [[pred_block, value], ...]
  def phi = (p = Inst.new(:phi, []); p.block = self; phis << p; p)
  def succs
    t = term
    case t&.op
    when :br then [t.args[0]]
    when :condbr then t.args[1..2]
    else []
    end
  end
end

class Func
  attr_accessor :name, :params, :blocks
  def initialize(name, nparams)
    @name = name
    @params = Array.new(nparams) { Inst.new(:param) }
    @blocks = [Block.new(:entry)]
  end
  def entry = blocks.first
  def new_block(n) = (b = Block.new(:"#{n}#{blocks.size}"); blocks << b; b)
  def preds(b) = blocks.select { _1.succs.include?(b) }

  def dump
    s = "func #{name}(#{params.join(', ')})\n"
    blocks.each do |b|
      s << "#{b.name}:\n"
      b.phis.each { |p| s << "  #{p} = phi #{p.args.map { |(bb, v)| "[#{bb.name}: #{v}]" }.join(', ')}\n" }
      b.insts.each do |i|
        a = i.args.map { _1.is_a?(Block) ? _1.name : _1.to_s }.join(", ")
        s << (i.term? ? "  #{i.op} #{a}\n" : "  #{i} = #{i.op} #{a}\n")
      end
    end
    s
  end
end

# ================================================================ lowering
class Lower
  def initialize(src)
    @ast = Prism.parse(src).value
    @funcs = {}
  end

  def run
    defs, top = @ast.statements.body.partition { _1.is_a?(Prism::DefNode) }
    defs.each { |d| @funcs[d.name] = Func.new(d.name, d.parameters&.requireds&.size || 0) }
    main = Func.new(:main, 0)
    lower_body(main, [], top)
    defs.each { |d| lower_body(@funcs[d.name], d.parameters&.requireds&.map(&:name) || [], d.body.body) }
    [main, *@funcs.values]
  end

  private

  def lower_body(f, names, stmts)
    @f, @locals, @cur = f, names.zip(f.params).to_h, f.entry
    last = nil
    stmts.each { last = expr(_1) }
    @cur << Inst.new(:ret, [last || const(0)])
  end

  def const(v) = (@cur << Inst.new(:const, [v]))

  def expr(n)
    case n
    when Prism::IntegerNode then const(n.value)
    when Prism::LocalVariableReadNode then @locals.fetch(n.name)
    when Prism::ParenthesesNode then n.body.body.map { expr(_1) }.last
    when Prism::IfNode then if_expr(n)
    when Prism::CallNode then call(n)
    else raise "unsupported: #{n.class}"
    end
  end

  def call(n)
    args = n.arguments&.arguments || []
    case n.name
    when :+, :-, :<
      op = { :+ => :add, :- => :sub, :< => :lt }[n.name]
      l = expr(n.receiver); r = expr(args[0])
      @cur << Inst.new(op, [l, r])
    when :puts then expr(args[0])
    else
      f = @funcs.fetch(n.name) { raise "unknown method #{n.name}" }
      a = args.map { expr(_1) }
      @cur << Inst.new(:call, [f, *a])
    end
  end

  def if_expr(n)
    c = expr(n.predicate)
    tb, eb, mb = @f.new_block(:then), @f.new_block(:else), @f.new_block(:merge)
    @cur << Inst.new(:condbr, [c, tb, eb])
    @cur = tb; tv = n.statements.body.map { expr(_1) }.last || const(0); tend = @cur
    @cur << Inst.new(:br, [mb])
    @cur = eb; ev = n.subsequent&.statements&.body&.map { expr(_1) }&.last || const(0); eend = @cur
    @cur << Inst.new(:br, [mb])
    @cur = mb
    p = mb.phi; p.args = [[tend, tv], [eend, ev]]
    p
  end
end

# ================================================================ passes
module Passes
  # Fold `ret phi[a, b]` into `ret a` / `ret b` in the predecessors, so each
  # return is visible to the pass below. Also drops the now-empty merge block.
  def self.sink_returns(f)
    f.blocks.dup.each do |b|
      r = b.term
      next unless r&.op == :ret && (p = r.args[0]).op == :phi && p.block == b && b.insts.size == 1
      p.args.each { |(pred, v)| pred.insts.pop; pred << Inst.new(:ret, [v]) }
      f.blocks.delete(b)
    end
  end

  # Accumulator recursion -> loop.  `ret add(call f(x), e)` becomes
  #   acc += e ; params = x ; goto header
  # and every other `ret v` becomes `ret add(v, acc)`.
  def self.accumulate(f)
    rets = f.blocks.map(&:term).select { _1.op == :ret }
    tail = rets.find do |r|
      v = r.args[0]
      v.op == :add && v.args.any? { |a| a.op == :call && a.args[0] == f }
    end
    return false unless tail

    add = tail.args[0]
    # if both operands are self-calls, the later one becomes the loop
    self_call = add.args.reverse.find { |a| a.op == :call && a.args[0] == f }
    other = add.args.find { _1 != self_call }

    # header block with phis for every param and the accumulator
    header = Block.new(:header)
    f.blocks.insert(1, header)
    old_entry = f.entry
    entry = Block.new(:entry); f.blocks.unshift(entry)
    zero = entry << Inst.new(:const, [0])
    entry << Inst.new(:br, [header])
    header << Inst.new(:br, [old_entry])
    old_entry.name = :body

    param_phis = f.params.map { header.phi }
    acc = header.phi
    param_phis.each_with_index { |p, i| p.args << [entry, f.params[i]] }
    acc.args << [entry, zero]
    # rewrite uses of params to phis (params stay as the entry-side values)
    rewrite = f.params.zip(param_phis).to_h
    f.blocks.each do |b|
      b.phis.each { |p| p.args.map! { |(bb, v)| [bb, rewrite.fetch(v, v)] } unless b == header }
      b.insts.each { |i| i.args.map! { |a| rewrite.fetch(a, a) } }
    end

    # the tail: acc' = add(acc, other); params = call args; br header
    tb = tail.block
    tb.insts.delete(add); tb.insts.delete(self_call); tb.insts.delete(tail)
    acc2 = tb << Inst.new(:add, [acc, other])
    tb << Inst.new(:br, [header])
    param_phis.each_with_index { |p, i| p.args << [tb, self_call.args[i + 1]] }
    acc.args << [tb, acc2]

    # other returns: ret add(v, acc)
    (rets - [tail]).each do |r|
      r.block.insts.delete(r)
      sum = r.block << Inst.new(:add, [r.args[0], acc])
      r.block << Inst.new(:ret, [sum])
    end
    true
  end

  def self.run(f)
    sink_returns(f)
    accumulate(f)
  end
end

# ================================================================ arm64
class Asm
  attr_reader :words
  def initialize = (@words, @labels, @fixups = [], {}, [])
  def pos = @words.size
  def emit(w) = @words << (w & 0xFFFFFFFF)
  def label(n) = (@labels[n] = pos)
  def fix(n, k) = @fixups << [pos, n, k]

  def movz(rd, imm) = emit(0xD2800000 | ((imm & 0xFFFF) << 5) | rd)
  def movk(rd, imm) = emit(0xF2A00000 | ((imm & 0xFFFF) << 5) | rd)
  def mov_imm(rd, v)
    raise "literal out of range: #{v}" unless (0..0xFFFFFFFF).cover?(v)
    movz(rd, v); movk(rd, v >> 16) if v > 0xFFFF
  end
  def mov(rd, rn) = (emit(0xAA0003E0 | (rn << 16) | rd) unless rd == rn)
  def add(rd, rn, rm) = emit(0x8B000000 | (rm << 16) | (rn << 5) | rd)
  def sub(rd, rn, rm) = emit(0xCB000000 | (rm << 16) | (rn << 5) | rd)
  def addi(rd, rn, i) = emit(0x91000000 | (i << 10) | (rn << 5) | rd)
  def subi(rd, rn, i) = emit(0xD1000000 | (i << 10) | (rn << 5) | rd)
  def cmp(rn, rm) = emit(0xEB00001F | (rm << 16) | (rn << 5))
  def cmpi(rn, i) = emit(0xF100001F | (i << 10) | (rn << 5))
  def cset_lt(rd) = emit(0x9A9FA7E0 | rd)
  COND = { ge: 0xA, lt: 0xB }
  def bcond(c, n) = (fix(n, :b19); emit(0x54000000 | COND[c]))
  def cbz(rt, n) = (fix(n, :b19); emit(0xB4000000 | rt))
  def b(n) = (fix(n, :b26); emit(0x14000000))
  def bl(n) = (fix(n, :b26); emit(0x94000000))
  def ret = emit(0xD65F03C0)
  # stp/ldp xt1,xt2,[sp,#off]
  def stp(t1, t2, off) = t2 ? emit(0xA9000000 | ((off / 8) << 15) | (t2 << 10) | (31 << 5) | t1) : str(t1, off)
  def ldp(t1, t2, off) = t2 ? emit(0xA9400000 | ((off / 8) << 15) | (t2 << 10) | (31 << 5) | t1) : ldr(t1, off)
  def str(t, off) = emit(0xF9000000 | ((off / 8) << 10) | (31 << 5) | t)
  def ldr(t, off) = emit(0xF9400000 | ((off / 8) << 10) | (31 << 5) | t)
  def stp_pre(t1, t2, sz) = emit(0xA9800000 | (((-sz / 8) & 0x7F) << 15) | (t2 << 10) | (31 << 5) | t1)
  def ldp_post(t1, t2, sz) = emit(0xA8C00000 | ((sz / 8) << 15) | (t2 << 10) | (31 << 5) | t1)
  def mov_fp_sp = emit(0x910003FD)

  def resolve!
    @fixups.each do |at, n, k|
      off = @labels.fetch(n) { raise "undefined #{n}" } - at
      @words[at] |= k == :b19 ? ((off & 0x7FFFF) << 5) : (off & 0x3FFFFFF)
    end
    @words.pack("V*")
  end
end

# Register allocation: every SSA value gets a callee-saved register, freed at
# last use, so values trivially survive calls. Phis resolved as parallel
# copies at the end of each predecessor. Enough for now; linear scan later.
class Codegen
  CALLEE = (19..28).to_a
  CALLER = (9..15).to_a
  TMP = 8

  def initialize(asm) = @asm = asm

  # Layout: follow fallthrough edges greedily so loops and else-arms need no
  # extra jumps. Reassigns f.blocks so next_block/lbl agree with emission.
  def layout(f)
    order, seen = [], {}
    work = [f.entry]
    until work.empty?
      b = work.shift
      next if seen[b]
      seen[b] = true; order << b
      sc = b.succs
      sc = sc.reverse if b.term.op == :condbr # else first: the b.ge falls through
      work = sc + work
    end
    f.blocks = order
  end

  def func(f)
    @f = f
    layout(f)
    order = f.blocks
    all = order.flat_map { |b| b.phis + b.insts }
    # last use index per value
    idx = {}; all.each_with_index { |i, k| idx[i] = k }
    f.params.each { |p| idx[p] = -1 }
    last = Hash.new(-1)
    all.each_with_index do |i, k|
      i.args.each { |a| last[a] = [last[a], k].max if a.is_a?(Inst) }
      i.args.each { |(pred, v)| last[v] = [last[v], idx[pred.term]].max if v.is_a?(Inst) } if i.op == :phi
    end
    # phis live for the whole loop; be conservative
    all.select { _1.op == :phi }.each { |p| last[p] = all.size }

    call_at = all.each_index.select { all[_1].op == :call }
    across_call = ->(v, from) { call_at.any? { |c| c > from && c < last[v] } }
    callee, caller = CALLEE.dup, CALLER.dup; used = []; freed = []
    assign = ->(v, pool) {
      r = pool.shift or raise "out of registers"
      used |= [r] if pool.equal?(callee); v.reg = r
    }
    # params: callee-saved only if live across a call; a param whose only use
    # is a header phi hands its register to the phi (coalesce).
    loop_phi_src = all.select { _1.op == :phi }.flat_map { |ph| ph.args.map(&:last) }
    f.params.each_with_index { |p, i| assign.(p, (across_call.(p, -1) || loop_phi_src.include?(p)) ? callee : caller) }
    all.select { _1.op == :phi }.each do |ph|
      src = ph.args.map(&:last).find { |v| v.op == :param && last[v] <= idx[ph] }
      if src then ph.reg = src.reg; used |= [src.reg] unless CALLER.include?(src.reg)
      else assign.(ph, callee) end # live across the loop body, which calls
    end
    all.select { _1.op == :phi }.each do |ph|
      ph.args.each do |(pred, v)|
        next unless v.is_a?(Inst) && !v.reg && !%i[param phi const].include?(v.op) && v.block == pred
        next unless last[v] == idx[pred.term]                    # only use is the phi move
        uses_after = pred.insts[(pred.insts.index(v) + 1)..].any? { |j| j.args.include?(ph) }
        v.reg = ph.reg unless uses_after                          # ph is dead after v's def
      end
    end
    all.each_with_index do |i, k|
      next if i.reg # coalesced
      expired = (f.params + all[0...k]).select { |v| v.reg && last[v] < k && !freed.include?(v) }
      expired.each { |v| freed << v; (CALLEE.include?(v.reg) ? callee : caller).unshift(v.reg) }
      next if i.term? || i.op == :phi || i.op == :const && !needs_reg?(i)
      assign.(i, across_call.(i, k) ? callee : caller)
    end

    used.sort!
    frame = 16 + ((used.size + 1) / 2) * 16
    @asm.label(f.name)
    @asm.stp_pre(29, 30, frame); @asm.mov_fp_sp
    used.each_slice(2).with_index { |(a, b), i| @asm.stp(a, b, 16 + i * 16) }
    f.params.each_with_index { |p, i| @asm.mov(p.reg, i) }

    order.each { |b| block(b) }

    @asm.label(:"#{f.name}_ret")
    used.each_slice(2).with_index { |(a, b), i| @asm.ldp(a, b, 16 + i * 16) }
    @asm.ldp_post(29, 30, frame); @asm.ret
  end

  def needs_reg?(c) = false # constants are folded into their users or materialized on demand

  def imm?(v) = v.op == :const && (0..4095).cover?(v.args[0])

  # materialize value into a register, returning it (constants go to TMP)
  def reg(v, tmp = TMP)
    return v.reg if v.reg
    raise "no reg for #{v.op}" unless v.op == :const
    @asm.mov_imm(tmp, v.args[0]); tmp
  end

  def block(b)
    @asm.label(:"#{@f.name}_#{b.name}")
    b.insts.each_with_index do |i, k|
      case i.op
      when :const then nil
      when :add, :sub
        l, r = i.args
        if imm?(r) then @asm.send(i.op == :add ? :addi : :subi, i.reg, reg(l), r.args[0])
        else @asm.send(i.op, i.reg, reg(l), reg(r, 9)) end
      when :lt
        nxt = b.insts[k + 1]
        if nxt&.op == :condbr && nxt.args[0] == i
          l, r = i.args
          imm?(r) ? @asm.cmpi(reg(l), r.args[0]) : @asm.cmp(reg(l), reg(r, 9))
          @flags = :lt
        else
          l, r = i.args
          imm?(r) ? @asm.cmpi(reg(l), r.args[0]) : @asm.cmp(reg(l), reg(r, 9))
          @asm.cset_lt(i.reg)
        end
      when :call
        f, *a = i.args
        a.each_with_index { |v, n| @asm.mov(n, reg(v)) }
        @asm.bl(f.name)
        @asm.mov(i.reg, 0)
      when :condbr
        c, t, e = i.args
        phi_moves(b, t); phi_moves(b, e) # both empty for if/else; loops use :br
        nb = next_block(b)
        if @flags
          if nb == e then @asm.bcond(:lt, lbl(t))
          else @asm.bcond(:ge, lbl(e)); @asm.b(lbl(t)) unless nb == t end
          @flags = nil
        else
          @asm.cbz(reg(c), lbl(e)); @asm.b(lbl(t)) unless nb == t
        end
      when :br
        phi_moves(b, i.args[0])
        @asm.b(lbl(i.args[0])) unless next_block(b) == i.args[0]
      when :ret
        @asm.mov(0, reg(i.args[0]))
        @asm.b(:"#{@f.name}_ret") unless b == @f.blocks.last
      else raise "codegen: #{i.op}"
      end
    end
  end

  def lbl(b) = :"#{@f.name}_#{b.name}"
  def next_block(b) = @f.blocks[@f.blocks.index(b) + 1]

  # parallel copy for phis in `to` coming from `from`
  def phi_moves(from, to)
    moves = to.phis.map { |p| v = p.args.find { _1[0] == from }&.last; [p.reg, v] }.reject { |(d, v)| v.nil? }
    moves = moves.map { |(d, v)| [d, v.reg || v] }.reject { |(d, s)| d == s }
    until moves.empty?
      ready = moves.find { |(d, s)| moves.none? { |(_, s2)| s2 == d } }
      if ready
        d, s = ready
        s.is_a?(Inst) ? @asm.mov_imm(d, s.args[0]) : @asm.mov(d, s)
        moves.delete(ready)
      else # cycle: break through TMP
        d, s = moves.first
        @asm.mov(TMP, s); moves.map! { |(dd, ss)| [dd, ss == s ? TMP : ss] }
      end
    end
  end
end

# ================================================================ loader
module Metal
  LIBC = Fiddle::Handle::DEFAULT
  MMAP = Fiddle::Function.new(LIBC["mmap"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_LONG], Fiddle::TYPE_VOIDP)
  MPROTECT = Fiddle::Function.new(LIBC["mprotect"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
  ICACHE = Fiddle::Function.new(LIBC["sys_icache_invalidate"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T], Fiddle::TYPE_VOID)

  def self.run(code)
    size = (code.bytesize + 4095) & ~4095
    mem = MMAP.call(nil, size, 3, 0x1002, -1, 0)
    raise "mmap failed" if mem.to_i == -1
    mem[0, code.bytesize] = code
    raise "mprotect failed" unless MPROTECT.call(mem, size, 5).zero?
    ICACHE.call(mem, size)
    Fiddle::Function.new(mem, [], Fiddle::TYPE_LONG).call
  end
end

# ================================================================ go
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

funcs = Lower.new(src).run
funcs.each { Passes.run(_1) unless ENV["NOPASS"] }
$stderr.puts funcs.map(&:dump) if ENV["DUMP"]
asm = Asm.new
funcs.each { Codegen.new(asm).func(_1) }
code = asm.resolve!
if ENV["HEX"] then code.unpack("V*").each_with_index { |w,i| printf("%3d: %08x\n", i*4, w) }; exit end
t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = Metal.run(code)
dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
puts result
$stderr.puts "indus: #{code.bytesize} bytes of arm64, ran in #{(dt * 1000).round(1)} ms"
