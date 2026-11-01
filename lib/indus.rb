# Indus: Ruby -> SSA -> arm64. See experiments/ for how it got here.
gem "prism", "= 1.8.2" rescue nil
require "prism"
require "fiddle"

# ================================================================ IR
class Inst
  attr_accessor :op, :args, :block, :reg, :cond
  attr_reader :id
  @@n = 0
  def initialize(op, args = [], cond = nil) = (@op, @args, @cond, @id = op, args, cond, @@n += 1)
  def term? = %i[br condbr ret].include?(op)
  def call? = %i[call puts_i puts_s].include?(op)
  def to_s = "v#{id}"
end

class Block
  attr_accessor :name, :phis, :insts, :cold
  def initialize(name) = (@name, @phis, @insts = name, [], [])
  def term = (t = insts.last; t if t&.term?)
  def <<(i) = (i.block = self; insts << i; i)
  def phi = (p = Inst.new(:phi, []); p.block = self; phis << p; p)
  def succs
    case term&.op
    when :br then [term.args[0]]
    when :condbr then term.args[1..2]
    else []
    end
  end
end

class Func
  attr_accessor :name, :params, :blocks
  def initialize(name, nparams)
    @name, @params, @blocks = name, Array.new(nparams) { Inst.new(:param) }, [Block.new(:entry)]
  end
  def entry = blocks.first
  def new_block(n) = (b = Block.new(:"#{n}#{blocks.size}"); blocks << b; b)
  def all = blocks.flat_map { |b| b.phis + b.insts }

  def replace_uses(from, to)
    all.each do |i|
      i.op == :phi ? i.args.map! { |(bb, v)| [bb, v == from ? to : v] } : i.args.map! { |a| a == from ? to : a }
    end
  end

  def dump
    s = "func #{name}(#{params.join(', ')})\n"
    blocks.each do |b|
      s << "#{b.name}:#{b.cold ? ' (cold)' : ''}\n"
      b.phis.each { |p| s << "  #{p} = phi #{p.args.map { |(bb, v)| "[#{bb.name}: #{v}]" }.join(', ')}\n" }
      b.insts.each do |i|
        a = i.args.map { _1.is_a?(Block) ? _1.name : _1.is_a?(Func) ? _1.name : _1.to_s }.join(", ")
        s << (i.term? ? "  #{i.op} #{a}\n" : "  #{i} = #{i.op}#{i.cond ? ".#{i.cond}" : ''} #{a}\n")
      end
    end
    s
  end
end

# ================================================================ lowering
# Locals are a name->value map per program point. `while` makes a phi per
# live local at the header; `if` makes a phi per local that differs at the
# merge. Trivial phis are removed afterwards.
class Lower
  CMP = { :== => :eq, :!= => :ne, :< => :lt, :<= => :le, :> => :gt, :>= => :ge }
  ARITH = { :+ => :add, :- => :sub, :* => :mul }

  def initialize(src) = (@ast, @funcs = Prism.parse(src).value, {})

  def run
    defs, top = @ast.statements.body.partition { _1.is_a?(Prism::DefNode) }
    defs.each { |d| @funcs[d.name] = Func.new(d.name, d.parameters&.requireds&.size || 0) }
    main = Func.new(:main, 0)
    lower_body(main, [], top)
    defs.each { |d| lower_body(@funcs[d.name], d.parameters&.requireds&.map(&:name) || [], d.body&.body || []) }
    [main, *@funcs.values]
  end

  private

  def lower_body(f, names, stmts)
    @f, @locals, @cur = f, names.zip(f.params).to_h, f.entry
    last = nil
    stmts.each { last = expr(_1) }
    @cur << Inst.new(:ret, [last || const(0)]) unless @cur.term
  end

  def const(v) = (@cur << Inst.new(:const, [v]))

  def expr(n)
    case n
    when Prism::IntegerNode then const(n.value)
    when Prism::LocalVariableReadNode then @locals.fetch(n.name) { raise "undefined local #{n.name}" }
    when Prism::LocalVariableWriteNode then @locals[n.name] = expr(n.value)
    when Prism::ParenthesesNode then n.body.body.map { expr(_1) }.last
    when Prism::StringNode then n # handled by puts
    when Prism::IfNode then if_expr(n)
    when Prism::WhileNode then while_stmt(n)
    when Prism::CallNode then call(n)
    else raise "unsupported: #{n.class}"
    end
  end

  def call(n)
    args = n.arguments&.arguments || []
    if (op = ARITH[n.name])
      l = expr(n.receiver); r = expr(args[0])
      @cur << Inst.new(op, [l, r])
    elsif (c = CMP[n.name])
      l = expr(n.receiver); r = expr(args[0])
      @cur << Inst.new(:cmp, [l, r], c)
    elsif n.name == :puts
      a = args[0]
      if a.is_a?(Prism::StringNode) then @cur << Inst.new(:puts_s, [a.unescaped])
      else @cur << Inst.new(:puts_i, [expr(a)]) end
    else
      f = @funcs.fetch(n.name) { raise "unknown method #{n.name}" }
      @cur << Inst.new(:call, [f, *args.map { expr(_1) }])
    end
  end

  def if_expr(n)
    c = expr(n.predicate)
    tb, eb, mb = @f.new_block(:then), @f.new_block(:else), @f.new_block(:merge)
    @cur << Inst.new(:condbr, [c, tb, eb])
    before = @locals.dup

    @cur = tb; tv = (n.statements&.body || []).map { expr(_1) }.last || const(0)
    tend, tlocals = @cur, @locals; @cur << Inst.new(:br, [mb]) unless @cur.term

    @cur = eb; @locals = before.dup
    ev = case n.subsequent
         when Prism::IfNode then if_expr(n.subsequent)
         when Prism::ElseNode then n.subsequent.statements&.body&.map { expr(_1) }&.last
         end || const(0)
    eend, elocals = @cur, @locals; @cur << Inst.new(:br, [mb]) unless @cur.term

    @cur = mb
    @locals = merge_locals(mb, [[tend, tlocals], [eend, elocals]])
    p = mb.phi; p.args = [[tend, tv], [eend, ev]]
    p
  end

  def merge_locals(mb, arms)
    names = arms.flat_map { _2.keys }.uniq
    names.to_h do |nm|
      vals = arms.map { |(_, l)| l[nm] }
      next [nm, vals[0]] if vals.uniq.size == 1 && !vals[0].nil?
      ph = mb.phi
      ph.args = arms.filter_map { |(b, l)| l[nm] && [b, l[nm]] }
      [nm, ph]
    end
  end

  def while_stmt(n)
    hb, bb, xb = @f.new_block(:head), @f.new_block(:body), @f.new_block(:exit)
    xb.cold = true
    pre = @cur
    @cur << Inst.new(:br, [hb])
    phis = @locals.to_h { |nm, v| ph = hb.phi; ph.args << [pre, v]; [nm, ph] }
    @locals = phis.dup
    @cur = hb
    c = expr(n.predicate)
    @cur << Inst.new(:condbr, [c, bb, xb])
    @cur = bb
    (n.statements&.body || []).each { expr(_1) }
    bend = @cur
    @cur << Inst.new(:br, [hb]) unless @cur.term
    phis.each { |nm, ph| ph.args << [bend, @locals[nm]] }
    @cur = xb
    @locals = phis.dup
    const(0)
  end
end

# ================================================================ passes
module Passes
  # phi whose args are all itself or one value v -> v
  def self.trivial_phis(f)
    loop do
      changed = false
      f.blocks.each do |b|
        b.phis.dup.each do |p|
          others = p.args.map(&:last).reject { _1 == p }.uniq
          next unless others.size == 1
          f.replace_uses(p, others[0]); b.phis.delete(p); changed = true
        end
      end
      break unless changed
    end
  end

  def self.sink_returns(f)
    f.blocks.dup.each do |b|
      r = b.term
      next unless r&.op == :ret && (p = r.args[0]).op == :phi && p.block == b && b.insts.size == 1 && b.phis == [p]
      p.args.each { |(pred, v)| pred.insts.pop; pred << Inst.new(:ret, [v]) }
      f.blocks.delete(b)
    end
  end

  def self.accumulate(f)
    rets = f.blocks.map(&:term).select { _1&.op == :ret }
    tail = rets.find { |r| (v = r.args[0]).op == :add && v.args.any? { |a| a.op == :call && a.args[0] == f } }
    return false unless tail
    add = tail.args[0]
    self_call = add.args.reverse.find { |a| a.op == :call && a.args[0] == f }
    other = add.args.find { _1 != self_call }
    return false if f.blocks.any? { |b| b.phis.any? } # keep it simple: no existing loops

    header = Block.new(:header); old_entry = f.entry; entry = Block.new(:entry)
    f.blocks.insert(1, header); f.blocks.unshift(entry)
    zero = entry << Inst.new(:const, [0]); entry << Inst.new(:br, [header])
    header << Inst.new(:br, [old_entry]); old_entry.name = :body
    param_phis = f.params.map { header.phi }; acc = header.phi
    param_phis.each_with_index { |p, i| p.args << [entry, f.params[i]] }; acc.args << [entry, zero]
    rewrite = f.params.zip(param_phis).to_h
    f.blocks.each do |b|
      b.phis.each { |p| p.args.map! { |(bb, v)| [bb, rewrite.fetch(v, v)] } unless b == header }
      b.insts.each { |i| i.args.map! { |a| rewrite.fetch(a, a) } }
    end
    tb = tail.block
    tb.insts.delete(add); tb.insts.delete(self_call); tb.insts.delete(tail)
    acc2 = tb << Inst.new(:add, [acc, other]); tb << Inst.new(:br, [header])
    param_phis.each_with_index { |p, i| p.args << [tb, self_call.args[i + 1]] }; acc.args << [tb, acc2]
    (rets - [tail]).each do |r|
      r.block.insts.delete(r)
      sum = r.block << Inst.new(:add, [r.args[0], acc]); r.block << Inst.new(:ret, [sum])
    end
    true
  end

  def self.run(f)
    trivial_phis(f)
    sink_returns(f)
    accumulate(f)
  end
end

# ================================================================ arm64
class Asm
  attr_reader :words
  def initialize = (@words, @labels, @fixups, @data = [], {}, [], [])
  def pos = @words.size
  def emit(w) = @words << (w & 0xFFFFFFFF)
  def label(n) = (@labels[n] = pos)
  def fix(n, k) = @fixups << [pos, n, k]

  def movz(rd, imm, sh = 0) = emit(0xD2800000 | (sh << 21) | ((imm & 0xFFFF) << 5) | rd)
  def movk(rd, imm, sh) = emit(0xF2800000 | (sh << 21) | ((imm & 0xFFFF) << 5) | rd)
  def movn(rd, imm) = emit(0x92800000 | ((imm & 0xFFFF) << 5) | rd)
  def mov_imm(rd, v)
    if v < 0 && v >= -0x10000 then movn(rd, ~v)
    else
      u = v & 0xFFFFFFFFFFFFFFFF
      movz(rd, u & 0xFFFF)
      movk(rd, (u >> 16) & 0xFFFF, 1) if u > 0xFFFF
      movk(rd, (u >> 32) & 0xFFFF, 2) if u > 0xFFFFFFFF
      movk(rd, (u >> 48) & 0xFFFF, 3) if u > 0xFFFFFFFFFFFF
    end
  end
  def mov(rd, rn) = (emit(0xAA0003E0 | (rn << 16) | rd) unless rd == rn)
  def add(rd, rn, rm) = emit(0x8B000000 | (rm << 16) | (rn << 5) | rd)
  def sub(rd, rn, rm) = emit(0xCB000000 | (rm << 16) | (rn << 5) | rd)
  def mul(rd, rn, rm) = emit(0x9B007C00 | (rm << 16) | (rn << 5) | rd)
  def addi(rd, rn, i) = emit(0x91000000 | (i << 10) | (rn << 5) | rd)
  def subi(rd, rn, i) = emit(0xD1000000 | (i << 10) | (rn << 5) | rd)
  def cmp(rn, rm) = emit(0xEB00001F | (rm << 16) | (rn << 5))
  def cmpi(rn, i) = emit(0xF100001F | (i << 10) | (rn << 5))
  COND = { eq: 0x0, ne: 0x1, ge: 0xA, lt: 0xB, gt: 0xC, le: 0xD }
  INV = { eq: :ne, ne: :eq, ge: :lt, lt: :ge, gt: :le, le: :gt }
  def cset(rd, c) = emit(0x9A9F07E0 | (COND[INV[c]] << 12) | rd)
  def bcond(c, n) = (fix(n, :b19); emit(0x54000000 | COND[c]))
  def cbz(rt, n) = (fix(n, :b19); emit(0xB4000000 | rt))
  def cbnz(rt, n) = (fix(n, :b19); emit(0xB5000000 | rt))
  def b(n) = (fix(n, :b26); emit(0x14000000))
  def bl(n) = (fix(n, :b26); emit(0x94000000))
  def blr(rn) = emit(0xD63F0000 | (rn << 5))
  def ret = emit(0xD65F03C0)
  def adr(rd, n) = (fix(n, :adr); emit(0x10000000 | rd))
  def stp(t1, t2, off) = t2 ? emit(0xA9000000 | ((off / 8) << 15) | (t2 << 10) | (31 << 5) | t1) : str(t1, off)
  def ldp(t1, t2, off) = t2 ? emit(0xA9400000 | ((off / 8) << 15) | (t2 << 10) | (31 << 5) | t1) : ldr(t1, off)
  def str(t, off) = emit(0xF9000000 | ((off / 8) << 10) | (31 << 5) | t)
  def ldr(t, off) = emit(0xF9400000 | ((off / 8) << 10) | (31 << 5) | t)
  def stp_pre(t1, t2, sz) = emit(0xA9800000 | (((-sz / 8) & 0x7F) << 15) | (t2 << 10) | (31 << 5) | t1)
  def ldp_post(t1, t2, sz) = emit(0xA8C00000 | ((sz / 8) << 15) | (t2 << 10) | (31 << 5) | t1)
  def mov_fp_sp = emit(0x910003FD)

  # data: bytes placed after the code, addressed with adr
  def data(name, bytes) = @data << [name, bytes]

  # --- the whole "runtime": puts for an Integer, via write(2) --------------
  # x0 = value. Builds decimal + "\n" in a 32-byte stack buffer, calls write.
  attr_accessor :write_addr # nil => bl __write (syscall stub)
  def call_write = write_addr ? (mov_imm(16, write_addr); blr(16)) : bl(:__write)

  # raw syscalls for a standalone binary.
  #   darwin: number in x16, svc #0x80, write=4
  #   linux:  number in x8,  svc #0,    write=64 exit=93
  def emit_syscalls(os)
    label(:__write)
    case os
    when :darwin then emit 0xD2800090; emit 0xD4001001; ret      # mov x16,#4 ; svc #0x80
    when :linux  then emit 0xD2800808; emit 0xD4000001; ret      # mov x8,#64 ; svc #0
    end
  end

  # linux has no dyld to call main: _start calls main then exit(0)
  def emit_start_linux
    label(:_start); bl(:main)
    emit 0xD2800000; emit 0xD2800BA8; emit 0xD4000001            # mov x0,#0 ; mov x8,#93 ; svc #0
  end

  def emit_puts_i
    label(:__puts_i)
    stp_pre(29, 30, 48); mov_fp_sp
    emit 0x910083E1                 # add x1, sp, #32        (end of buffer; buf is [sp+16, sp+48))
    emit 0x9100C3E1                 # add x1, sp, #48
    emit 0x52800143                 # mov w3, #10  '\n'
    emit 0x381FFC23                 # strb w3, [x1, #-1]!
    emit 0xD280014A                 # mov x10, #10
    emit 0xD280000B                 # mov x11, #0  (negative flag)
    emit 0xF100001F                 # cmp x0, #0
    bcond(:ge, :__pi_loop)
    emit 0xCB0003E0                 # neg x0, x0
    emit 0xD280002B                 # mov x11, #1
    label(:__pi_loop)
    emit 0x9ACA0802                 # udiv x2, x0, x10
    emit 0x9B0A8043                 # msub x3, x2, x10, x0
    emit 0x1100C063                 # add w3, w3, #48
    emit 0x381FFC23                 # strb w3, [x1, #-1]!
    emit 0xAA0203E0                 # mov x0, x2
    cbnz(0, :__pi_loop)
    cbz(11, :__pi_write)
    emit 0x528005A3                 # mov w3, #45 '-'
    emit 0x381FFC23                 # strb w3, [x1, #-1]!
    label(:__pi_write)
    emit 0x9100C3E2                 # add x2, sp, #48
    emit 0xCB010042                 # sub x2, x2, x1
    emit 0xD2800020                 # mov x0, #1
    call_write
    ldp_post(29, 30, 48); ret
  end

  def resolve!
    # place data after code, 8-aligned
    emit 0 while pos % 2 != 0
    @data.each do |name, bytes|
      label(name)
      padded = bytes + "\0" * ((4 - bytes.bytesize % 4) % 4)
      @words.concat(padded.unpack("V*"))
    end
    @fixups.each do |at, n, k|
      off = @labels.fetch(n) { raise "undefined #{n}" } - at
      @words[at] |= case k
                    when :b19 then (off & 0x7FFFF) << 5
                    when :b26 then off & 0x3FFFFFF
                    when :adr then bo = off * 4; ((bo & 3) << 29) | (((bo >> 2) & 0x7FFFF) << 5)
                    end
    end
    @words.pack("V*")
  end
end

# ================================================================ codegen
class Codegen
  CALLEE = (19..28).to_a
  CALLER = (9..15).to_a
  TMP = 8

  def initialize(asm) = @asm = asm

  def layout(f)
    order, seen, work = [], {}, [f.entry]
    until work.empty?
      b = work.shift
      next if seen[b]
      seen[b] = true; order << b
      sc = b.succs
      if b.term.op == :condbr
        t, e = sc
        sc = e.cold ? [t, e] : [e, t] # fall into the loop body; else-first otherwise
      end
      work = sc + work
    end
    f.blocks = order
  end

  def func(f)
    @f = f
    layout(f)
    all = f.all
    idx = {}; all.each_with_index { |i, k| idx[i] = k }
    f.params.each { |p| idx[p] = -1 }
    last = Hash.new(-1)
    all.each_with_index do |i, k|
      if i.op == :phi
        i.args.each { |(pred, v)| last[v] = [last[v], idx[pred.term]].max if v.is_a?(Inst) }
      else
        i.args.each { |a| last[a] = [last[a], k].max if a.is_a?(Inst) }
      end
    end
    phis = all.select { _1.op == :phi }
    # a phi is live over its whole loop: from its block to the last pred terminator
    phis.each { |p| last[p] = [last[p], *p.args.map { |(pred, _)| idx[pred.term] }].max }

    call_at = all.each_index.select { all[_1].call? }
    across = ->(v, from) { call_at.any? { |c| c > from && c < last[v] } }
    callee, caller = CALLEE.dup, CALLER.dup; used = []; freed = []
    assign = ->(v, pool) {
      r = pool.shift || (pool.equal?(callee) ? caller : callee).shift or raise "out of registers in #{f.name}"
      used |= [r] if CALLEE.include?(r); v.reg = r
    }
    phi_srcs = phis.flat_map { |p| p.args.map(&:last) }
    f.params.each { |p| assign.(p, (across.(p, -1) || phi_srcs.include?(p)) ? callee : caller) }
    phis.each do |ph|
      src = ph.args.map(&:last).find { |v| v.op == :param && last[v] <= idx[ph] && phi_srcs.count(v) == 1 }
      if src then ph.reg = src.reg
      else assign.(ph, across.(ph, idx[ph.block.insts.first] - 1) || across.(ph, -1) ? callee : caller) end
    end
    phis.each do |ph|
      ph.args.each do |(pred, v)|
        next unless v.is_a?(Inst) && !v.reg && !%i[param phi const].include?(v.op) && v.block == pred
        next unless last[v] == idx[pred.term]
        after = pred.insts[(pred.insts.index(v) + 1)..].any? { |j| j.args.include?(ph) }
        v.reg = ph.reg unless after
      end
    end
    all.each_with_index do |i, k|
      expired = (f.params + all[0...k]).select { |v| v.reg && last[v] < k && !freed.include?(v) }
      expired.each { |v| freed << v; (CALLEE.include?(v.reg) ? callee : caller).unshift(v.reg) }
      next if i.reg || i.term? || i.op == :phi || i.op == :const || i.op == :puts_s || i.op == :puts_i
      next if i.op == :cmp && fused?(i)
      assign.(i, across.(i, k) ? callee : caller)
    end

    used.sort!
    frame = 16 + ((used.size + 1) / 2) * 16
    @asm.label(f.name)
    @asm.stp_pre(29, 30, frame); @asm.mov_fp_sp
    used.each_slice(2).with_index { |(a, b), i| @asm.stp(a, b, 16 + i * 16) }
    # params arrive in x0..; move to their homes (parallel copy: homes never overlap x0-x7)
    f.params.each_with_index { |p, i| @asm.mov(p.reg, i) }
    f.blocks.each { block(_1) }
    @asm.label(:"#{f.name}_ret")
    used.each_slice(2).with_index { |(a, b), i| @asm.ldp(a, b, 16 + i * 16) }
    @asm.ldp_post(29, 30, frame); @asm.ret
  end

  def fused?(c)
    nxt = c.block.insts[c.block.insts.index(c) + 1]
    nxt&.op == :condbr && nxt.args[0] == c
  end

  def imm?(v) = v.op == :const && (0..4095).cover?(v.args[0])

  def reg(v, tmp = TMP)
    return v.reg if v.reg
    raise "no reg for #{v.op} #{v}" unless v.op == :const
    @asm.mov_imm(tmp, v.args[0]); tmp
  end

  def block(b)
    @asm.label(lbl(b))
    b.insts.each do |i|
      case i.op
      when :const then nil
      when :add, :sub
        l, r = i.args
        if imm?(r) then @asm.send(i.op == :add ? :addi : :subi, i.reg, reg(l), r.args[0])
        else @asm.send(i.op, i.reg, reg(l), reg(r, 9)) end
      when :mul then @asm.mul(i.reg, reg(i.args[0]), reg(i.args[1], 9))
      when :cmp
        l, r = i.args
        imm?(r) ? @asm.cmpi(reg(l), r.args[0]) : @asm.cmp(reg(l), reg(r, 9))
        @asm.cset(i.reg, i.cond) unless fused?(i)
      when :call
        f, *a = i.args
        a.each_with_index { |v, n| v.op == :const ? @asm.mov_imm(n, v.args[0]) : @asm.mov(n, v.reg) }
        @asm.bl(f.name); @asm.mov(i.reg, 0)
      when :puts_i
        v = i.args[0]
        v.op == :const ? @asm.mov_imm(0, v.args[0]) : @asm.mov(0, v.reg)
        @asm.bl(:__puts_i)
      when :puts_s
        s = i.args[0] + "\n"; name = :"str#{i.id}"
        @asm.data(name, s)
        @asm.adr(1, name); @asm.mov_imm(2, s.bytesize); @asm.mov_imm(0, 1)
        @asm.call_write
      when :condbr
        c, t, e = i.args
        phi_moves(b, t); phi_moves(b, e)
        nb = next_block(b)
        if c.op == :cmp && fused?(c)
          if nb == e then @asm.bcond(c.cond, lbl(t))
          else @asm.bcond(Asm::INV[c.cond], lbl(e)); @asm.b(lbl(t)) unless nb == t end
        else
          @asm.cbz(reg(c), lbl(e)); @asm.b(lbl(t)) unless nb == t
        end
      when :br
        phi_moves(b, i.args[0])
        @asm.b(lbl(i.args[0])) unless next_block(b) == i.args[0]
      when :ret
        v = i.args[0]
        if v.op == :const then @asm.mov_imm(0, v.args[0])
        elsif v.reg then @asm.mov(0, v.reg)
        else @asm.mov_imm(0, 0) end # nil-valued (puts, while)
        @asm.b(:"#{@f.name}_ret") unless b == @f.blocks.last
      else raise "codegen: #{i.op}"
      end
    end
  end

  def lbl(b) = :"#{@f.name}_#{b.name}"
  def next_block(b) = @f.blocks[@f.blocks.index(b) + 1]

  def phi_moves(from, to)
    moves = to.phis.filter_map { |p| v = p.args.find { _1[0] == from }&.last; v && [p.reg, v.reg || v] }
    moves.reject! { |(d, s)| d == s }
    until moves.empty?
      ready = moves.find { |(d, _)| moves.none? { |(_, s2)| s2 == d } }
      if ready
        d, s = ready
        s.is_a?(Inst) ? @asm.mov_imm(d, s.args[0]) : @asm.mov(d, s)
        moves.delete(ready)
      else
        _, s = moves.first
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


# ================================================================ driver
module Indus
  # standalone: nil (run in-process via libc write), :darwin or :linux
  def self.compile(src, standalone: nil)
    funcs = Lower.new(src).run
    funcs.each { Passes.run(_1) unless ENV["NOPASS"] }
    $stderr.puts funcs.map(&:dump) if ENV["DUMP"]
    asm = Asm.new
    asm.write_addr = Metal::LIBC["write"].to_i unless standalone
    asm.emit_start_linux if standalone == :linux
    funcs.each { Codegen.new(asm).func(_1) }
    asm.emit_puts_i
    asm.emit_syscalls(standalone) if standalone
    asm.resolve!
  end
end
