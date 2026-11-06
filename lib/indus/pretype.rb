# Pre-typing: a coarse kind for every expression *before* lowering, so that
# structural decisions that depend on a receiver's kind -- is `x.each {}` an
# array loop or an inlined user method? which class does `x.send(n)` dispatch
# over? -- are made from inference, not from syntax.
#
# Kinds are deliberately coarse: :int :float :str :sym :bool :nil,
# [:array, elem], [:hash, k, v], [:range], a class name (Symbol), or nil
# (unknown). Two different kinds meeting give :poly (unknown for our purposes).
# Flow: literals; local assignment; ivar assignment (per class); method return
# (join of returns); parameters (join over call sites); block parameters from
# the iterated collection. Iterated to a fixpoint over all scopes.
#
# Results are keyed by AST node identity: Pretype#[](node).
module Indus
  class Pretype
    attr_reader :classes

    def initialize(ast, classes)
      @ast, @classes = ast, classes
      @kind = {}.compare_by_identity          # node -> kind
      @ret = Hash.new                          # Func key -> return kind
      @params = Hash.new { |h, k| h[k] = [] }  # Func key -> [kind per param]
      @ivars = Hash.new { |h, k| h[k] = {} }   # class -> ivar -> kind
      @defs = {}                               # key -> [DefNode, class or nil]
      collect
      run
    end

    def [](node) = @kind[node]

    def join(a, b)
      return b if a.nil?
      return a if b.nil? || a == b
      return :int? if [a, b].sort_by(&:to_s) == [:int, :nil] || [a, b].sort_by(&:to_s) == %i[int int?]
      return a if b == :nil
      return b if a == :nil
      return :float if [a, b].sort_by(&:to_s) == %i[float int]
      return [:array, join(a[1], b[1])] if a.is_a?(Array) && b.is_a?(Array) && a[0] == :array && b[0] == :array
      return [:hash, join(a[1], b[1]), join(a[2], b[2])] if a.is_a?(Array) && b.is_a?(Array) && a[0] == :hash && b[0] == :hash
      :poly
    end

    private

    def key(klass, name) = klass ? :"#{klass}##{name}" : name

    def collect
      walk_defs = ->(body, klass) {
        (body || []).each do |st|
          case st
          when Prism::DefNode then @defs[key(klass, st.name)] = [st, klass]
          when Prism::ClassNode then walk_defs.(st.body&.body, st.constant_path.name)
          when Prism::ModuleNode then walk_defs.(st.body&.body, nil)
          end
        end
      }
      walk_defs.(@ast.statements.body, nil)
    end

    def run
      loop do
        @changed = false
        # top level
        env = {}
        @ast.statements.body.each { |st| stmt(st, env, nil, nil) }
        # every def, with its current parameter kinds
        @defs.each do |k, (d, klass)|
          env = {}
          names = (d.parameters&.requireds&.map(&:name) || []) + (d.parameters&.optionals&.map(&:name) || [])
          names.each_with_index { |n, i| env[n] = @params[k][i] }
          env[:"*rest"] = [:array, nil] if d.parameters&.rest
          last = nil
          (d.body&.body || []).each { |st| last = stmt(st, env, klass, k) }
          set_ret(k, last) if last
        end
        break unless @changed
      end
    end

    def set_ret(k, kind) = (nk = join(@ret[k], kind); (@ret[k] = nk; @changed = true) if nk != @ret[k])
    def set_param(k, i, kind) = (cur = @params[k][i]; nk = join(cur, kind); (@params[k][i] = nk; @changed = true) if nk != cur)
    def set_ivar(klass, iv, kind) = (cur = @ivars[klass][iv]; nk = join(cur, kind); (@ivars[klass][iv] = nk; @changed = true) if nk != cur)
    def note(n, kind) = (@kind[n] = kind unless kind.nil?; kind)

    def stmt(n, env, klass, fkey) = expr(n, env, klass, fkey)

    # kind of an expression; records it for the node
    def expr(n, env, klass, fkey)
      k = case n
          when Prism::IntegerNode then :int
          when Prism::FloatNode then :float
          when Prism::StringNode, Prism::InterpolatedStringNode then (n.is_a?(Prism::InterpolatedStringNode) && n.parts.each { |p| expr(p.statements.body.last, env, klass, fkey) if p.is_a?(Prism::EmbeddedStatementsNode) }; :str)
          when Prism::SymbolNode then :sym
          when Prism::TrueNode, Prism::FalseNode then :bool
          when Prism::NilNode then :nil
          when Prism::SelfNode then klass
          when Prism::ArrayNode then [:array, n.elements.map { expr(_1, env, klass, fkey) }.reduce(nil) { join(_1, _2) }]
          when Prism::HashNode
            ks = vs = nil
            n.elements.each { |e| next unless e.is_a?(Prism::AssocNode); ks = join(ks, expr(e.key, env, klass, fkey)); vs = join(vs, expr(e.value, env, klass, fkey)) }
            [:hash, ks, vs]
          when Prism::RangeNode then (expr(n.left, env, klass, fkey); expr(n.right, env, klass, fkey); [:range])
          when Prism::ParenthesesNode then n.body.body.map { expr(_1, env, klass, fkey) }.last
          when Prism::StatementsNode then n.body.map { expr(_1, env, klass, fkey) }.last
          when Prism::LocalVariableReadNode then env[n.name]
          when Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode
            v = expr(n.value, env, klass, fkey); env[n.name] = join(env[n.name], v); env[n.name]
          when Prism::LocalVariableOperatorWriteNode then (expr(n.value, env, klass, fkey); env[n.name])
          when Prism::MultiWriteNode
            vs = n.value.is_a?(Prism::ArrayNode) ? n.value.elements.map { expr(_1, env, klass, fkey) } : []
            n.lefts.each_with_index { |t, i| env[t.name] = join(env[t.name], vs[i]) if t.is_a?(Prism::LocalVariableTargetNode) }
            nil
          when Prism::InstanceVariableReadNode then klass && @ivars[klass][n.name]
          when Prism::InstanceVariableWriteNode
            v = expr(n.value, env, klass, fkey); set_ivar(klass, n.name, v) if klass; v
          when Prism::ConstantReadNode, Prism::ConstantPathNode then @classes[n.name] ? :"class:#{n.name}" : nil
          when Prism::ConstantWriteNode then expr(n.value, env, klass, fkey)
          when Prism::ClassVariableWriteNode then (v = expr(n.value, env, klass, fkey); (@cvars ||= {})[n.name] = join(@cvars[n.name], v); v)
          when Prism::ClassVariableReadNode then (@cvars ||= {})[n.name]
          when Prism::ClassVariableOperatorWriteNode then (expr(n.value, env, klass, fkey); (@cvars ||= {})[n.name])
          when Prism::IfNode, Prism::UnlessNode
            expr(n.predicate, env, klass, fkey)
            a = n.statements&.body&.map { expr(_1, env, klass, fkey) }&.last
            sub = n.is_a?(Prism::UnlessNode) ? n.else_clause : n.subsequent
            b = case sub
                when Prism::IfNode then expr(sub, env, klass, fkey)
                when Prism::ElseNode then sub.statements&.body&.map { expr(_1, env, klass, fkey) }&.last
                end
            join(a, b)
          when Prism::WhileNode, Prism::UntilNode
            expr(n.predicate, env, klass, fkey); n.statements&.body&.each { expr(_1, env, klass, fkey) }; :nil
          when Prism::CaseNode
            expr(n.predicate, env, klass, fkey) if n.predicate
            ks = n.conditions.map { |w| w.conditions.each { expr(_1, env, klass, fkey) }; w.statements&.body&.map { expr(_1, env, klass, fkey) }&.last }
            ks << n.else_clause&.statements&.body&.map { expr(_1, env, klass, fkey) }&.last
            ks.reduce(nil) { join(_1, _2) }
          when Prism::ReturnNode
            v = n.arguments ? expr(n.arguments.arguments[0], env, klass, fkey) : :nil
            set_ret(fkey, v) if fkey; v
          when Prism::YieldNode then (n.arguments&.arguments&.each { expr(_1, env, klass, fkey) }; nil)
          when Prism::AndNode, Prism::OrNode then (expr(n.left, env, klass, fkey); expr(n.right, env, klass, fkey); :bool)
          when Prism::CallNode then call(n, env, klass, fkey)
          when Prism::LambdaNode, Prism::BreakNode, Prism::NextNode, Prism::DefNode, Prism::ClassNode, Prism::ModuleNode then nil
          else nil
          end
      note(n, k)
    end

    ARITH = %i[+ - * / %].freeze

    def call(n, env, klass, fkey)
      args = n.arguments&.arguments || []
      recv = n.receiver && expr(n.receiver, env, klass, fkey)
      akinds = args.map { expr(_1, env, klass, fkey) }
      blk = n.block.is_a?(Prism::BlockNode) ? n.block : nil

      # block parameters get the element kind of what is iterated, then the body is walked
      if blk
        params = blk.parameters.is_a?(Prism::BlockParametersNode) ? blk.parameters.parameters.requireds.map { _1.respond_to?(:name) ? _1.name : nil } : [] # |(a, b)| destructures: no name for that slot
        benv = env # blocks share the enclosing locals
        case n.name
        when :times, :upto, :downto then benv[params[0]] = :int if params[0]
        when :each, :map, :select, :each_with_index
          if recv.is_a?(Array) && recv[0] == :array then benv[params[0]] = recv[1] if params[0]
          elsif recv == [:range] then benv[params[0]] = :int if params[0]
          elsif recv.is_a?(Symbol) && (y = yielder(recv, n.name)) then yield_kinds(y, params, benv)
          end
          benv[params[1]] = :int if params[1]
        else
          y = yielder(recv.is_a?(Symbol) ? recv : klass, n.name) || yielder(nil, n.name)
          yield_kinds(y, params, benv) if y
        end
        (blk.body&.body || []).each { expr(_1, benv, klass, fkey) }
      end

      case n.name
      when *ARITH
        return recv if recv == :str && n.name == :+
        l, r = recv, akinds[0]
        return :float if l == :float || r == :float
        return l == :int? ? :int : l
      when :==, :!=, :<, :<=, :>, :>=, :key?, :has_key?, :is_a?, :! then :bool
      when :length, :size, :to_i, :ord, :&, :|, :^, :<<, :>> then (n.name == :<< && recv != :int ? recv : :int)
      when :to_s, :upcase, :downcase, :capitalize, :swapcase, :strip, :lstrip, :rstrip, :chomp, :chop, :succ, :next, :tr,
           :delete, :squeeze, :center, :ljust, :rjust, :inspect, :join, :chr, :sub, :gsub, :slice, :insert, :prepend then :str
      when :to_f then :float
      when :new
        cname = n.receiver.is_a?(Prism::ConstantReadNode) || n.receiver.is_a?(Prism::ConstantPathNode) ? n.receiver.name : nil
        return [:array, akinds[1]] if cname == :Array
        if cname && @classes[cname]
          k = key(cname, :initialize)
          akinds.each_with_index { |ak, i| set_param(k, i, ak) } if @defs[k]
          return cname
        end
        nil
      when :[]
        case recv
        in [:array, e] then e
        in [:hash, _, v] then v
        else recv == :str ? :str : nil
        end
      when :[]= then (store_into(recv, n.receiver, akinds, env, klass); akinds[1])
      when :push then (store_into(recv, n.receiver, [nil, akinds[0]], env, klass); recv)
      when :keys then recv.is_a?(Array) && recv[0] == :hash ? [:array, recv[1]] : nil
      when :map, :select, :reject, :sort, :sort_by, :reverse, :uniq, :flatten, :compact, :first, :take, :drop, :shuffle, :zip, :each_slice, :each_cons, :partition, :chars, :split, :lines, :to_a, :values, :filter_map, :flat_map, :min_by, :max_by
        if recv == :str # a String method of the same name: the pieces are an array, the rest is a String
          %i[chars split lines bytes to_a].include?(n.name) ? [:array, n.name == :bytes ? :int : :str] : :str
        elsif %i[min_by max_by first].include?(n.name) && (n.name != :first || akinds.empty?) then (recv.is_a?(Array) && recv[0] == :array ? recv[1] : nil)
        elsif recv.is_a?(Array) && recv[0] == :hash then (%i[select reject compact filter find_all slice except merge_blk sort_by_h].include?(n.name) ? recv : [:array, nil])
        elsif %i[select reject sort reverse uniq compact first take drop shuffle].include?(n.name) && recv.is_a?(Array) then recv
        else [:array, nil] end
      when :group_by, :tally, :to_h, :transform_values, :transform_keys, :merge, :invert, :each_with_object, :slice, :except, :filter_map_h, :keep_if, :delete_if, :clear, :store
        if n.name == :each_with_object then (akinds[0].is_a?(Array) ? akinds[0] : nil)
        elsif %i[slice except keep_if delete_if clear].include?(n.name) then (recv.is_a?(Array) && recv[0] == :hash ? recv : (n.name == :slice ? recv : [:array, nil]))
        elsif n.name == :store then akinds[1]
        else [:hash, nil, nil] end
      when :dup, :clone, :freeze, :itself then recv
      when :send, :public_send then nil
      when :sqrt, :sin, :cos then :float
      when :** then (recv == :float || akinds[0] == :float ? :float : :int)
      else
        # a user method: receiver class (or self class, or top level)
        target = if n.receiver.nil? then (klass && @defs[key(klass, n.name)] ? key(klass, n.name) : @defs[n.name] ? n.name : nil)
                 elsif recv.is_a?(Symbol) && @classes[recv] then (k = method_key(recv, n.name)) end
        if target
          akinds.each_with_index { |ak, i| set_param(target, i, ak) }
          @ret[target]
        elsif recv.is_a?(Symbol) && @classes[recv]
          c = @classes[recv]
          (iv = c.find_reader(n.name)) ? @ivars[owner_of_ivar(recv, iv)][iv] : nil
        end
      end
    end

    # `a[i] = v` / `a.push(v)`: the element kind flows into the container's kind at its home
    def store_into(recv, rnode, akinds, env, klass)
      nk = case recv
           in [:array, e] then [:array, join(e, akinds[1])]
           in [:hash, k, v] then [:hash, join(k, akinds[0]), join(v, akinds[1])]
           else return
           end
      case rnode
      when Prism::LocalVariableReadNode then env[rnode.name] = nk
      when Prism::InstanceVariableReadNode then set_ivar(klass, rnode.name, nk) if klass
      end
    end

    def method_key(cname, name)
      c = @classes[cname]
      while c
        k = key(c.name, name)
        return k if @defs[k]
        c = c.superclass
      end
      nil
    end

    def owner_of_ivar(cname, iv)
      c = @classes[cname]
      c = c.superclass while c&.superclass && !@ivars[c.name].key?(iv) && @ivars[c.superclass.name].key?(iv)
      c ? c.name : cname
    end

    # the def of a yield-method `name` on class `cname` (or top level when nil)
    def yielder(cname, name)
      k = cname ? method_key(cname, name) : (@defs[name] && name)
      k && @defs[k] && yields?(@defs[k][0]) ? k : nil
    end

    def yields?(d) = d.body && d.body.body.any? { |st| has_yield?(st) }
    def has_yield?(node)
      return false unless node.is_a?(Prism::Node)
      return true if node.is_a?(Prism::YieldNode)
      node.compact_child_nodes.any? { has_yield?(_1) }
    end

    # block params of a call to a yield-method: kinds of the yield arguments, as last inferred
    def yield_kinds(k, params, benv)
      d, klass = @defs[k]
      ys = []
      find = ->(node) { return unless node.is_a?(Prism::Node); ys << node if node.is_a?(Prism::YieldNode); node.compact_child_nodes.each { find.(_1) } }
      (d.body&.body || []).each { find.(_1) }
      ys.each do |y|
        (y.arguments&.arguments || []).each_with_index { |a, i| benv[params[i]] = join(benv[params[i]], @kind[a]) if params[i] }
      end
    end
  end
end
