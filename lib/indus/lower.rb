# Prism AST -> SSA. Locals are a name->value map per program point.
module Indus
  # Locals are a name->value map per program point. `while` makes a phi per
  # live local at the header; `if` makes a phi per local that differs at the
  # merge. Trivial phis are removed afterwards.
  class Lower
    CMP = { :== => :eq, :!= => :ne, :< => :lt, :<= => :le, :> => :gt, :>= => :ge }
    ARITH = { :+ => :add, :- => :sub, :* => :mul, :/ => :div, :% => :mod, :& => :and, :| => :or, :^ => :xor, :<< => :shl, :>> => :shr }

    attr_reader :classes, :syms
    # symbols are small integers, interned at compile time
    def sym_id(name) = (@syms ||= {})[name.to_sym] ||= @syms.size + 1

    def initialize(src) = (@ast, @funcs, @classes, @consts = Prism.parse(src).value, {}, {}, {})

    def run
      body = @ast.statements.body
      # modules are namespaces: hoist their classes and constants to the top level
      mods = body.grep(Prism::ModuleNode)
      mod_classes = mods.flat_map { |m| (m.body&.body || []).grep(Prism::ClassNode) }
      mod_consts = mods.flat_map { |m| (m.body&.body || []).grep(Prism::ConstantWriteNode) }
      defs = body.grep(Prism::DefNode)
      cdefs = body.grep(Prism::ClassNode) + mod_classes
      top = (body - defs - cdefs - mods) 
      top = mod_consts + top
      # methods that take a block (contain yield) are inlined at call sites with a literal block;
      # they still get compiled as functions for block-less callers
      @yielders = {} # name -> [klass or nil, def]
      defs.each { |d| @yielders[d.name] = [nil, d] if yields?(d) }
      @defs_by_func = {}
      defs.each do |d|
        next if yields?(d)
        f = @funcs[d.name] = Func.new(d.name, (d.parameters&.requireds&.size || 0) + (d.parameters&.optionals&.size || 0))
        @defs_by_func[f] = d
      end
      methods = [] # [klass, def, func]
      cdefs.each do |c|
        sup = c.superclass && @classes.fetch(c.superclass.name) { raise "superclass #{c.superclass.name} must be defined first" }
        k = @classes[c.constant_path.name] = Klass.new(c.constant_path.name, sup)
        k.id = @classes.size
        (c.body&.body || []).each do |st|
          case st
          when Prism::DefNode
            if yields?(st) then @yielders[st.name] = [k, st]; next end # inlined only
            f = Func.new(:"#{k.name}##{st.name}", 1 + (st.parameters&.requireds&.size || 0) + (st.parameters&.rest ? 1 : 0))
            f.rest = true if st.parameters&.rest
            f.cls = k; k.methods[st.name] = f; methods << [k, st, f]
          when Prism::CallNode
            class_body_call(k, st, {}, methods)
          else raise "unsupported in class body: #{st.class}"
          end
        end
      end
      @pre = Pretype.new(@ast, @classes) # receiver kinds for the structural decisions below
      main = Func.new(:main, 0)
      lower_body(main, [], top)
      defs.each { |d| lower_body(@funcs[d.name], (d.parameters&.requireds&.map(&:name) || []) + (d.parameters&.optionals&.map(&:name) || []), d.body&.body || []) if @funcs[d.name] }
      methods.each do |k, d, f, names, body, ct|
        if d
          names = [:self, *(d.parameters&.requireds&.map(&:name) || [])]
          names << d.parameters.rest.name if d.parameters&.rest # *args arrives as an array
          lower_body(f, names, d.body&.body || [], k)
        else
          lower_body(f, names, body, k, ct)
        end
      end
      all = [main, *@funcs.values, *methods.map { _1[2] }]
      all.each { prune(_1) }
      all
    end

    # the resident compiler: lower one `def` from a string into a Func that
    # replaces `old` (same class, same signature)
    def lower_method(klass, def_node, old)
      f = Func.new(old.name, old.params.size)
      f.cls = klass; f.ptypes = old.ptypes.dup; f.rtype = old.rtype
      lower_body(f, [:self, *(def_node.parameters&.requireds&.map(&:name) || [])], def_node.body&.body || [], klass)
      prune(f)
      f
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

    # Class-body metaprogramming is evaluated at compile time. `ct` is the
    # compile-time environment: block variables bound to literal symbols by
    # an unrolled `[:a, :b].each do |f| ... end`.
    def class_body_call(k, st, ct, methods)
      args = st.arguments&.arguments || []
      case st.name
      when :attr_accessor, :attr_reader, :attr_writer
        args.each do |sym|
          n = ct_symbol(sym, ct); k.ivar(:"@#{n}")
          k.readers[n] = :"@#{n}" if %i[attr_accessor attr_reader].include?(st.name)
          k.writers[:"#{n}="] = :"@#{n}" if %i[attr_accessor attr_writer].include?(st.name)
        end
      when :define_method
        name = ct_symbol(args[0], ct)
        blk = st.block or raise "define_method without a block"
        params = blk.parameters&.parameters&.requireds&.map(&:name) || []
        f = Func.new(:"#{k.name}##{name}", 1 + params.size)
        f.cls = k; k.methods[name] = f
        methods << [k, nil, f, [:self, *params], blk.body&.body || [], ct.dup]
      when :each # [:a, :b].each do |f| ... end  -> unrolled at compile time
        recv = st.receiver
        raise "class-body each over a non-literal array" unless recv.is_a?(Prism::ArrayNode)
        blk = st.block; var = blk.parameters.parameters.requireds[0].name
        recv.elements.each do |el|
          env = ct.merge(var => ct_symbol(el, ct))
          (blk.body&.body || []).each { |inner| class_body_call(k, inner, env, methods) }
        end
      else raise "unsupported in class body: #{st.name}"
      end
    end

    # a Symbol known at compile time: literal, interpolated from ct, or a ct variable
    def ct_symbol(node, ct)
      case node
      when Prism::SymbolNode then node.unescaped.to_sym
      when Prism::StringNode then node.unescaped.to_sym
      when Prism::LocalVariableReadNode then ct.fetch(node.name) { raise "#{node.name} is not a compile-time symbol" }
      when Prism::InterpolatedSymbolNode
        node.parts.map do |part|
          case part
          when Prism::StringNode then part.unescaped
          when Prism::EmbeddedStatementsNode then ct_symbol(part.statements.body.last, ct).to_s
          end
        end.join.to_sym
      else raise "not a compile-time symbol: #{node.class}"
      end
    end

    def lower_body(f, names, stmts, klass = nil, ct = {})
      @f, @locals, @cur, @klass, @ct = f, names.zip(f.params).to_h, f.entry, klass, ct
      last = nil
      stmts.each { last = expr(_1) }
      emit(:ret, [last || const(0)]) unless @cur.term
    end

    # a local's key: a block parameter (innermost block first), an inlined
    # callee's local, or the plain name
    def lname(name)
      (@blk_pfx || []).reverse_each { |pfx| k = :"#{pfx}#{name}"; return k if @locals.key?(k) }
      return :"#{@name_pfx}#{name}" if @name_pfx
      name
    end
    # a syntactic guess at what a node evaluates to, for choosing between a
    # builtin iterator and a user yield-method at lowering time:
    # :array, :range, :int, :str, a class name, or nil (unknown)
    def kind_of(n)
      if @pre && (k = @pre[n])
        return :array if k.is_a?(Array) && k[0] == :array
        return :range if k == [:range]
        return k if k.is_a?(Symbol) && (@classes[k] || %i[int str].include?(k))
      end
      syntactic_kind(n)
    end

    # the old guess, kept as a fallback for nodes the pre-typing has no answer for
    def syntactic_kind(n)
      case n
      when Prism::ArrayNode then :array
      when Prism::RangeNode then :range
      when Prism::IntegerNode then :int
      when Prism::StringNode, Prism::InterpolatedStringNode then :str
      when Prism::ParenthesesNode then kind_of(n.body.body.last)
      when Prism::LocalVariableReadNode then (@kinds || {})[lname(n.name)]
      when Prism::InstanceVariableReadNode then (@ivar_kinds || {})[[@klass&.name, n.name]]
      when Prism::CallNode
        if n.name == :new && n.receiver.is_a?(Prism::ConstantReadNode)
          n.receiver.name == :Array ? :array : (@classes[n.receiver.name] ? n.receiver.name : nil)
        elsif %i[map keys to_a].include?(n.name) then :array
        elsif n.name == :to_s then :str
        end
      end
    end

    def me_val = @name_pfx ? @locals.fetch(:"#{@name_pfx}self") : @locals.fetch(:self)
    # append to the *current* block after the arguments have been evaluated
    # (lowering an argument may move @cur: loops, inlining)
    def emit(op, args = [], cond = nil) = (@cur << Inst.new(op, args, cond))
    def const(v) = emit(:const, [v])
    def yields?(d) = d.body && d.body.body.any? { |st| contains_yield?(st) }
    def contains_yield?(node)
      return false unless node.is_a?(Prism::Node)
      return true if node.is_a?(Prism::YieldNode)
      node.compact_child_nodes.any? { contains_yield?(_1) }
    end
    # x.to_s: strings pass through, integers convert; resolved after typing for others
    def to_s(v) = (emit(:to_s, [v]))
    def fconst(v) = (emit(:fconst, [v]))

    def expr(n)
      case n
      when Prism::IntegerNode then const(n.value)
      when Prism::FloatNode then fconst(n.value)
      when Prism::NilNode then (c = const(0); c.ty = :nil; c)
      when Prism::TrueNode then (c = const(1); c.ty = :bool; c)
      when Prism::FalseNode then (c = const(0); c.ty = :bool; c)
      when Prism::UnlessNode then if_expr(n, negate: true)
      when Prism::UntilNode then while_stmt(n, negate: true)
      when Prism::CaseNode then case_expr(n)
      when Prism::LambdaNode then lambda_value(n)
      when Prism::ConstantPathNode then expr_const_path(n)
      when Prism::ModuleNode then raise "module in expression position"
      when Prism::LocalVariableOrWriteNode # x ||= v
        cur = @locals[lname(n.name)]
        if cur.nil? || cur.ty == :nil then (v = expr(n.value); @locals[lname(n.name)] = v)
        else cond_assign(cur, false, -> { expr(n.value) }, ->(v) { @locals[lname(n.name)] = v }) end
      when Prism::LocalVariableAndWriteNode # x &&= v
        cond_assign(@locals.fetch(lname(n.name)), true, -> { expr(n.value) }, ->(v) { @locals[lname(n.name)] = v })
      when Prism::IndexOrWriteNode # h[k] ||= v
        recv = expr(n.receiver); k = expr(n.arguments.arguments[0])
        cur = emit(:idx, [recv, k])
        cond_assign(cur, false, -> { expr(n.value) }, ->(v) {
          r = emit(:idx_set, [recv, k, v])
          @locals[lname(n.receiver.name)] = r if n.receiver.is_a?(Prism::LocalVariableReadNode) })
      when Prism::SelfNode then me_val
      when Prism::ArrayNode
        fill = const(0); fill.ty = :nil # element type comes from the first store
        a = emit(:anew, [const(n.elements.size), fill])
        n.elements.each_with_index { |e, k| a = emit(:aset, [a, const(k), expr(e)]) }
        a
      when Prism::HashNode
        h = emit(:hnew, [])
        n.elements.each do |el|
          raise "unsupported hash element #{el.class}" unless el.is_a?(Prism::AssocNode)
          h = emit(:hset, [h, expr(el.key), expr(el.value)])
        end
        h
      when Prism::InstanceVariableReadNode then emit(:fld_get, [me_val, @klass.ivar(n.name)])
      when Prism::InstanceVariableWriteNode
        v = expr(n.value)
        ((@ivar_kinds ||= {})[[@klass&.name, n.name]] ||= kind_of(n.value)) if @klass
        emit(:fld_set, [me_val, @klass.ivar(n.name), v]); v
      when Prism::ConstantReadNode
        if n.name == :ARGV then (c = const(0); c.ty = :nil; c) # no arguments: every ARGV[k] is nil
        else emit(:gget, [n.name]) end
      when Prism::ConstantWriteNode
        v = expr(n.value); emit(:gset, [n.name, v]); v
      when Prism::LocalVariableReadNode
        if @ct&.key?(n.name) then (c = const(sym_id(@ct[n.name])); c.ty = :sym; c) # compile-time symbol
        else @locals.fetch(lname(n.name)) { raise "undefined local #{n.name}" } end
      when Prism::LocalVariableWriteNode
        if n.value.is_a?(Prism::LambdaNode) # a lambda is inlined at its call sites
          (@lambdas ||= {})[lname(n.name)] = n.value
          return const(0)
        end
        v = expr(n.value) # value first: loops replace @locals
        (@kinds ||= {})[lname(n.name)] = kind_of(n.value)
        @locals[lname(n.name)] = v
      when Prism::LocalVariableOperatorWriteNode
        l = @locals.fetch(lname(n.name)); r = expr(n.value)
        @locals[lname(n.name)] = emit(ARITH.fetch(n.binary_operator), [l, r])
      when Prism::MultiWriteNode # a, b = x, y  (evaluate all, then bind)
        vals = n.value.elements.map { expr(_1) }
        n.lefts.zip(vals).each { |t, v| @locals[t.name] = v }
        vals.last
      when Prism::BreakNode
        raise "break outside loop" unless @loop
        @loop[:breaks] << [@cur, @locals.dup]
        emit(:br, [@loop[:exit]])
        @cur = @f.new_block(:dead); const(0)
      when Prism::ReturnNode
        v = n.arguments ? expr(n.arguments.arguments[0]) : const(0)
        if @ret_exit # returning from an inlined callee: jump to its exit with the value
          @ret_exit[:arms] << [@cur, @locals.dup, v]
          emit(:br, [@ret_exit[:block]])
        else
          emit(:ret, [v])
        end
        @cur = @f.new_block(:dead); const(0)
      when Prism::StatementsNode then n.body.map { expr(_1) }.last
      when Prism::NextNode
        raise "next outside a block" unless @loop&.[](:next)
        @loop[:nexts] << [@cur, @locals.dup]
        emit(:br, [@loop[:next]])
        @cur = @f.new_block(:dead); const(0)
      when Prism::YieldNode
        raise "yield outside an inlined block method" unless @block
        yield_block(n.arguments&.arguments || [])
      when Prism::RangeNode then raise "a Range is only supported as the receiver of each/map"
      when Prism::SymbolNode then (c = const(sym_id(n.unescaped)); c.ty = :sym; c)
      when Prism::ParenthesesNode then n.body.body.map { expr(_1) }.last
      when Prism::StringNode then emit(:sconst, [n.unescaped])
      when Prism::InterpolatedStringNode # "a#{x}b" -> concat chain
        parts = n.parts.map do |part|
          case part
          when Prism::StringNode then emit(:sconst, [part.unescaped])
          when Prism::EmbeddedStatementsNode then to_s(expr(part.statements.body.last))
          else raise "unsupported interpolation part #{part.class}"
          end
        end
        parts.reduce { |a, b| emit(:scat, [a, b]) }
      when Prism::IfNode then if_expr(n)
      when Prism::WhileNode then while_stmt(n)
      when Prism::CallNode then call(n)
      when Prism::OrNode
        l = expr(n.left)
        if l.ty == :nil then expr(n.right)                       # nil || y  ->  y, at compile time
        else or_value(l) { expr(n.right) } end
      when Prism::AndNode then bool_expr(n)
      when Prism::IndexTargetNode then raise "unsupported index target"
      else raise "unsupported: #{n.class}"
      end
    end

    # l || <right>: l if truthy else right, as a value
    def or_value(l)
      tb, eb, mb = @f.new_block(:ort), @f.new_block(:orf), @f.new_block(:orm)
      emit(:condbr, [l, tb, eb])
      @cur = tb; emit(:br, [mb])
      before = @locals.dup
      @cur = eb; r = yield; eend, el = @cur, @locals; emit(:br, [mb])
      @cur = mb; @locals = merge_locals(mb, [[tb, before], [eend, el]])
      p = mb.phi; p.args = [[tb, l], [eend, r]]; p
    end

    # a && b / a || b as a value: control flow + phi
    def bool_expr(n)
      tb, eb, mb = @f.new_block(:bt), @f.new_block(:bf), @f.new_block(:bm)
      cond_branch(n, tb, eb)
      @cur = tb; one = const(1); one.ty = :bool; emit(:br, [mb])
      @cur = eb; zero = const(0); zero.ty = :bool; emit(:br, [mb])
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
        emit(:condbr, [c, tb, eb])
      end
    end

    def call(n)
      args = n.arguments&.arguments || []
      return block_call(n, args) if n.block.is_a?(Prism::BlockNode)
      if n.name == :<< && n.receiver.is_a?(Prism::LocalVariableReadNode) && !@int_locals&.include?(n.receiver.name)
        # `<<` is append on strings/arrays and shift on integers; Types fixes up a misguess
        a = expr(n.receiver); v = expr(args[0])
        return @locals[n.receiver.name] = emit(:lshift_or_append, [a, v])
      elsif n.name == :<< && n.receiver.is_a?(Prism::InstanceVariableReadNode)
        a = expr(n.receiver); v = expr(args[0])
        r = emit(:lshift_or_append, [a, v])
        emit(:fld_set, [@locals.fetch(:self), @klass.ivar(n.receiver.name), r]); return r
      end
      if n.receiver.nil? && n.name.to_s.start_with?("__") && !@funcs[n.name] && !(@klass && @klass.find_method(n.name))
        return intrinsic(n.name, args) # the GC prelude's raw memory access
      end
      if n.name == :! && args.empty?
        v = expr(n.receiver)
        return emit(:cmp, [v, const(0)], :eq) # !x : true iff x is nil/false (0)
      end
      if n.name == :call && n.receiver.is_a?(Prism::LocalVariableReadNode) && (@lambdas || {})[lname(n.receiver.name)]
        return inline_lambda(@lambdas[lname(n.receiver.name)], args)
      end
      if n.name == :send || n.name == :public_send
        name, *rest = args
        recv_v = n.receiver ? expr(n.receiver) : me_val
        if name.is_a?(Prism::SymbolNode) # send(:literal) is a plain call
          return emit(:mcall, [name.unescaped.to_sym, recv_v, *rest.map { expr(_1) }])
        end
        return emit(:dsend, [expr(name), recv_v, *rest.map { expr(_1) }]) # switch over the class's methods
      end
      if (op = ARITH[n.name])
        l = expr(n.receiver); r = expr(args[0])
        emit(op, [l, r])
      elsif (c = CMP[n.name])
        l = expr(n.receiver); r = expr(args[0])
        emit(:cmp, [l, r], c)
      elsif n.name == :to_i && args.empty? then emit(:to_i, [expr(n.receiver)])
      elsif n.name == :to_f && args.empty? then emit(:to_f, [expr(n.receiver)])
      elsif n.name == :putc
        a = args[0]
        if a.is_a?(Prism::StringNode) then emit(:putc, [const(a.unescaped.ord)])
        else emit(:putc, [expr(a)]) end
      elsif n.name == :puts
        a = args[0]
        if a.is_a?(Prism::StringNode) then emit(:puts_s, [a.unescaped])
        else emit(:puts_v, [expr(a)]) end # Types picks puts_i / puts_str
      elsif n.name == :p && n.receiver.nil? && args.size == 1
        emit(:p_v, [expr(args[0])])       # inspect form: strings quoted, nil as "nil"
      elsif n.name == :print && n.receiver.nil? && args.size == 1
        emit(:print_v, [expr(args[0])])   # no newline
      elsif n.name == :Integer && n.receiver.nil? && args.size == 1
        emit(:to_i, [expr(args[0])])      # Integer(x): the parse, no exception on junk (yet)
      elsif n.name == :nil? && args.empty? && n.receiver
        v = expr(n.receiver); emit(:cmp, [v, (c = const(0); c.ty = :nil; c)], :eq)
      elsif n.name == :to_s && args.empty? then to_s(expr(n.receiver))
      elsif n.name == :+@ && args.empty? then expr(n.receiver) # +"" : literals are already fresh copies
      elsif n.name == :new && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Array
        len = expr(args[0]); fill = args[1] ? expr(args[1]) : const(0)
        emit(:anew, [len, fill])
      elsif n.name == :new && (n.receiver.is_a?(Prism::ConstantReadNode) || n.receiver.is_a?(Prism::ConstantPathNode)) && @classes[n.receiver.name]
        k = @classes[n.receiver.name]
        obj = emit(:onew, [k])
        if (init = k.find_method(:initialize))
          emit(:call, [init, obj, *args.map { expr(_1) }])
        end
        obj
      elsif n.name == :class_eval && n.receiver.is_a?(Prism::ConstantReadNode) && @classes[n.receiver.name]
        # a puncture: the methods this string defines can change at run time.
        # They are called through a slot from here on; nothing else changes.
        k = @classes[n.receiver.name]
        src = args[0]
        raise "class_eval needs a string literal (a computed string would make every method of #{k.name} patchable)" unless src.is_a?(Prism::StringNode)
        Prism.parse(src.unescaped).value.statements.body.grep(Prism::DefNode).each do |d|
          m = k.find_method(d.name) or raise "class_eval defining a new method #{d.name} (only redefinition for now)"
          m.patchable = true
        end
        emit(:seam, [k, src.unescaped])
      elsif n.name == :sqrt && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Math
        emit(:fsqrt, [expr(args[0])])
      elsif %i[sin cos].include?(n.name) && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Math
        emit(:libm, [n.name, expr(args[0])])
      elsif n.name == :** then emit(:pow, [expr(n.receiver), expr(args[0])]) # ipow or libm pow, by type
      elsif n.name == :length && args.empty? && n.receiver then emit(:alen, [expr(n.receiver)])
      elsif n.name == :push && (n.receiver.is_a?(Prism::LocalVariableReadNode) || n.receiver.is_a?(Prism::InstanceVariableReadNode))
        a = expr(n.receiver); v = expr(args[0]); len = emit(:alen, [a])
        r = emit(:aset, [a, len, v]) # may grow: rebind the home
        if n.receiver.is_a?(Prism::LocalVariableReadNode) then @locals[lname(n.receiver.name)] = r
        else emit(:fld_set, [me_val, @klass.ivar(n.receiver.name), r]) end
        r
      elsif n.name == :[] # array / hash / string: Types decides
        r = expr(n.receiver)
        return (c = const(0); c.ty = :nil; c) if r.ty == :nil # nil[k] (ARGV) is nil at compile time
        emit(:idx, [r, *args.map { expr(_1) }])
      elsif n.name == :[]=
        # a[i] = v may grow a: the result is the (possibly new) container, rebound to its home
        a = expr(n.receiver); i = expr(args[0]); v = expr(args[1])
        r = emit(:idx_set, [a, i, v])
        case n.receiver
        when Prism::LocalVariableReadNode then @locals[lname(n.receiver.name)] = r
        when Prism::InstanceVariableReadNode then emit(:fld_set, [me_val, @klass.ivar(n.receiver.name), r])
        else raise "[]= on #{n.receiver.class}"
        end
        v
      elsif (n.name == :key? || n.name == :has_key?) && args.size == 1 && n.receiver
        emit(:hkey, [expr(n.receiver), expr(args[0])])
      elsif n.name == :keys && args.empty? && n.receiver
        emit(:hkeys, [expr(n.receiver)])
      elsif n.receiver && !n.receiver.is_a?(Prism::ConstantReadNode)
        # a method call on an object: resolved by Types once the receiver's class is known
        emit(:mcall, [n.name, expr(n.receiver), *args.map { expr(_1) }])
      elsif @klass && @klass.find_method(n.name) && !@funcs[n.name]
        me = @name_pfx ? @locals.fetch(:"#{@name_pfx}self") : @locals.fetch(:self)
        emit(:call, [@klass.find_method(n.name), me, *args.map { expr(_1) }])
      else
        f = @funcs.fetch(n.name) { raise "unknown method #{n.name}" }
        vals = args.map { expr(_1) }
        vals = fill_defaults(f, vals) if vals.size < f.params.size
        emit(:call, [f, *vals])
      end
    end

    # optional parameters: missing arguments take their default expressions,
    # evaluated at the call site with earlier parameters bound
    def fill_defaults(f, vals)
      d = @defs_by_func[f] or raise "#{f.name}: wrong number of arguments"
      ps = d.parameters
      names = ps.requireds.map(&:name) + ps.optionals.map(&:name)
      pfx = :"dflt#{@f.blocks.size}:"
      names.each_with_index { |nm, k| @locals[:"#{pfx}#{nm}"] = vals[k] if vals[k] }
      @blk_pfx = (@blk_pfx || []) << pfx
      ps.optionals.each_with_index do |o, k|
        idx = ps.requireds.size + k
        next if vals[idx]
        vals[idx] = expr(o.value); @locals[:"#{pfx}#{o.name}"] = vals[idx]
      end
      @blk_pfx.pop
      @locals.delete_if { |k, _| k.to_s.start_with?(pfx.to_s) }
      vals
    end

    # raw memory / addresses for the collector (lib/indus/prelude/gc.rb)
    def intrinsic(name, args)
      case name
      when :__ld then emit(:rawld, [expr(args[0])])
      when :__ld32 then emit(:rawld32, [expr(args[0])])
      when :__st then (a = expr(args[0]); v = expr(args[1]); emit(:rawst, [a, v]); v)
      when :__gbase then emit(:gbase, [])
      when :__adr_tables then emit(:adrlbl, [:__gc_tables])
      when :__adr_text then emit(:adrlbl, [:__text_base])
      when :__dbg then emit(:puts_i, [expr(args[0])])
      when :__mmap then emit(:rawmmap, [expr(args[0])])
      when :__trap then emit(:trap, [])
      else raise "unknown intrinsic #{name}"
      end
    end

    # ------------------------------------------------------------ blocks
    # Every block is inlined at its call site: builtin iterators become
    # loops, a user method containing `yield` is inlined with the block body
    # spliced at each yield. Callee locals live in the caller's @locals map
    # under prefixed keys, so loop phis cover both scopes uniformly.
    def block_call(n, args)
      blk = n.block
      params = case blk.parameters
               when Prism::NumberedParametersNode then (1..blk.parameters.maximum).map { :"_#{_1}" }
               when nil then []
               else blk.parameters.parameters.requireds.map(&:name)
               end
      body = blk.body&.body || []
      recv = n.receiver
      case n.name
      when :new # Array.new(n) { |i| v }
        raise "block passed to #{recv&.name}.new" unless recv.is_a?(Prism::ConstantReadNode) && recv.name == :Array
        len = expr(args[0])
        fill = const(0); fill.ty = :nil
        arr = emit(:anew, [len, fill])
        outv = :"anew#{@f.blocks.size}:out"
        @locals[outv] = arr
        counted_loop(const(0), len, :lt, params, body) do |i, ps, pfx|
          @locals[:"#{pfx}#{ps[0]}"] = i if ps[0]
          @map_target = [outv, i]
        end
        return @locals.delete(outv)
      when :times then counted_loop(const(0), expr(recv), :lt, params, body)
      when :upto then counted_loop(expr(recv), expr(args[0]), :le, params, body)
      when :each, :map, :each_with_index
        r = recv.is_a?(Prism::ParenthesesNode) ? recv.body.body.last : recv
        if r.is_a?(Prism::RangeNode)
          raise "map over a range" if n.name == :map
          return counted_loop(expr(r.left), expr(r.right), r.exclude_end? ? :lt : :le, params, body)
        end
        k = recv ? kind_of(recv) : (@klass&.name) # receiverless: self
        y = @yielders[n.name]
        return inline_yielder(y, recv, args, params, body) if y && k.is_a?(Symbol) && @classes[k] && y[0] && (k == y[0].name || y[0].name.nil?)
        return inline_yielder(y, recv, args, params, body) if y && k.nil? && recv.nil?
        array_loop(expr(recv), n.name, params, body)
      else
        y = @yielders[n.name] or raise "block passed to #{n.name}, which has no yield"
        inline_yielder(y, recv, args, params, body)
      end
    end

    # for i in [from, to): header phis over every local; block params are
    # prefixed so they shadow without clobbering
    def counted_loop(from, to, cond, params, body, &each)
      pfx = :"blk#{@f.blocks.size}:"
      hb, bb, lb, xb = @f.new_block(:head), @f.new_block(:body), @f.new_block(:latch), @f.new_block(:exit)
      xb.cold = true
      pre = @cur
      ivar = :"#{pfx}i"
      @locals[ivar] = from
      emit(:br, [hb])
      phis = @locals.to_h { |nm, v| ph = hb.phi; ph.args << [pre, v]; [nm, ph] }
      @locals = phis.dup
      @cur = hb
      emit(:condbr, [emit(:cmp, [@locals[ivar], to], cond), bb, xb])
      outer, @loop = @loop, { exit: xb, breaks: [], next: lb, nexts: [] }
      @cur = bb
      each ? each.call(@locals[ivar], params, pfx) : (@locals[:"#{pfx}#{params[0]}"] = @locals[ivar] if params[0])
      @blk_pfx = (@blk_pfx || []) << pfx
      last = nil
      body.each { last = expr(_1) }
      @blk_pfx.pop
      if @map_target && @map_target[0] && @locals[@map_target[0]]
        outv, idx = @map_target; @map_target = nil
        @locals[outv] = emit(:aset, [@locals[outv], idx, last || const(0)])
      end
      emit(:br, [lb]) unless @cur.term
      @loop[:nexts] << [@cur, @locals.dup] unless @cur.name.to_s.start_with?("dead")
      # latch: merge normal end + nexts, then step
      @cur = lb
      arms = @loop[:nexts].select { |(b, _)| b.succs.include?(lb) }
      @locals = merge_locals(lb, arms) unless arms.size <= 1
      @locals = arms[0][1].dup if arms.size == 1
      @locals[ivar] = emit(:add, [@locals[ivar], const(1)])
      emit(:br, [hb])
      phis.each { |nm, ph| ph.args << [lb, @locals.fetch(nm)] }
      breaks = @loop[:breaks]; @loop = outer
      @cur = xb
      @locals = breaks.empty? ? phis.dup : merge_locals(xb, [[hb, phis.dup], *breaks])
      @locals.delete_if { |k, _| k.to_s.start_with?(pfx.to_s) }
      const(0)
    end

    def array_loop(arr, kind, params, body)
      len = emit(:alen, [arr])
      out = (emit(:anew, [len, (c = const(0); c.ty = :nil; c)])) if kind == :map
      outv = :"map#{@f.blocks.size}:out"
      @locals[outv] = out if out
      counted_loop(const(0), len, :lt, params, body) do |i, ps, pfx|
        @locals[:"#{pfx}#{ps[0]}"] = emit(:aget, [arr, i]) if ps[0]
        @locals[:"#{pfx}#{ps[1]}"] = i if kind == :each_with_index && ps[1]
        if kind == :map
          # the body's value is stored at the latch: wrap body so its last value is captured
          @map_target = [outv, i]
        end
      end.then do |r|
        if out
          res = @locals.delete(outv); res
        else r end
      end
    end

    def inline_yielder((klass, d), recv, args, params, body)
      pfx = :"inl#{@f.blocks.size}:"
      me = recv ? expr(recv) : @locals[:self]
      callee_locals = me ? { :"#{pfx}self" => me } : {} # top-level yielders have no self
      (d.parameters&.requireds || []).each_with_index { |p, k| callee_locals[:"#{pfx}#{p.name}"] = expr(args[k]) }
      saved = [@block, @klass, @inl, @ret_exit]
      @block = [params, body]
      @inl = pfx; @klass = klass || @klass
      exit = @f.new_block(:inlret); exit.cold = false
      @ret_exit = { block: exit, arms: [] }
      @locals.merge!(callee_locals)
      last = nil
      (d.body&.body || []).each { last = inl_expr(_1) }
      unless @cur.term
        @ret_exit[:arms] << [@cur, @locals.dup, last || const(0)]
        emit(:br, [exit])
      end
      @cur = exit
      arms = @ret_exit[:arms]
      @locals = arms.size == 1 ? arms[0][1].dup : merge_locals(exit, arms.map { |(b, l, _)| [b, l] })
      val = if arms.size == 1 then arms[0][2]
            else p = exit.phi; p.args = arms.map { |(b, _, v)| [b, v] }; p end
      @locals.delete_if { |k, _| k.to_s.start_with?(pfx.to_s) }
      @block, @klass, @inl, @ret_exit = saved
      val
    end

    # inside an inlined callee every name resolves through the callee prefix
    def inl_expr(n) = with_prefix(@inl) { expr(n) }

    def with_prefix(pfx)
      old = @name_pfx; @name_pfx = pfx
      yield
    ensure
      @name_pfx = old
    end

    # splice the block body at a yield: it runs in the caller's naming
    def yield_block(arg_nodes)
      params, body = @block
      vals = arg_nodes.map { expr(_1) }           # still in callee naming
      bpfx = :"y#{@f.blocks.size}:"
      saved_pfx, @name_pfx = @name_pfx, nil
      saved_ret, @ret_exit = @ret_exit, nil        # a `return` in the block would return from the caller: unsupported
      params.each_with_index { |p, k| @locals[:"#{bpfx}#{p}"] = vals[k] || const(0) }
      @blk_pfx = (@blk_pfx || []) << bpfx
      last = nil
      body.each { last = expr(_1) }
      @blk_pfx.pop
      @locals.delete_if { |k, _| k.to_s.start_with?(bpfx.to_s) }
      @name_pfx, @ret_exit = saved_pfx, saved_ret
      last || const(0)
    end

    def if_expr(n, negate: false)
      tb, eb, mb = @f.new_block(:then), @f.new_block(:else), @f.new_block(:merge)
      negate ? cond_branch(n.predicate, eb, tb) : cond_branch(n.predicate, tb, eb)
      before = @locals.dup

      @cur = tb; tv = (n.statements&.body || []).map { expr(_1) }.last || const(0)
      tend, tlocals = @cur, @locals; emit(:br, [mb]) unless @cur.term

      @cur = eb; @locals = before.dup
      sub = n.is_a?(Prism::UnlessNode) ? n.else_clause : n.subsequent
      ev = case sub
           when Prism::IfNode then if_expr(sub)
           when Prism::ElseNode then sub.statements&.body&.map { expr(_1) }&.last
           end || const(0)
      eend, elocals = @cur, @locals; emit(:br, [mb]) unless @cur.term

      @cur = mb
      @locals = merge_locals(mb, [[tend, tlocals], [eend, elocals]])
      p = mb.phi; p.args = [[tend, tv], [eend, ev]]
      p
    end

    # case v when a, b then ... when x..y then ... else ... end  ->  if-chain
    def case_expr(n)
      subj = n.predicate ? expr(n.predicate) : nil
      tests = n.conditions.map do |w|
        [w.conditions.map { |c| when_test(subj, c) }, w.statements&.body || []]
      end
      lower_chain(tests, n.else_clause&.statements&.body || [])
    end

    def when_test(subj, c)
      return ->() { expr(c) } unless subj
      if c.is_a?(Prism::RangeNode)
        ->() { lo = expr(c.left); hi = expr(c.right)
               a = emit(:cmp, [subj, lo], :ge); b = emit(:cmp, [subj, hi], c.exclude_end? ? :lt : :le)
               emit(:and, [a, b]) }
      else
        ->() { emit(:cmp, [subj, expr(c)], :eq) } # Types turns str == str into seq
      end
    end

    def lower_chain(tests, else_body)
      return (else_body.map { expr(_1) }.last || const(0)) if tests.empty?
      (conds, body), *rest = tests
      tb, eb, mb = @f.new_block(:then), @f.new_block(:else), @f.new_block(:merge)
      # any of the conditions
      conds.each_with_index do |t, k|
        v = t.call
        nxt = k == conds.size - 1 ? eb : @f.new_block(:or)
        emit(:condbr, [v, tb, nxt]); @cur = nxt
      end
      before = @locals.dup
      @cur = tb; tv = body.map { expr(_1) }.last || const(0); tend, tl = @cur, @locals; emit(:br, [mb]) unless @cur.term
      @cur = eb; @locals = before.dup; ev = lower_chain(rest, else_body); eend, el = @cur, @locals; emit(:br, [mb]) unless @cur.term
      @cur = mb; @locals = merge_locals(mb, [[tend, tl], [eend, el]])
      p = mb.phi; p.args = [[tend, tv], [eend, ev]]; p
    end

    # x ||= v (when_truthy=false) / x &&= v (when_truthy=true)
    def cond_assign(cur, when_truthy, value_fn, assign_fn)
      tb, mb = @f.new_block(:set), @f.new_block(:merge)
      pre = @cur; before = @locals.dup
      when_truthy ? emit(:condbr, [cur, tb, mb]) : emit(:condbr, [cur, mb, tb])
      @cur = tb; v = value_fn.call; assign_fn.call(v); tend, tl = @cur, @locals; emit(:br, [mb])
      @cur = mb; @locals = merge_locals(mb, [[pre, before], [tend, tl]])
      p = mb.phi; p.args = [[pre, cur], [tend, v]]; p
    end

    # lambdas are inlined at .call / .() sites: a lambda value is its AST
    def lambda_value(n)
      @pending_lambda = n
      c = const(0); c.ty = :lambda; c
    end

    def inline_lambda(lam, args)
      params = lam.parameters&.parameters&.requireds&.map(&:name) || []
      pfx = :"lam#{@f.blocks.size}:"
      params.each_with_index { |p, k| @locals[:"#{pfx}#{p}"] = expr(args[k]) }
      @blk_pfx = (@blk_pfx || []) << pfx
      last = nil
      (lam.body&.body || []).each { last = expr(_1) }
      @blk_pfx.pop
      @locals.delete_if { |k, _| k.to_s.start_with?(pfx.to_s) }
      last || const(0)
    end

    def expr_const_path(n)
      # Mod::NAME -> the constant; Mod::Klass handled by callers (Klass.new)
      emit(:gget, [n.name])
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

    def while_stmt(n, negate: false)
      hb, bb, xb = @f.new_block(:head), @f.new_block(:body), @f.new_block(:exit)
      xb.cold = true
      pre = @cur
      emit(:br, [hb])
      phis = @locals.to_h { |nm, v| ph = hb.phi; ph.args << [pre, v]; [nm, ph] }
      @locals = phis.dup
      @cur = hb
      negate ? cond_branch(n.predicate, xb, bb) : cond_branch(n.predicate, bb, xb)
      outer, @loop = @loop, { exit: xb, breaks: [] }
      @cur = bb
      (n.statements&.body || []).each { expr(_1) }
      bend = @cur
      emit(:br, [hb]) unless @cur.term
      phis.each { |nm, ph| ph.args << [bend, @locals[nm]] }
      breaks = @loop[:breaks]; @loop = outer
      @cur = xb
      # exit sees the header's values, or a break site's
      @locals = breaks.empty? ? phis.dup : merge_locals(xb, [[hb, phis.dup], *breaks])
      const(0)
    end
  end
end
