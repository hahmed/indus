# Prism AST -> SSA. Locals are a name->value map per program point.
module Indus
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
end
