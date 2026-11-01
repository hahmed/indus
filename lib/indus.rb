# Indus: Ruby -> SSA -> arm64. See experiments/ for how it got here.
gem "prism", "= 1.8.2" rescue nil
require "prism"
require "fiddle"

# ================================================================ IR
class Inst
  attr_accessor :op, :args, :block, :reg, :cond, :slot, :shared, :ty
  attr_reader :id
  @@n = 0
  def initialize(op, args = [], cond = nil) = (@op, @args, @cond, @id = op, args, cond, @@n += 1)
  def term? = %i[br condbr ret].include?(op)
  def call? = %i[call puts_i puts_s putc anew aset].include?(op)
  def float? = ty == :float
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
  attr_accessor :name, :params, :blocks, :ptypes, :rtype
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
        s << (i.term? ? "  #{i.op} #{a}\n" : "  #{i}#{i.ty ? ":#{i.ty}" : ''} = #{i.op}#{i.cond ? ".#{i.cond}" : ''} #{a}\n")
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
  ARITH = { :+ => :add, :- => :sub, :* => :mul, :/ => :div, :& => :and, :| => :or, :^ => :xor, :<< => :shl, :>> => :shr }

  def initialize(src) = (@ast, @funcs = Prism.parse(src).value, {})

  def run
    defs, top = @ast.statements.body.partition { _1.is_a?(Prism::DefNode) }
    defs.each { |d| @funcs[d.name] = Func.new(d.name, d.parameters&.requireds&.size || 0) }
    main = Func.new(:main, 0)
    lower_body(main, [], top)
    defs.each { |d| lower_body(@funcs[d.name], d.parameters&.requireds&.map(&:name) || [], d.body&.body || []) }
    [main, *@funcs.values].each { prune(_1) }
  end

  # drop blocks unreachable from entry (code after break/return) and the phi
  # edges that came from them
  def prune(f)
    seen = {}; work = [f.entry]
    until work.empty?
      b = work.shift; next if seen[b]
      seen[b] = true; work.concat(b.succs)
    end
    f.blocks.select! { seen[_1] }
    f.blocks.each { |b| b.phis.each { |p| p.args.select! { |(pred, _)| seen[pred] } } }
  end

  private

  def lower_body(f, names, stmts)
    @f, @locals, @cur = f, names.zip(f.params).to_h, f.entry
    last = nil
    stmts.each { last = expr(_1) }
    @cur << Inst.new(:ret, [last || const(0)]) unless @cur.term
  end

  def const(v) = (@cur << Inst.new(:const, [v]))
  def fconst(v) = (@cur << Inst.new(:fconst, [v]))

  def expr(n)
    case n
    when Prism::IntegerNode then const(n.value)
    when Prism::FloatNode then fconst(n.value)
    when Prism::LocalVariableReadNode then @locals.fetch(n.name) { raise "undefined local #{n.name}" }
    when Prism::LocalVariableWriteNode then @locals[n.name] = expr(n.value)
    when Prism::LocalVariableOperatorWriteNode
      l = @locals.fetch(n.name); r = expr(n.value)
      @locals[n.name] = @cur << Inst.new(ARITH.fetch(n.binary_operator), [l, r])
    when Prism::MultiWriteNode # a, b = x, y  (evaluate all, then bind)
      vals = n.value.elements.map { expr(_1) }
      n.lefts.zip(vals).each { |t, v| @locals[t.name] = v }
      vals.last
    when Prism::BreakNode
      raise "break outside loop" unless @loop
      @loop[:breaks] << [@cur, @locals.dup]
      @cur << Inst.new(:br, [@loop[:exit]])
      @cur = @f.new_block(:dead); const(0)
    when Prism::ReturnNode
      v = n.arguments ? expr(n.arguments.arguments[0]) : const(0)
      @cur << Inst.new(:ret, [v])
      @cur = @f.new_block(:dead); const(0)
    when Prism::StatementsNode then n.body.map { expr(_1) }.last
    when Prism::ParenthesesNode then n.body.body.map { expr(_1) }.last
    when Prism::StringNode then n # handled by puts
    when Prism::IfNode then if_expr(n)
    when Prism::WhileNode then while_stmt(n)
    when Prism::CallNode then call(n)
    when Prism::AndNode, Prism::OrNode then bool_expr(n)
    when Prism::IndexTargetNode then raise "unsupported index target"
    else raise "unsupported: #{n.class}"
    end
  end

  # a && b / a || b as a value: control flow + phi
  def bool_expr(n)
    tb, eb, mb = @f.new_block(:bt), @f.new_block(:bf), @f.new_block(:bm)
    cond_branch(n, tb, eb)
    @cur = tb; one = const(1); @cur << Inst.new(:br, [mb])
    @cur = eb; zero = const(0); @cur << Inst.new(:br, [mb])
    @cur = mb; p = mb.phi; p.args = [[tb, one], [eb, zero]]; p
  end

  # branch on a condition without materializing it; && and || short-circuit
  def cond_branch(n, tb, eb)
    case n
    when Prism::AndNode
      mid = @f.new_block(:and); cond_branch(n.left, mid, eb); @cur = mid; cond_branch(n.right, tb, eb)
    when Prism::OrNode
      mid = @f.new_block(:or); cond_branch(n.left, tb, mid); @cur = mid; cond_branch(n.right, tb, eb)
    when Prism::ParenthesesNode then cond_branch(n.body.body.last, tb, eb)
    else
      c = expr(n)
      @cur << Inst.new(:condbr, [c, tb, eb])
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
    elsif n.name == :to_i && args.empty? then @cur << Inst.new(:to_i, [expr(n.receiver)])
    elsif n.name == :to_f && args.empty? then @cur << Inst.new(:to_f, [expr(n.receiver)])
    elsif n.name == :putc
      a = args[0]
      if a.is_a?(Prism::StringNode) then @cur << Inst.new(:putc, [const(a.unescaped.ord)])
      else @cur << Inst.new(:putc, [expr(a)]) end
    elsif n.name == :puts
      a = args[0]
      if a.is_a?(Prism::StringNode) then @cur << Inst.new(:puts_s, [a.unescaped])
      else @cur << Inst.new(:puts_i, [expr(a)]) end
    elsif n.name == :new && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Array
      len = expr(args[0]); fill = args[1] ? expr(args[1]) : const(0)
      @cur << Inst.new(:anew, [len, fill])
    elsif n.name == :[]
      @cur << Inst.new(:aget, [expr(n.receiver), expr(args[0])])
    elsif n.name == :[]=
      # a[i] = v may grow a: the result is the (possibly new) array, rebound to the local
      raise "[]= on non-local receiver" unless n.receiver.is_a?(Prism::LocalVariableReadNode)
      a = expr(n.receiver); i = expr(args[0]); v = expr(args[1])
      @locals[n.receiver.name] = @cur << Inst.new(:aset, [a, i, v])
      v
    else
      f = @funcs.fetch(n.name) { raise "unknown method #{n.name}" }
      @cur << Inst.new(:call, [f, *args.map { expr(_1) }])
    end
  end

  def if_expr(n)
    tb, eb, mb = @f.new_block(:then), @f.new_block(:else), @f.new_block(:merge)
    cond_branch(n.predicate, tb, eb)
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
    cond_branch(n.predicate, bb, xb)
    outer, @loop = @loop, { exit: xb, breaks: [] }
    @cur = bb
    (n.statements&.body || []).each { expr(_1) }
    bend = @cur
    @cur << Inst.new(:br, [hb]) unless @cur.term
    phis.each { |nm, ph| ph.args << [bend, @locals[nm]] }
    breaks = @loop[:breaks]; @loop = outer
    @cur = xb
    # exit sees the header's values, or a break site's
    @locals = breaks.empty? ? phis.dup : merge_locals(xb, [[hb, phis.dup], *breaks])
    const(0)
  end
end

# ================================================================ types
# int / float / iarr / farr, to a fixpoint across functions. Then insert
# int->float conversions where a float meets an int.
module Types
  JOIN = ->(a, b) {
    return b if a.nil?; return a if b.nil?; return a if a == b
    return :float if [a, b].sort == %i[float int]
    return :farr  if [a, b].sort == %i[farr iarr]
    :float
  }
  def self.of(f, v) = v.op == :param ? f.params.index(v).then { f.ptypes[_1] } : v.ty

  def self.run(funcs)
    funcs.each { |f| f.ptypes = Array.new(f.params.size); f.rtype = nil }
    loop do
      changed = false
      funcs.each do |f|
        f.all.each do |i|
          t = infer(f, i)
          next if t.nil? || t == i.ty
          i.ty = JOIN.(i.ty, t); changed = true
          if i.op == :call # arg types -> callee param types
            callee = i.args[0]
            i.args[1..].each_with_index do |a, k|
              at = of(f, a); nt = JOIN.(callee.ptypes[k], at)
              (callee.ptypes[k] = nt; changed = true) if nt != callee.ptypes[k]
            end
          end
        end
        f.all.each do |i| # args and arrays also flow on non-call insts
          case i.op
          when :call
            callee = i.args[0]
            i.args[1..].each_with_index do |a, k|
              nt = JOIN.(callee.ptypes[k], of(f, a)); (callee.ptypes[k] = nt; changed = true) if nt != callee.ptypes[k]
            end
          when :ret
            nt = JOIN.(f.rtype, of(f, i.args[0])); (f.rtype = nt; changed = true) if nt != f.rtype
          when :aset # storing a float into an int array promotes the array
            a, _, v = i.args
            if of(f, v) == :float && of(f, a) == :iarr
              a.op == :param ? f.ptypes[f.params.index(a)] = :farr : a.ty = :farr; changed = true
            end
          end
        end
      end
      break unless changed
    end
    funcs.each { convert(_1) }
  end

  def self.infer(f, i)
    a = i.args
    case i.op
    when :const then :int
    when :fconst then :float
    when :add, :sub, :mul, :div then JOIN.(of(f, a[0]), of(f, a[1]))
    when :and, :or, :xor, :shl, :shr, :cmp, :to_i then :int
    when :to_f then :float
    when :anew then of(f, a[1]) == :float ? :farr : :iarr
    when :aget then { farr: :float, iarr: :int }[of(f, a[0])]
    when :aset then of(f, a[0])
    when :phi then a.map { of(f, _2) }.reduce(nil) { JOIN.(_1, _2) }
    when :call then a[0].rtype
    when :itof then :float
    end
  end

  # insert itof where an int flows into a float position
  def self.convert(f)
    cvt = ->(blk, before, v) {
      c = Inst.new(:itof, [v]); c.ty = :float; c.block = blk
      blk.insts.insert(blk.insts.index(before), c); c
    }
    f.blocks.each do |b|
      b.insts.dup.each do |i|
        case i.op
        when :add, :sub, :mul, :div, :cmp
          next unless i.args.any? { of(f, _1) == :float }
          i.args.map!.with_index { |v, k| of(f, v) == :int ? cvt.(b, i, v) : v }
          i.cond = :"f#{i.cond}" if i.op == :cmp
        when :aset
          a, ix, v = i.args
          i.args[2] = cvt.(b, i, v) if of(f, a) == :farr && of(f, v) == :int
        when :call
          callee = i.args[0]
          i.args[1..].each_with_index { |v, k| i.args[k + 1] = cvt.(b, i, v) if callee.ptypes[k] == :float && of(f, v) == :int }
        when :ret
          i.args[0] = cvt.(b, i, i.args[0]) if f.rtype == :float && of(f, i.args[0]) == :int
        end
      end
      b.phis.each do |p|
        next unless p.ty == :float
        p.args.map! { |(pred, v)| of(f, v) == :int ? [pred, cvt.(pred, pred.term, v)] : [pred, v] }
      end
    end
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
    return false if f.rtype == :float
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
  def and_(rd, rn, rm) = emit(0x8A000000 | (rm << 16) | (rn << 5) | rd)
  def orr(rd, rn, rm) = emit(0xAA000000 | (rm << 16) | (rn << 5) | rd)
  def eor(rd, rn, rm) = emit(0xCA000000 | (rm << 16) | (rn << 5) | rd)
  def lslv(rd, rn, rm) = emit(0x9AC02000 | (rm << 16) | (rn << 5) | rd)
  def asrv(rd, rn, rm) = emit(0x9AC02800 | (rm << 16) | (rn << 5) | rd)
  def ldr_idx(rt, rn, rm) = emit(0xF8607800 | (rm << 16) | (rn << 5) | rt)   # ldr rt,[rn, rm, lsl #3]
  def str_idx(rt, rn, rm) = emit(0xF8207800 | (rm << 16) | (rn << 5) | rt)   # str rt,[rn, rm, lsl #3]
  def ldur(rt, rn, off) = emit(0xF8400000 | ((off & 0x1FF) << 12) | (rn << 5) | rt) # ldr rt,[rn,#simm9]
  def stur(rt, rn, off) = emit(0xF8000000 | ((off & 0x1FF) << 12) | (rn << 5) | rt)
  def bhs(n) = (fix(n, :b19); emit(0x54000002))   # b.hs (unsigned >=): index out of range
  # floats (d registers)
  def fadd(rd, rn, rm) = emit(0x1E602800 | (rm << 16) | (rn << 5) | rd)
  def fsub(rd, rn, rm) = emit(0x1E603800 | (rm << 16) | (rn << 5) | rd)
  def fmul(rd, rn, rm) = emit(0x1E600800 | (rm << 16) | (rn << 5) | rd)
  def fdiv(rd, rn, rm) = emit(0x1E601800 | (rm << 16) | (rn << 5) | rd)
  def fcmp(rn, rm) = emit(0x1E602000 | (rm << 16) | (rn << 5))
  def scvtf(rd, rn) = emit(0x9E620000 | (rn << 5) | rd)      # d <- x
  def fcvtzs(rd, rn) = emit(0x9E780000 | (rn << 5) | rd)     # x <- d (truncate)
  def fmov_dx(rd, rn) = emit(0x9E670000 | (rn << 5) | rd)
  def fmov(rd, rn) = (emit(0x1E604000 | (rn << 5) | rd) unless rd == rn)
  def fldr_idx(rt, rn, rm) = emit(0xFC607800 | (rm << 16) | (rn << 5) | rt)
  def fstr_idx(rt, rn, rm) = emit(0xFC207800 | (rm << 16) | (rn << 5) | rt)
  def fstr(t, off) = emit(0xFD000000 | ((off / 8) << 10) | (31 << 5) | t)
  def fldr(t, off) = emit(0xFD400000 | ((off / 8) << 10) | (31 << 5) | t)
  def fstp(t1, t2, off) = t2 ? emit(0x6D000000 | ((off / 8) << 15) | (t2 << 10) | (31 << 5) | t1) : fstr(t1, off)
  def fldp(t1, t2, off) = t2 ? emit(0x6D400000 | ((off / 8) << 15) | (t2 << 10) | (31 << 5) | t1) : fldr(t1, off)
  def fmov_imm(rd, v) = (mov_imm(8, [v].pack("E").unpack1("Q")); fmov_dx(rd, 8))
  # integer division, Ruby semantics (floor): q = a/b; if r != 0 && (r^b) < 0 then q -= 1
  def sdiv_floor(rd, rn, rm)
    emit(0x9AC00C00 | (rm << 16) | (rn << 5) | rd)                 # sdiv rd, rn, rm
    emit(0x9B008000 | (rm << 16) | (rn << 10) | (rd << 5) | 8)     # msub x8, rd, rm, rn   (r)
    emit(0xCA000000 | (rm << 16) | (8 << 5) | 9)                   # eor x9, x8, rm
    emit(0xF100011F)                                               # cmp x8, #0
    emit(0xFA401924)                                               # ccmp x9, #0, #4, ne
    cset(9, :lt)
    emit(0xCB090000 | (rd << 5) | rd)                              # sub rd, rd, x9
  end
  # putc: x0 = char. strb to stack, write(1, sp+15, 1)
  def emit_putc
    label(:__putc)
    stp_pre(29, 30, 32); mov_fp_sp
    emit 0x390043E0                 # strb w0, [sp, #16]   (above the saved fp/lr pair)
    emit 0x910003E1 | (16 << 10)    # add x1, sp, #16
    emit 0xD2800022                 # mov x2, #1
    emit 0xD2800020                 # mov x0, #1
    call_write
    ldp_post(29, 30, 32); ret
  end
  def uniq = (@u = (@u || 0) + 1; :"L#{@u}")

  HEAP = 28 # bump pointer, reserved; arrays: [cap][len][elems...], handle -> elems

  # x0 = len, x1 = fill -> x0 = handle. cap = len.
  def emit_array_new
    label(:__anew)
    emit 0x91004382             # add x2, x28, #16        handle after the header
    stur(0, 2, -16)             # cap = len
    stur(0, 2, -8)              # len
    emit 0x8B000C5C             # add x28, x2, x0, lsl #3
    emit 0x91003F9C             # add x28, x28, #15
    emit 0x927CEF9C             # and x28, x28, #~15      bump, 16-aligned
    emit 0xD2800003             # mov x3, #0
    l = uniq; d = uniq
    label(l)
    emit 0xEB00007F             # cmp x3, x0
    bhs(d)
    str_idx(1, 2, 3)            # [x2 + x3*8] = fill
    emit 0x91000463             # add x3, x3, #1
    b(l)
    label(d)
    emit 0xAA0203E0             # mov x0, x2
    ret
  end

  # x0 = handle, x1 = i (>= len), x2 = v -> x0 = handle (new one if grown)
  def emit_array_set_slow
    label(:__aset_slow)
    ldur(3, 0, -16)             # cap
    ldur(4, 0, -8)              # len
    emit 0xEB03003F             # cmp x1, x3
    grow = uniq; fill = uniq; store = uniq
    bhs(grow)
    label(fill)                 # fill len..i-1 with nil(0)
    emit 0xEB01009F             # cmp x4, x1
    bhs(store)
    str_idx(31, 0, 4)           # xzr
    emit 0x91000484             # add x4, x4, #1
    b(fill)
    label(store)
    str_idx(2, 0, 1)
    emit 0x91000424             # add x4, x1, #1
    stur(4, 0, -8)              # len = i+1
    ret
    label(grow)                 # newcap = max(cap*2, i+1); copy; then fill/store on the new array
    emit 0xD37FF865             # lsl x5, x3, #1
    emit 0x91000426             # add x6, x1, #1
    emit 0xEB0600BF             # cmp x5, x6
    emit 0x9A8680A5             # csel x5, x5, x6, hi     newcap = max(cap*2, i+1)
    emit 0x91004387             # add x7, x28, #16  (new handle)
    stur(5, 7, -16)             # cap
    stur(4, 7, -8)              # len (same as old)
    emit 0x8B050CFC             # add x28, x7, x5, lsl #3
    emit 0x91003F9C; emit 0x927CEF9C
    emit 0xD2800006             # x6 = 0 (copy index)
    cl = uniq; cd = uniq
    label(cl)
    emit 0xEB0400DF             # cmp x6, x4
    bhs(cd)
    ldr_idx(9, 0, 6); str_idx(9, 7, 6)
    emit 0x910004C6             # add x6, x6, #1
    b(cl)
    label(cd)
    emit 0xAA0703E0             # mov x0, x7
    b(fill)
  end
  def addi(rd, rn, i) = emit(0x91000000 | (i << 10) | (rn << 5) | rd)
  def subi(rd, rn, i) = emit(0xD1000000 | (i << 10) | (rn << 5) | rd)
  def cmp(rn, rm) = emit(0xEB00001F | (rm << 16) | (rn << 5))
  def cmpi(rn, i) = emit(0xF100001F | (i << 10) | (rn << 5))
  COND = { eq: 0x0, ne: 0x1, ge: 0xA, lt: 0xB, gt: 0xC, le: 0xD, mi: 0x4, pl: 0x5, ls: 0x9, hi: 0x8,
           # float compares: unordered must be false for < <= (mi/ls), true for != (ne)
           feq: 0x0, fne: 0x1, flt: 0x4, fle: 0x9, fgt: 0xC, fge: 0xA }
  INV = { eq: :ne, ne: :eq, ge: :lt, lt: :ge, gt: :le, le: :gt, mi: :pl, pl: :mi, ls: :hi, hi: :ls,
          feq: :fne, fne: :feq, flt: :pl, fle: :hi, fgt: :fle_u, fge: :flt_u }
  COND[:fle_u] = 0xD; COND[:flt_u] = 0xB # le / lt (true on unordered), the inverses of gt / ge
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
    label(:_start)
    # mmap(NULL, 256MB, PROT_READ|WRITE, MAP_PRIVATE|ANON, -1, 0) -> x0
    emit 0xD2800000             # mov x0, #0
    emit 0xD2A20001             # mov x1, #0x10000000
    emit 0xD2800062             # mov x2, #3
    emit 0xD2800443             # mov x3, #0x22
    emit 0x92800004             # mov x4, #-1
    emit 0xD2800005             # mov x5, #0
    emit 0xD2801BC8             # mov x8, #222
    emit 0xD4000001             # svc #0
    bl(:main)
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
  CALLEE = (19..27).to_a # x28 = heap
  CALLER = (10..15).to_a # x8, x9 scratch
  FCALLEE = (8..15).to_a  # d8-d15
  FCALLER = (16..29).to_a # d30, d31 scratch
  TMP = 8; FTMP = 30; FTMP2 = 31

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
    # loops: a value defined before a loop and used inside it is live to the loop's end
    loops = f.blocks.filter_map do |h|
      next if h.phis.empty?
      back = f.blocks.select { |b| b.succs.include?(h) && idx[b.term] > idx[h.phis.first] }
      [idx[h.phis.first], back.map { idx[_1.term] }.max] unless back.empty?
    end
    loop do
      changed = false
      (f.params + all).each do |v|
        d = idx[v]
        loops.each do |(ls, le)|
          if d < ls && last[v] >= ls && last[v] < le then last[v] = le; changed = true end
        end
      end
      break unless changed
    end

    call_at = all.each_index.select { all[_1].call? }
    across = ->(v, from) { call_at.any? { |c| c > from && c < last[v] } }
    callee, caller = CALLEE.dup, CALLER.dup; used = []; freed = []
    fcallee, fcaller = FCALLEE.dup, FCALLER.dup; fused = []
    nslots = 0
    assign = ->(v, pool) {
      if v.float?
        pool = pool.equal?(callee) ? fcallee : fcaller
        r = pool.shift || (pool.equal?(fcallee) ? fcaller : fcallee).shift
        if r then fused |= [r] if FCALLEE.include?(r); v.reg = r
        else v.slot = nslots; nslots += 1 end
        next
      end
      r = pool.shift || (pool.equal?(callee) ? caller : callee).shift
      if r then used |= [r] if CALLEE.include?(r); v.reg = r
      else v.slot = nslots; nslots += 1 end # spill to the frame
    }
    phi_srcs = phis.flat_map { |p| p.args.map(&:last) }
    f.params.each_with_index { |p, k| p.ty = f.ptypes[k] || :int }
    f.params.each { |p| assign.(p, (across.(p, -1) || phi_srcs.include?(p)) ? callee : caller) }
    phis.each do |ph|
      src = ph.args.map(&:last).find { |v| v.op == :param && last[v] <= idx[ph] && phi_srcs.count(v) == 1 }
      if src then ph.reg = src.reg; src.shared = true
      else assign.(ph, across.(ph, idx[ph.block.insts.first] - 1) || across.(ph, -1) ? callee : caller) end
    end
    phis.each do |ph|
      ph.args.each do |(pred, v)|
        next unless v.is_a?(Inst) && !v.reg && !%i[param phi const].include?(v.op) && v.block == pred
        next unless last[v] == idx[pred.term]
        after = pred.insts[(pred.insts.index(v) + 1)..].any? { |j| j.args.include?(ph) }
        (v.reg = ph.reg; v.shared = true) unless after || ph.reg.nil?
      end
    end
    all.each_with_index do |i, k|
      expired = (f.params + all[0...k]).select { |v| v.reg && !v.shared && last[v] < k && !freed.include?(v) }
      expired.each do |v|
        freed << v
        if v.float? then (FCALLEE.include?(v.reg) ? fcallee : fcaller).unshift(v.reg)
        else (CALLEE.include?(v.reg) ? callee : caller).unshift(v.reg) end
      end
      next if i.reg || i.slot || i.term? || i.op == :phi || i.op == :const || i.op == :fconst || i.op == :puts_s || i.op == :puts_i || i.op == :putc
      next if i.op == :cmp && fused?(i)
      assign.(i, across.(i, k) ? callee : caller)
    end

    used |= [Asm::HEAP] if f.name == :main
    used.sort!; fused.sort!
    fsave = 16 + ((used.size + 1) / 2) * 16
    @spill_base = fsave + ((fused.size + 1) / 2) * 16
    frame = @spill_base + ((nslots + 1) / 2) * 16
    raise "frame too large" if frame > 504
    @asm.label(f.name)
    @asm.stp_pre(29, 30, frame); @asm.mov_fp_sp
    used.each_slice(2).with_index { |(a, b), i| @asm.stp(a, b, 16 + i * 16) }
    fused.each_slice(2).with_index { |(a, b), i| @asm.fstp(a, b, fsave + i * 16) }
    @asm.mov(Asm::HEAP, 0) if f.name == :main # heap base arrives in x0
    # params: ints in x0.., floats in d0.. (separate counters, AAPCS64)
    xi = fi = 0
    f.params.each { |p| p.float? ? (@asm.fmov(p.reg, fi); fi += 1) : (@asm.mov(p.reg, xi); xi += 1) }
    f.blocks.each { block(_1) }
    @asm.label(:"#{f.name}_ret")
    fused.each_slice(2).with_index { |(a, b), i| @asm.fldp(a, b, fsave + i * 16) }
    used.each_slice(2).with_index { |(a, b), i| @asm.ldp(a, b, 16 + i * 16) }
    @asm.ldp_post(29, 30, frame); @asm.ret
  end

  def fused?(c)
    nxt = c.block.insts[c.block.insts.index(c) + 1]
    nxt&.op == :condbr && nxt.args[0] == c
  end

  def imm?(v) = v.op == :const && (0..4095).cover?(v.args[0])

  SPILL = 17 # scratch for a spilled definition (x16/x17 are free between calls)

  def slot_off(v) = @spill_base + 8 * v.slot

  # a value in a register, loading a constant or a spilled value into tmp
  def reg(v, tmp = TMP)
    return freg(v, tmp == TMP ? FTMP : FTMP2) if v.float?
    return v.reg if v.reg
    return (@asm.ldr(tmp, slot_off(v)); tmp) if v.slot
    raise "no reg for #{v.op} #{v}" unless v.op == :const
    @asm.mov_imm(tmp, v.args[0]); tmp
  end
  def freg(v, tmp = FTMP)
    return v.reg if v.reg
    return (@asm.fldr(tmp, slot_off(v)); tmp) if v.slot
    raise "no freg for #{v.op} #{v}" unless v.op == :fconst
    @asm.fmov_imm(tmp, v.args[0]); tmp
  end

  # where a definition is written; stored to its slot afterwards if spilled
  def dst(i) = i.reg || (i.float? ? FTMP : SPILL)
  def spill!(i)
    return unless i.slot
    i.float? ? @asm.fstr(FTMP, slot_off(i)) : @asm.str(SPILL, slot_off(i))
  end

  def block(b)
    @asm.label(lbl(b))
    b.insts.each do |i|
      d = dst(i)
      case i.op
      when :const, :fconst then nil
      when :add, :sub, :mul, :div
        l, r = i.args
        if i.float?
          @asm.send({ add: :fadd, sub: :fsub, mul: :fmul, div: :fdiv }[i.op], d, freg(l), freg(r, FTMP2))
        elsif i.op == :div then @asm.sdiv_floor(d, reg(l), reg(r, 9))
        elsif i.op == :mul then @asm.mul(d, reg(l), reg(r, 9))
        elsif imm?(r) then @asm.send(i.op == :add ? :addi : :subi, d, reg(l), r.args[0])
        else @asm.send(i.op, d, reg(l), reg(r, 9)) end
      when :itof then @asm.scvtf(d, reg(i.args[0]))
      when :to_f then @asm.scvtf(d, reg(i.args[0]))
      when :to_i then i.args[0].float? ? @asm.fcvtzs(d, freg(i.args[0])) : @asm.mov(d, reg(i.args[0]))
      when :putc
        @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:__putc)
      when :and then @asm.and_(d, reg(i.args[0]), reg(i.args[1], 9))
      when :or  then @asm.orr(d, reg(i.args[0]), reg(i.args[1], 9))
      when :xor then @asm.eor(d, reg(i.args[0]), reg(i.args[1], 9))
      when :shl then @asm.lslv(d, reg(i.args[0]), reg(i.args[1], 9))
      when :shr then @asm.asrv(d, reg(i.args[0]), reg(i.args[1], 9))
      when :anew
        l, v = i.args
        @asm.mov(0, reg(l, 0))
        v.float? ? @asm.emit(0x9E660000 | (freg(v) << 5) | 1) : @asm.mov(1, reg(v, 1)) # fmov x1, d
        @asm.bl(:__anew); @asm.mov(d, 0)
      when :aget # out of range (incl. negative, via unsigned compare) -> nil (0)
        a, ix = i.args; ra = reg(a); ri = reg(ix, 9)
        @asm.ldur(16, ra, -8); @asm.cmp(ri, 16)      # x16: len (x8/x9 may hold ra/ri)
        skip = @asm.uniq
        if i.float? then @asm.fmov_imm(d, 0.0); @asm.bhs(skip); @asm.fldr_idx(d, ra, ri)
        else @asm.mov_imm(d, 0); @asm.bhs(skip); @asm.ldr_idx(d, ra, ri) end
        @asm.label(skip)
      when :aset # in range: store; else slow path (fill / grow) which returns the handle
        a, ix, v = i.args
        @asm.mov(0, reg(a, 0)); @asm.mov(1, reg(ix, 1))
        v.float? ? @asm.emit(0x9E660000 | (freg(v) << 5) | 2) : @asm.mov(2, reg(v, 2)) # fmov x2, d
        @asm.ldur(TMP, 0, -8); @asm.cmp(1, TMP)
        slow = @asm.uniq; done = @asm.uniq
        @asm.bhs(slow); @asm.str_idx(2, 0, 1); @asm.b(done)
        @asm.label(slow); @asm.bl(:__aset_slow)
        @asm.label(done); @asm.mov(d, 0)
      when :cmp
        l, r = i.args
        if l.float? then @asm.fcmp(freg(l), freg(r, FTMP2))
        elsif imm?(r) then @asm.cmpi(reg(l), r.args[0])
        else @asm.cmp(reg(l), reg(r, 9)) end
        @asm.cset(d, i.cond) unless fused?(i)
      when :call
        f, *a = i.args
        xi = fi = 0
        a.each { |v| v.float? ? (@asm.fmov(fi, freg(v, fi)); fi += 1) : (@asm.mov(xi, reg(v, xi)); xi += 1) }
        @asm.bl(f.name)
        i.float? ? @asm.fmov(d, 0) : @asm.mov(d, 0)
      when :puts_i
        @asm.mov(0, reg(i.args[0], 0))
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
        if v.float? then @asm.fmov(0, freg(v, 0))
        elsif v.reg || v.slot || v.op == :const then @asm.mov(0, reg(v, 0))
        else @asm.mov_imm(0, 0) end # nil-valued (puts, while)
        @asm.b(:"#{@f.name}_ret") unless b == @f.blocks.last
      else raise "codegen: #{i.op}"
      end
      spill!(i)
    end
  end

  def lbl(b) = :"#{@f.name}_#{b.name}"
  def next_block(b) = @f.blocks[@f.blocks.index(b) + 1]

  # parallel copy for the phis of `to` along the edge from `from`.
  # locations: Integer register, [:slot, n], or a const Inst (source only)
  def loc(v) = v.reg ? (v.float? ? [:f, v.reg] : v.reg) : (v.slot ? [:slot, v.slot] : v)
  def move(d, s)
    if (d.is_a?(Array) && d[0] == :f) || (s.is_a?(Array) && s[0] == :f) || (s.is_a?(Inst) && s.float?) || (s.is_a?(Inst) && s.op == :fconst)
      sreg = case s
             when Array then s[0] == :f ? s[1] : (@asm.fldr(FTMP, @spill_base + 8 * s[1]); FTMP)
             when Inst then @asm.fmov_imm(FTMP, s.args[0]); FTMP
             else s
             end
      d.is_a?(Array) && d[0] == :f ? @asm.fmov(d[1], sreg) : @asm.fstr(sreg, @spill_base + 8 * d[1])
      return
    end
    sreg = case s
           when Integer then s
           when Inst then @asm.mov_imm(TMP, s.args[0]); TMP
           else @asm.ldr(TMP, @spill_base + 8 * s[1]); TMP
           end
    d.is_a?(Integer) ? @asm.mov(d, sreg) : @asm.str(sreg, @spill_base + 8 * d[1])
  end
  def phi_moves(from, to)
    moves = to.phis.filter_map { |p| v = p.args.find { _1[0] == from }&.last; v && [loc(p), loc(v)] }
    moves.reject! { |(d, s)| d == s }
    until moves.empty?
      ready = moves.find { |(d, _)| moves.none? { |(_, s2)| s2 == d } }
      if ready
        move(*ready); moves.delete(ready)
      else # cycle: park one source in x9 / d31
        _, s = moves.first
        park = (s.is_a?(Array) && s[0] == :f) ? [:f, FTMP2] : 9
        move(park, s); moves.map! { |(dd, ss)| [dd, ss == s ? park : ss] }
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
    heap = MMAP.call(nil, 1 << 28, 3, 0x1002, -1, 0)
    Fiddle::Function.new(mem, [Fiddle::TYPE_VOIDP], Fiddle::TYPE_LONG).call(heap)
  end
end


# ================================================================ driver
module Indus
  # standalone: nil (run in-process via libc write), :darwin or :linux
  def self.compile(src, standalone: nil)
    funcs = Lower.new(src).run
    Types.run(funcs)
    funcs.each { Passes.run(_1) unless ENV["NOPASS"] }
    $stderr.puts funcs.map(&:dump) if ENV["DUMP"]
    asm = Asm.new
    asm.write_addr = Metal::LIBC["write"].to_i unless standalone
    asm.emit_start_linux if standalone == :linux
    funcs.each { Codegen.new(asm).func(_1) }
    asm.emit_puts_i
    asm.emit_putc
    asm.emit_array_new
    asm.emit_array_set_slow
    asm.emit_syscalls(standalone) if standalone
    asm.resolve!
  end
end
