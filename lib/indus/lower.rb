# Prism AST -> SSA. Locals are a name->value map per program point.
module Indus
  # Locals are a name->value map per program point. `while` makes a phi per
  # live local at the header; `if` makes a phi per local that differs at the
  # merge. Trivial phis are removed afterwards.
  class Lower
    CMP = { :== => :eq, :!= => :ne, :< => :lt, :<= => :le, :> => :gt, :>= => :ge }
    ARITH = { :+ => :add, :- => :sub, :* => :mul, :/ => :div, :% => :mod, :& => :and, :| => :or, :^ => :xor, :<< => :shl, :>> => :shr }

    attr_reader :classes, :syms, :funcs
    # symbols are small integers, interned at compile time
    def sym_id(name) = (@syms ||= {})[name.to_sym] ||= @syms.size + 1

    def initialize(src) = (@ast, @funcs, @classes, @consts = Lower.normalize(Prism.parse(src).value), {}, {}, {})

    # `def m ... rescue ... end` is a def whose body is a begin: give it the statements body
    # every def site expects, so one shape reaches the lowering
    def self.normalize(node)
      return node.map { normalize(_1) } if node.is_a?(Array)
      return node unless node.is_a?(Prism::Node)
      if node.is_a?(Prism::DefNode) && node.body.is_a?(Prism::BeginNode)
        node = node.copy(body: Prism::StatementsNode.new(node.send(:source), 0, node.body.location, 0, [node.body]))
      end
      fields = node.class.instance_method(:initialize).parameters.map(&:last).reject { %i[source node_id location flags].include?(_1) }
      changes = {}
      fields.each do |fl|
        next unless node.respond_to?(fl)
        v = node.public_send(fl)
        nv = normalize(v)
        changes[fl] = nv unless nv.equal?(v) || v.is_a?(Array) && nv == v
      end
      changes.empty? ? node : node.copy(**changes)
    end

    def run
      body = @ast.statements.body
      # modules are namespaces: hoist their classes and constants to the top level
      mods = body.grep(Prism::ModuleNode)
      # a module's instance methods: `include M` in a class body compiles them as that class's own
      # (one copy per including class -- typed for that class, like everything else here)
      @module_defs = mods.to_h { |m| [m.constant_path.name, (m.body&.body || []).grep(Prism::DefNode).reject { _1.receiver.is_a?(Prism::SelfNode) }] }
      mod_classes = mods.flat_map { |m| (m.body&.body || []).grep(Prism::ClassNode) }
      mod_consts = mods.flat_map { |m| (m.body&.body || []).grep(Prism::ConstantWriteNode) }
      mod_ivars = mods.flat_map { |m| (m.body&.body || []).grep(Prism::InstanceVariableWriteNode).map { [m.constant_path.name, _1] } }
      defs = body.grep(Prism::DefNode)
      # top-level define_method(:name) { |params| body } with a literal symbol and block: a def
      dm = body.select { |st| st.is_a?(Prism::CallNode) && st.name == :define_method && st.receiver.nil? && st.block.is_a?(Prism::BlockNode) && st.arguments&.arguments&.first.is_a?(Prism::SymbolNode) }
      body = body - dm
      cdefs = body.grep(Prism::ClassNode) + mod_classes
      # `def self.m` in a class or module body: a function named Owner.m, no self
      @modules = mods.map { _1.constant_path.name }
      sdefs = (cdefs + mods).flat_map { |c| (c.body&.body || []).grep(Prism::DefNode).select { _1.receiver.is_a?(Prism::SelfNode) }.map { [c.constant_path.name, _1] } }
      # module_function :m (or bare, covering the defs below it): the instance method is also Module.m
      mods.each do |m|
        stmts = m.body&.body || []
        bare = false
        stmts.each do |st|
          if st.is_a?(Prism::CallNode) && st.name == :module_function && st.receiver.nil?
            names = (st.arguments&.arguments || []).map { |a| a.is_a?(Prism::SymbolNode) ? a.unescaped.to_sym : raise("module_function needs symbols") }
            bare = true if names.empty?
            names.each { |nm| d = stmts.grep(Prism::DefNode).find { _1.name == nm } or raise("module_function #{nm}: no such def"); sdefs << [m.constant_path.name, d] }
          elsif bare && st.is_a?(Prism::DefNode) && !st.receiver
            sdefs << [m.constant_path.name, st]
          end
        end
      end
      # constants written inside class bodies run before everything else
      class_consts = cdefs.flat_map { |c| (c.body&.body || []).grep(Prism::ConstantWriteNode) }
      # Name = Struct.new(:a, :b) defines a class with accessors and an initialize
      structs = body.select { |st| st.is_a?(Prism::ConstantWriteNode) && struct_new?(st.value) }
      top = (body - defs - cdefs - mods - structs)
      top = class_consts + mod_consts + top
      @mod_ivars = mod_ivars
      # methods that take a block (contain yield) are inlined at call sites with a literal block;
      # they still get compiled as functions for block-less callers
      @yielders = {} # name -> [klass or nil, def]
      defs.each { |d| @yielders[d.name] = [nil, d] if yields?(d) && !d.parameters&.block }
      @defs_by_func = {}
      @dm_bodies = {}
      dm.each do |st|
        name = st.arguments.arguments.first.unescaped.to_sym
        params = st.block.parameters&.parameters&.requireds&.map(&:name) || []
        f = @funcs[name] = Func.new(name, params.size)
        @dm_bodies[f] = [params, st.block.body&.body || []]
      end
      sdefs.each do |owner, d|
        ps = d.parameters
        f = @funcs[:"#{owner}.#{d.name}"] = Func.new(:"#{owner}.#{d.name}", (ps&.requireds&.size || 0) + (ps&.optionals&.size || 0) + (ps&.keywords&.size || 0))
        @defs_by_func[f] = d
      end
      @lazy = {} # prelude functions (__name): lowered on first demand, see `demand`
      defs.each do |d|
        next if yields?(d) && !d.parameters&.block # a yielder without &blk inlines at its call sites
        ps = d.parameters
        f = @funcs[d.name] = Func.new(d.name, def_param_names(d).size)
        f.rest = true if ps&.rest.is_a?(Prism::RestParameterNode)
        @defs_by_func[f] = d
        @lazy[d.name] = d if d.name.to_s.start_with?("__")
      end
      methods = [] # [klass, def, func]
      structs.each do |st|
        k = @classes[st.name] = Klass.new(st.name)
        k.id = @classes.size
        fields = st.value.arguments.arguments.map { |a| a.unescaped.to_sym }
        fields.each { |f| k.ivar(:"@#{f}"); k.readers[f] = :"@#{f}"; k.writers[:"#{f}="] = :"@#{f}" }
        init = Func.new(:"#{k.name}#initialize", 1 + fields.size)
        init.cls = k; k.methods[:initialize] = init
        # body: @a = a; @b = b ...  built as AST-free lowering below
        methods << [k, nil, init, [:self, *fields], fields.map { |f| [:struct_set, f] }, {}]
      end
      cdefs.each do |c|
        sup = c.superclass && @classes.fetch(c.superclass.name) { raise "superclass #{c.superclass.name} must be defined first" }
        k = @classes[c.constant_path.name] = Klass.new(c.constant_path.name, sup)
        k.id = @classes.size
        # every @ivar this class body writes, registered now: a subclass declared below copies
        # the parent's layout at declaration, before the parent's methods are lowered
        assigned_ivars(c.body).each { k.ivar(_1) }
        # the method resolution order, flattened into this class: included modules first (a
        # later definition overrides an earlier one), the body, then prepended modules on top.
        # An overridden definition stays reachable as the overrider's `shadowed`: super's target
        mods_named = ->(kind) { (c.body&.body || []).select { |st| st.is_a?(Prism::CallNode) && st.name == kind && st.receiver.nil? }
                                  .flat_map { |st| st.arguments.arguments.map { |a| a.is_a?(Prism::ConstantReadNode) ? a.name : raise("#{kind} needs a module name") } } }
        mod_defs = ->(m) { @module_defs.fetch(m) { m == :Comparable ? [] : raise("include #{m}: unknown module") } }
        included, prepended = mods_named.(:include), mods_named.(:prepend)
        (k.mixins ||= []).concat(included + prepended)
        mixed_in, prepended_defs = included.flat_map(&mod_defs), prepended.flat_map(&mod_defs)
        (mixed_in + prepended_defs).each { |d| assigned_ivars(d).each { k.ivar(_1) } }
        (mixed_in + (c.body&.body || []) + prepended_defs).each do |st|
          case st
          when Prism::DefNode
            next if st.receiver.is_a?(Prism::SelfNode) # Owner.m, registered above
            if yields?(st) then @yielders[st.name] = [k, st]; next end # inlined only
            ps = st.parameters
            f = Func.new(:"#{k.name}##{st.name}#{k.methods[st.name] ? "'" * (1 + k.methods[st.name].name.to_s.count("'")) : ""}", 1 + def_param_names(st).size)
            f.rest = true if ps&.rest.is_a?(Prism::RestParameterNode)
            f.shadowed = k.methods[st.name] if k.methods[st.name]&.cls == k
            f.cls = k; k.methods[st.name] = f; methods << [k, st, f]; @defs_by_func[f] = st
          when Prism::CallNode
            next if st.name == :include || st.name == :prepend # mixed in above
            class_body_call(k, st, {}, methods)
          when Prism::ConstantWriteNode then nil # hoisted above
          else raise "unsupported in class body: #{st.class}"
          end
        end
      end
      @pre = Pretype.new(@ast, @classes) # receiver kinds for the structural decisions below
      main = Func.new(:main, 0)
      lower_body(main, [], top)
      # prelude functions are lowered only when something names them (most of the prelude is
      # never used by a given program, and typing it first was half the compile)
      defs.each { |d| lower_body(@funcs[d.name], def_param_names(d), d.body&.body || []) if @funcs[d.name] && !@lazy.key?(d.name) && !(@lowered_late || []).include?(@funcs[d.name]) }
      @dm_bodies.each { |f, (params, stmts)| lower_body(f, params, stmts) }
      sdefs.each do |owner, d|
        @owner = owner
        lower_body(@funcs[:"#{owner}.#{d.name}"], (d.parameters&.requireds&.map(&:name) || []) + (d.parameters&.optionals&.map(&:name) || []) + (d.parameters&.keywords&.map(&:name) || []), d.body&.body || [])
        @owner = nil
      end
      methods.each do |k, d, f, names, body, ct|
        if d
          names = [:self, *def_param_names(d)]
          lower_body(f, names, d.body&.body || [], k)
        else
          lower_body(f, names, body, k, ct)
        end
      end
      lower_deferred_lambdas
      install_symbol_names(main)
      demand(:__gc_run) if @funcs[:__gc_run] # the collector is entered from the runtime, not by a call
      drain_demands
      all = [main, *@funcs.values.reject { @lazy.key?(_1.name) }, *methods.map { _1[2] }, *@classes.values.select(&:closure).map { _1.methods[:call] }]
      all.each { prune(_1) }
      all
    end

    def def_param_names(d)
      ps = d.parameters
      return [] unless ps
      (ps.requireds.map(&:name)) + (ps.optionals.map(&:name)) + (ps.rest.is_a?(Prism::RestParameterNode) ? [ps.rest.name || :__rest] : []) +
        (ps.keywords.map(&:name)) + (ps.keyword_rest.is_a?(Prism::KeywordRestParameterNode) ? [ps.keyword_rest.name || :__kwrest] : []) +
        (ps.block ? [ps.block.name || :__blk] : [])
    end

    # a prelude function named by lowered code or by a Types rule: lowered now (once).
    # Returns the Func; `lowered_late` collects the ones Types has to pick up.
    public
    def demand(name)
      f = @funcs.fetch(name) { raise "unknown prelude function #{name}" }
      if (d = @lazy&.delete(name))
        nested { lower_body(f, def_param_names(d), d.body&.body || []) }
        prune(f)
        (@lowered_late ||= []) << f
      end
      f
    end
    def lowered_late! = (l = @lowered_late || []; @lowered_late = []; l)

    # lowering a body may name more prelude functions; lower until nothing new is named
    def drain_demands
      loop do
        late = lowered_late!
        break if late.empty?
        @early_lowered = (@early_lowered || []) + late
      end
      @funcs # the late ones are in @funcs already
    end
    public

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

    # arguments for a method call on an object whose class Types resolves later. Defaults, *rest
    # and keywords are shaped here, when the class is known or every class defining the name
    # agrees on the parameter shape
    def object_args(n, args, klass, recv = nil)
      cands = klass ? [klass.find_method(n.name)].compact : @classes.values.filter_map { |k| k.methods[n.name] }
      cands = cands.select { @defs_by_func[_1] }
      needs = args.last.is_a?(Prism::KeywordHashNode) || cands.any? { |f| f.rest || @defs_by_func[f].parameters&.then { |ps| ps.optionals.any? || ps.keywords.any? } }
      return args.map { expr(_1) } unless needs
      raise "#{n.name}: a default that reads self needs the receiver evaluated first" if klass.nil? && recv.nil? && cands.any? { |f| @defs_by_func[f].parameters.then { |ps| (ps.optionals + ps.keywords).any? { |o| o.respond_to?(:value) && o.value && !o.value.is_a?(Prism::IntegerNode) && !o.value.is_a?(Prism::StringNode) && !o.value.is_a?(Prism::NilNode) && !o.value.is_a?(Prism::TrueNode) && !o.value.is_a?(Prism::FalseNode) && !o.value.is_a?(Prism::FloatNode) && !o.value.is_a?(Prism::SymbolNode) && !o.value.is_a?(Prism::ArrayNode) && !o.value.is_a?(Prism::HashNode) } } }
      shapes = cands.map { |f| @defs_by_func[f].parameters&.slice.to_s }.uniq
      raise "#{n.name}: methods differ in parameter shape across classes; call with every argument spelled out" if shapes.size != 1
      method_args(cands[0], args, recv)
    end

    # arguments after self for a method call, defaults filled; a default that reads self
    # (an ivar, a method) is evaluated against the receiver, in the method's class
    def method_args(f, args, recv = nil)
      @default_self = [recv, f.cls] if recv
      call_args_raw(f, args, 1)
    ensure
      @default_self = nil
    end

    def call_args_raw(f, args, skip)
      args = args.dup
      kw = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
      vals = args.map { expr(_1) }
      if f.rest && (d = @defs_by_func[f]) # the extra positionals become the *rest array
        ps = d.parameters
        nfixed = ps.requireds.size + ps.optionals.size
        fixed, extra = vals[0, nfixed], vals[nfixed..] || []
        vals = fixed + [pack_values(extra)]
      elsif f.rest
        return vals
      end
      vals = fill_defaults(f, vals, kw) if (vals.size + skip < f.params.size || kw) && @defs_by_func[f]
      vals
    end

    # positional and keyword arguments for a call to f, defaults filled
    def call_args(f, args) = call_args_raw(f, args, 0)

    # the type a constant names, for refinement
    def kind_for(cname)
      { Integer: :int, Float: :float, String: :str, Array: [:arr, :dyn], Hash: [:hash, :dyn, :dyn], Symbol: :sym }.fetch(cname) { @classes[cname] ? cname : raise("is_a?(#{cname}): unknown class") }
    end

    attr_reader :modules

    # `x << a << b`: the local or ivar at the root of the chain, nil when it is an integer local
    def append_root(n)
      r = n.receiver
      r = r.receiver while r.is_a?(Prism::CallNode) && r.name == :<<
      case r
      when Prism::LocalVariableReadNode then @int_locals&.include?(r.name) ? nil : r
      when Prism::InstanceVariableReadNode then r
      when Prism::CallNode then r if r.arguments.nil? && r.block.nil? && r.receiver # `obj.attr << v`: the slot becomes a cell (Types)
      end
    end

    def new_exception(cname, arg_nodes)
      k = @classes.fetch(cname) { raise "unknown exception class #{cname}" }
      o = emit(:onew, [k])
      init = k.find_method(:initialize)
      emit(:call, [init, o, *method_args(init, arg_nodes)]) if init
      o
    end

    # begin body rescue K => e; handler end [ensure fin end]
    # try_push installs the handler record; a raise inside the body (or any callee) lands at
    # the handler block with the exception value; try_pop on the normal path.
    def rescue_modifier(n) = begin_expr(nil, stmts: [n.expression], rescues: [[[:StandardError], nil, [n.rescue_expression]]])

    def begin_expr(n, stmts: nil, rescues: nil, ensure_body: nil)
      stmts ||= n.statements&.body || []
      unless rescues
        rescues = []
        r = n.rescue_clause
        while r
          classes = r.exceptions.map { |c| c.is_a?(Prism::ConstantReadNode) ? c.name : raise("rescue needs a class name") }
          classes = [:StandardError] if classes.empty?
          rescues << [classes, r.reference, r.statements&.body || []]; r = r.subsequent
        end
      end
      ensure_body ||= n&.ensure_clause&.statements&.body || []
      return (stmts + ensure_body).map { expr(_1) }.last || const(0) if rescues.empty? && ensure_body.empty?
      hb, mb = @f.new_block(:handler), @f.new_block(:merge)
      retrying = rescues.any? { |(_, _, body)| body.any? { has_node?(_1, Prism::RetryNode) } }
      if retrying # `retry` re-enters the protected body: a header of phis, as a loop has
        rh = @f.new_block(:retry)
        assigned_locals_plain(stmts).uniq.each { |nm| @locals[nm] ||= (c = const(0); c.ty = :nil; c) }
        pre = @cur; emit(:br, [rh])
        rphis = @locals.to_h { |nm, v| ph = rh.phi; ph.args << [pre, v]; [nm, ph] }
        @locals = rphis.dup; @cur = rh
        outer_retry, @retry = @retry, { head: rh, sites: [] }
      end
      before = @locals.dup
      tp = emit(:try_push, [hb])
      bv = stmts.map { expr(_1) }.last || const(0)
      emit(:try_pop, [tp])
      ensure_body.each { expr(_1) }
      bend, blocals = @cur, @locals; emit(:br, [mb]) unless @cur.term
      # the handler: the exception value, then rescue clauses by class
      @cur = hb; @locals = before.dup
      exc = emit(:exc_value, [])
      arms = rescues.map do |(classes, ref, body)|
        test = classes.map { |cn| emit(:isa, [exc, cn]) }.reduce { |a, b| emit(:or, [a, b]) }
        [test, ref, body]
      end
      ends = []
      arms.each do |test, ref, body|
        tb, nb = @f.new_block(:rescue), @f.new_block(:norescue)
        emit(:condbr, [test, tb, nb])
        @cur = tb; @locals = before.dup
        if ref.is_a?(Prism::LocalVariableTargetNode) # the bound exception is narrowed to the rescued class (one class; several stay the union)
          @locals[lname(ref.name)] = classes.size == 1 && @classes[classes[0]] ? emit(:unbox, [exc, classes[0]]) : exc
        end
        rv = body.map { expr(_1) }.last || const(0)
        ensure_body.each { expr(_1) }
        ends << [@cur, @locals, rv] unless @cur.term
        emit(:br, [mb]) unless @cur.term
        @cur = nb; @locals = before.dup
      end
      # nothing matched: run ensure, re-raise (never returns here)
      ensure_body.each { expr(_1) }
      emit(:raise, [exc]); emit(:call, [demand(:__uncaught), exc])
      ends << [@cur, before.dup, const(0)]; emit(:br, [mb])
      @cur = mb
      arms_all = [[bend, blocals, bv], *ends]
      @locals = merge_locals(mb, arms_all.map { |(b, l, _)| [b, l] })
      ph = mb.phi; ph.args = arms_all.map { |(b, _, v)| [b, v] }
      if retrying
        @retry[:sites].each { |(b, l)| rphis.each { |nm, p| p.args << [b, l.fetch(nm)] } }
        @retry = outer_retry
      end
      ph
    end

    def struct_new?(v) = v.is_a?(Prism::CallNode) && v.name == :new && v.receiver.is_a?(Prism::ConstantReadNode) && v.receiver.name == :Struct

    public
    # A prelude generic (`__arr_sort_by(a, keys)`) is Ruby over whatever element type its
    # caller has; two callers with different types get two copies. Re-lower the def into
    # a fresh Func; Types infers the copy against the new call's types.
    def instantiate(f)
      d = @defs_by_func.fetch(f)
      @instances ||= Hash.new(0); n = @instances[f.name] += 1
      g = Func.new(:"#{f.name}$#{n}", f.params.size)
      @defs_by_func[g] = d
      nested { lower_body(g, (d.parameters&.requireds&.map(&:name) || []) + (d.parameters&.optionals&.map(&:name) || []) + (d.parameters&.keywords&.map(&:name) || []), d.body&.body || []) }
      prune(g)
      g
    end
    private

    def lower_body(f, names, stmts, klass = nil, ct = {}, captured = nil, shared_in = [])
      @f, @locals, @cur, @klass, @ct = f, names.zip(f.params).to_h, f.entry, klass, ct
      @block_param = (d = @defs_by_func[f]) && d.parameters&.block ? (d.parameters.block.name || :__blk) : (f.name.to_s.end_with?("$blk") ? :__blk : nil)
      @shared = (stmts.is_a?(Array) ? shared_locals(stmts) : []) + shared_in
      captured&.each { |nm| @locals[nm] = emit(:fld_get, [@locals[:self], klass.ivar(:"@#{nm}")]) } # a lambda's captures: the value, or the shared cell
      if f.name == :main && @mod_ivars # `module M; @x = 1; end` runs before the program
        @mod_ivars.each { |owner, w| @owner = owner; expr(w); @owner = nil }
      end
      if stmts.first.is_a?(Array) && stmts.first[0] == :struct_set # a Struct's initialize
        stmts.each { |(_, fld)| emit(:fld_set, [@locals[:self], klass.ivar(:"@#{fld}"), @locals.fetch(fld)]) }
        emit(:ret, [@locals[:self]])
        return
      end
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
        return :hash if k.is_a?(Array) && k[0] == :hash
        return :range if k == [:range]
        return k if k.is_a?(Symbol) && (@classes[k] || %i[int str].include?(k))
      end
      syntactic_kind(n)
    end

    # the old guess, kept as a fallback for nodes the pre-typing has no answer for
    def syntactic_kind(n)
      case n
      when Prism::ArrayNode then :array
      when Prism::HashNode then :hash
      when Prism::RangeNode then :range
      when Prism::IntegerNode then :int
      when Prism::StringNode, Prism::InterpolatedStringNode then :str
      when Prism::ParenthesesNode then kind_of(n.body.body.last)
      when Prism::LocalVariableReadNode then (@kinds || {})[lname(n.name)]
      when Prism::InstanceVariableReadNode then (@ivar_kinds || {})[[@klass&.name, n.name]]
      when Prism::CallNode
        return :hash if n.name == :new && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Hash
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
      when Prism::IntegerNode then (n.value.bit_length <= 64 or raise "integer literal #{n.value} does not fit 64 bits (Bignum literals not supported yet)"); const(n.value)
      when Prism::FloatNode then fconst(n.value)
      when Prism::NilNode then (c = const(0); c.ty = :nil; c)
      when Prism::TrueNode then (c = const(1); c.ty = :bool; c)
      when Prism::FalseNode then (c = const(0); c.ty = :bool; c)
      when Prism::UnlessNode then if_expr(n, negate: true)
      when Prism::UntilNode then while_stmt(n, negate: true)
      when Prism::CaseNode then case_expr(n)
      when Prism::BeginNode then begin_expr(n)
      when Prism::RescueModifierNode then rescue_modifier(n) # expr rescue fallback
      when Prism::SuperNode, Prism::ForwardingSuperNode # super(args) / super: the superclass's version of this method
        raise "super outside a method" unless @klass && @f.cls
        mname = @f.name.to_s.split("#").last.delete("'").to_sym
        sup = @f.shadowed || @klass.superclass&.find_method(mname) or raise "super: no #{mname} above #{@klass.name}"
        args = n.is_a?(Prism::SuperNode) ? (n.arguments&.arguments || []) : @f.params[1..].map { nil }
        vals = n.is_a?(Prism::SuperNode) ? method_args(sup, args) : @f.params[1..]
        emit(:call, [sup, me_val, *vals])
      when Prism::LambdaNode then lambda_value(n)
      when Prism::ConstantPathNode then expr_const_path(n)
      when Prism::ModuleNode then raise "module in expression position"
      when Prism::LocalVariableOrWriteNode # x ||= v
        cur = @locals[lname(n.name)]
        if cur.nil? || cur.ty == :nil then (v = expr(n.value); @locals[lname(n.name)] = v)
        else cond_assign(cur, false, -> { expr(n.value) }, ->(v) { @locals[lname(n.name)] = v }) end
      when Prism::LocalVariableAndWriteNode # x &&= v
        cond_assign(@locals.fetch(lname(n.name)), true, -> { expr(n.value) }, ->(v) { @locals[lname(n.name)] = v })
      when Prism::IndexOperatorWriteNode # a[i] += v
        recv = expr(n.receiver); k = expr(n.arguments.arguments[0])
        cur = hash_default_of(n.receiver) ? hash_read_with_default(recv, n.arguments.arguments[0], n.receiver) : emit(:idx, [recv, k])
        rhs = expr(n.value)
        v = emit(ARITH.fetch(n.binary_operator), [cur, rhs])
        r = emit(:idx_set, [recv, k, v])
        case n.receiver
        when Prism::LocalVariableReadNode then @locals[lname(n.receiver.name)] = r
        when Prism::InstanceVariableReadNode then emit(:fld_set, [me_val, @klass.ivar(n.receiver.name), r])
        end
        v
      when Prism::IndexOrWriteNode # h[k] ||= v
        recv = expr(n.receiver); k = expr(n.arguments.arguments[0])
        cur = emit(:idx, [recv, k])
        cond_assign(cur, false, -> { expr(n.value) }, ->(v) {
          r = emit(:idx_set, [recv, k, v])
          @locals[lname(n.receiver.name)] = r if n.receiver.is_a?(Prism::LocalVariableReadNode) })
      when Prism::SelfNode then me_val
      when Prism::ArrayNode
        if n.elements.any? { _1.is_a?(Prism::SplatNode) } # [*a, x, *b]: the runs between splats are literals, joined with +
          runs = n.elements.chunk_while { |x, y| !x.is_a?(Prism::SplatNode) && !y.is_a?(Prism::SplatNode) }.to_a
          parts = runs.map { |r| r[0].is_a?(Prism::SplatNode) ? expr(r[0].expression) : pack_values(r.map { expr(_1) }) }
          return parts.reduce { |acc, x| emit(:call, [demand(:__arr_plus), acc, x]) }
        end
        fill = const(0); fill.ty = :nil # element type comes from the first store
        a = emit(:anew, [const(n.elements.size), fill])
        n.elements.each_with_index { |e, k| a = emit(:aset, [a, const(k), expr(e)]) }
        a
      when Prism::HashNode
        h = emit(:hnew, [])
        n.elements.each do |el|
          case el
          when Prism::AssocNode then h = emit(:hset, [h, expr(el.key), expr(el.value)])
          when Prism::AssocSplatNode then h = emit(:call, [demand(:__hash_merge_into), h, expr(el.value)]) # { **other }
          else raise "unsupported hash element #{el.class}"
          end
        end
        h
      when Prism::InstanceVariableReadNode
        return emit(:gget, [:"#{@owner}#{n.name}"]) if @owner # a module's / class object's own ivar
        emit(:fld_get, [me_val, @klass.ivar(n.name)])
      when Prism::InstanceVariableOperatorWriteNode # @x += v
        cur = @owner ? emit(:gget, [:"#{@owner}#{n.name}"]) : emit(:fld_get, [me_val, @klass.ivar(n.name)])
        v = emit(ARITH.fetch(n.binary_operator), [cur, expr(n.value)])
        @owner ? emit(:gset, [:"#{@owner}#{n.name}", v]) : emit(:fld_set, [me_val, @klass.ivar(n.name), v])
        v
      when Prism::InstanceVariableWriteNode
        if @owner then v = expr(n.value); emit(:gset, [:"#{@owner}#{n.name}", v]); return v end
        (@hash_defaults ||= {})[[@klass&.name, n.name]] = n.value.arguments.arguments[0] if hash_new_with_default?(n.value)
        v = expr(n.value)
        ((@ivar_kinds ||= {})[[@klass&.name, n.name]] ||= kind_of(n.value)) if @klass
        emit(:fld_set, [me_val, @klass.ivar(n.name), v]); v
      when Prism::ConstantReadNode
        if n.name == :ARGV then (c = const(0); c.ty = :nil; c) # no arguments: every ARGV[k] is nil
        else emit(:gget, [n.name]) end
      when Prism::ConstantWriteNode
        v = expr(n.value); emit(:gset, [n.name, v]); v
      when Prism::GlobalVariableReadNode then emit(:gget, [n.name])
      when Prism::GlobalVariableWriteNode
        v = expr(n.value); emit(:gset, [n.name, v]); v
      when Prism::LocalVariableReadNode
        if @in_safe_nav && @in_safe_nav_node.equal?(n) then @in_safe_nav
        elsif @ct&.key?(n.name) then (c = const(sym_id(@ct[n.name])); c.ty = :sym; c) # compile-time symbol
        elsif shared?(n.name) then emit(:cell_get, [@locals.fetch(lname(n.name)) { raise "undefined local #{n.name}" }])
        else @locals.fetch(lname(n.name)) { raise "undefined local #{n.name}" } end
      when Prism::LocalVariableWriteNode
        if n.value.is_a?(Prism::LambdaNode) # inlined at `x.call(...)` sites; a value wherever else x is used
          (@lambdas ||= {})[lname(n.name)] = n.value
          return (@locals[lname(n.name)] = lambda_value(n.value))
        end
        v = expr(n.value) # value first: loops replace @locals
        (@kinds ||= {})[lname(n.name)] = kind_of(n.value)
        (@hash_defaults ||= {})[lname(n.name)] = n.value.arguments.arguments[0] if hash_new_with_default?(n.value)
        return write_shared(n.name, v) if shared?(n.name)
        @locals[lname(n.name)] = v
      when Prism::LocalVariableOperatorWriteNode
        if shared?(n.name)
          l = emit(:cell_get, [@locals.fetch(lname(n.name))]); r = expr(n.value)
          return write_shared(n.name, emit(ARITH.fetch(n.binary_operator), [l, r]))
        end
        l = @locals.fetch(lname(n.name)); r = expr(n.value)
        @locals[lname(n.name)] = emit(ARITH.fetch(n.binary_operator), [l, r])
      when Prism::MultiWriteNode # a, @b = x, y  (evaluate all, then bind each target); a, b = arr destructures
        targets = n.lefts + (n.rest ? [n.rest] : []) + n.rights
        vals = if n.value.is_a?(Prism::ArrayNode) && !n.rest then n.value.elements.map { expr(_1) }
               else
                 arr = n.value.is_a?(Prism::ArrayNode) ? expr(n.value) : expr(n.value)
                 lefts = n.lefts.each_index.map { |k| emit(:idx, [arr, const(k)]) }
                 if n.rest # first, *rest, last = arr: the middle takes what is left
                   n_l, n_r = n.lefts.size, n.rights.size
                   mid = emit(:mcall, [:slice_range, arr, const(n_l), const(-1 - n_r), const(0)])
                   rights = n.rights.each_index.map { |k| emit(:idx, [arr, emit(:sub, [emit(:alen, [arr]), const(n_r - k)])]) }
                   lefts + [mid] + rights
                 else lefts end
               end
        targets.zip(vals).each do |t, v|
          next if t.is_a?(Prism::SplatNode) && t.expression.nil? # a, * = arr
          t = t.expression if t.is_a?(Prism::SplatNode)
          case t
          when Prism::LocalVariableTargetNode then @locals[lname(t.name)] = v
          when Prism::InstanceVariableTargetNode
            if @owner then emit(:gset, [:"#{@owner}#{t.name}", v])
            else emit(:fld_set, [me_val, @klass.ivar(t.name), v]) end
          else raise "unsupported assignment target #{t.class}"
          end
        end
        vals.last
      when Prism::RetryNode
        raise "retry outside rescue" unless @retry
        @retry[:sites] << [@cur, @locals.dup]
        emit(:br, [@retry[:head]])
        @cur = @f.new_block(:dead); const(0)
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
        raise "next outside a loop" unless @loop
        if @loop[:next].nil? # a plain while: jump to the header
          @loop[:nexts] << [@cur, @locals.dup] if @loop[:nexts]
          emit(:br, [@loop[:head]])
          @cur = @f.new_block(:dead); return const(0)
        end
        @loop[:nexts] << [@cur, @locals.dup]
        emit(:br, [@loop[:next]])
        @cur = @f.new_block(:dead); const(0)
      when Prism::YieldNode
        if (bv = @locals[@block_param || :__none]) && !@block # yield in a method holding its block as a value
          return emit(:mcall, [:call, bv, *(n.arguments&.arguments || []).map { expr(_1) }])
        end
        raise "yield outside an inlined block method" unless @block
        yield_block(n.arguments&.arguments || [])
      when Prism::RangeNode then range_array(n) # a Range as a value: its elements (each/map/times fuse before reaching here)
      when Prism::SymbolNode then (c = const(sym_id(n.unescaped)); c.ty = :sym; c)
      when Prism::ParenthesesNode then n.body.body.map { expr(_1) }.last
      when Prism::StringNode then emit(:sconst, [n.unescaped])
      when Prism::InterpolatedStringNode # "a#{x}b" -> concat chain
        parts = n.parts.map do |part|
          case part
          when Prism::StringNode then emit(:sconst, [part.unescaped])
          when Prism::EmbeddedStatementsNode then to_s(expr(part.statements.body.last))
          when Prism::InterpolatedStringNode then expr(part) # "a#{x}" \ "b#{y}": adjacent literals
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
    # Guards narrow (notes/33). facts(cond, truth): the [[local, Class]] that hold on the
    # edge where cond came out `truth`. Applying one rebinds the local to unbox(v, Class):
    # the locals map is the SSA renamer, so a narrowing is one assignment.
    def facts(n, truth)
      case n
      when Prism::ParenthesesNode then facts(n.body.body.last, truth)
      when Prism::AndNode then truth ? facts(n.left, true) + facts(n.right, true) : []
      when Prism::OrNode then truth ? [] : facts(n.left, false) + facts(n.right, false)
      when Prism::CallNode
        if n.name == :! && n.receiver then facts(n.receiver, !truth)
        elsif truth && n.name == :is_a? && n.receiver.is_a?(Prism::LocalVariableReadNode) && n.arguments&.arguments&.first.is_a?(Prism::ConstantReadNode)
          [[lname(n.receiver.name), n.arguments.arguments.first.name]]
        else [] end
      else []
      end
    end

    def narrow(facts)
      facts.each { |nm, cname| @locals[nm] = emit(:unbox, [@locals.fetch(nm), kind_for(cname)]) if @locals[nm] }
    end

    # a narrowed name was only a view: unless the region assigned it, the original flows on
    def unnarrow(facts, before)
      facts.each { |nm, _| @locals[nm] = before[nm] if @locals[nm]&.op == :unbox && before[nm] }
    end

    def cond_branch(n, tb, eb)
      case n
      when Prism::AndNode
        mid = @f.new_block(:and); cond_branch(n.left, mid, eb); @cur = mid
        saved = @locals.dup; narrow(facts(n.left, true))   # the right side runs only when the left held
        cond_branch(n.right, tb, eb); unnarrow(facts(n.left, true), saved)
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
      if n.safe_navigation? && !@in_safe_nav # x&.m: nil when x is nil
        r = expr(n.receiver)
        return (c = const(0); c.ty = :nil; c) if r.ty == :nil
        tb, eb, mb = @f.new_block(:snthen), @f.new_block(:snelse), @f.new_block(:snmerge)
        emit(:condbr, [r, tb, eb])
        @cur = tb; @in_safe_nav = r; @in_safe_nav_node = n.receiver; v = call(n); @in_safe_nav = nil; tend = @cur; emit(:br, [mb])
        @cur = eb; nilv = const(0); nilv.ty = :nil; emit(:br, [mb])
        @cur = mb; ph = mb.phi; ph.args = [[tend, v], [eb, nilv]]; return ph
      end
      # a receiver known to be a user object: its method, whatever the name (size, push, to_s ...
      # all mean the class's own method, not the builtin shortcut below)
      if n.receiver && !n.block && !n.receiver.is_a?(Prism::ConstantReadNode) && (k = kind_of(n.receiver)).is_a?(Symbol) && @classes[k] && !%i[== != < <= > >= + - * / % [] []= nil? is_a? ! << send public_send respond_to? class_eval instance_variable_get].include?(n.name)
        rv = expr(n.receiver)
        return emit(:mcall, [n.name, rv, *object_args(n, args, @classes[k], rv)])
      end
      if n.block.is_a?(Prism::BlockNode) && n.receiver.nil? && (f = @funcs[n.name]) && (d = @defs_by_func[f]) && d.parameters&.block
        blk = n.block
        params = blk.parameters&.parameters&.requireds&.map(&:name) || []
        c = closure_value(params, free_locals(blk.body, params).select { |nm| @locals.key?(lname(nm)) }, blk.body&.body || [])
        return emit(:call, [f, *call_args(f, args), c])
      end
      if n.block.is_a?(Prism::BlockArgumentNode) && n.block.expression.is_a?(Prism::SymbolNode) && n.receiver
        return block_call(n, args) # map(&:upcase), group_by(&:length), ...: the block { |e| e.sym }
      end
      if n.block.is_a?(Prism::BlockArgumentNode) # m(&b): the block is already a value
        bv = expr(n.block.expression)
        return block_arg_call(n, args, bv)
      end
      return block_call(n, args) if n.block.is_a?(Prism::BlockNode)
      if n.name == :<< && (root = append_root(n)) # `<<` is append on strings/arrays and shift on integers; Types fixes up a misguess
        a = expr(n.receiver); v = expr(args[0])
        r = emit(:lshift_or_append, [a, v])
        case root # the chain's home is rebound to the result (a grown string/array may have moved)
        when Prism::LocalVariableReadNode then @locals[root.name] = r
        when Prism::InstanceVariableReadNode then emit(:fld_set, [@locals.fetch(:self), @klass.ivar(root.name), r])
        end
        return r
      end
      if n.receiver.nil? && n.name.to_s.start_with?("__") && !@funcs[n.name] && !(@klass && @klass.find_method(n.name))
        return intrinsic(n.name, args) # the GC prelude's raw memory access
      end
      if n.name == :-@ && args.empty? # unary minus: 0 - x
        v = expr(n.receiver)
        return emit(:sub, [v.ty == :float ? fconst(0.0) : const(0), v])
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
      if n.name == :% && n.receiver && (kind_of(n.receiver) == :str || n.receiver.is_a?(Prism::StringNode) || n.receiver.is_a?(Prism::InterpolatedStringNode))
        list = args[0].is_a?(Prism::ArrayNode) ? args[0].elements : [args[0]] # "fmt" % args
        return emit(:call, [demand(:__format), expr(n.receiver), dyn_array(list)])
      end
      if (op = ARITH[n.name])
        l = expr(n.receiver); r = expr(args[0])
        emit(op, [l, r])
      elsif (c = CMP[n.name])
        l = expr(n.receiver); r = expr(args[0])
        emit(:cmp, [l, r], c)
      elsif n.name == :<=> && args.size == 1 && n.receiver
        emit(:mcall, [:<=>, expr(n.receiver), expr(args[0])]) # Types: ints/strings via the prelude, objects via their method
      elsif n.name == :to_i && args.empty? then emit(:to_i, [expr(n.receiver)])
      elsif n.name == :to_f && args.empty? then emit(:to_f, [expr(n.receiver)])
      elsif n.name == :putc
        a = args[0]
        if a.is_a?(Prism::StringNode) then emit(:putc, [const(a.unescaped.ord)])
        else emit(:putc, [expr(a)]) end
      elsif n.name == :puts && n.receiver.is_a?(Prism::GlobalVariableReadNode) && n.receiver.name == :$stderr && args.size == 1
        emit(:eputs_v, [expr(args[0])])  # $stderr.puts x
      elsif n.name == :puts && (n.receiver.nil? || n.receiver.is_a?(Prism::GlobalVariableReadNode) && n.receiver.name == :$stdout || n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :STDOUT)
        return emit(:puts_s, [""]) if args.empty?
        r = nil
        args.each do |a| # puts a, b: one line each
          r = if a.is_a?(Prism::StringNode) then emit(:puts_s, [a.unescaped])
              else emit(:puts_v, [expr(a)]) end # Types picks puts_i / puts_str
        end
        r
      elsif n.name == :p && n.receiver.nil? && args.size > 1
        args.each { |a| p_one(a) }; return const(0)   # p a, b: one line each
      elsif n.name == :p && n.receiver.nil? && args.size == 1 then p_one(args[0])
      elsif n.name == :inspect && args.empty? && n.receiver then inspect_str(n.receiver)
      elsif n.name == :print && n.receiver.nil? && args.size == 1
        emit(:print_v, [expr(args[0])])   # no newline
      elsif n.name == :Integer && n.receiver.nil? && args.size == 1
        emit(:to_i, [expr(args[0])])      # Integer(x): the parse, no exception on junk (yet)
      elsif n.name == :include? && args.size == 1 && n.receiver.is_a?(Prism::ConstantReadNode) && (k = @classes[n.receiver.name]) && args[0].is_a?(Prism::ConstantReadNode)
        c = const(Types.ancestor?(k, args[0].name) ? 1 : 0); c.ty = :bool; c # Klass.include?(M): a compile-time fact
      elsif n.name == :name && args.empty? && n.receiver.is_a?(Prism::ConstantReadNode) && @classes[n.receiver.name]
        emit(:sconst, [n.receiver.name.to_s]) # Klass.name
      elsif n.name == :name && args.empty? && n.receiver.is_a?(Prism::CallNode) && n.receiver.name == :class && n.receiver.arguments.nil? && n.receiver.receiver
        expr(n.receiver) # obj.class.name: the class is already its name (no class objects)
      elsif n.name == :ancestors && args.empty? && n.receiver.is_a?(Prism::ConstantReadNode) then raise "ancestors: no class objects at run time"
      elsif n.name == :extend && args.size == 1 && n.receiver then raise "extend on an instance: singleton methods are not supported (every object of a class shares its methods)"
      elsif n.name == :is_a? && args.size == 1 && n.receiver && args[0].is_a?(Prism::ConstantReadNode)
        emit(:isa, [expr(n.receiver), args[0].name])
      elsif n.name == :nil? && args.empty? && n.receiver
        v = expr(n.receiver); emit(:cmp, [v, (c = const(0); c.ty = :nil; c)], :eq)
      elsif n.name == :to_s && args.empty? && n.receiver.nil? && @klass && @klass.find_method(:to_s) # bare to_s: self's
        emit(:call, [@klass.find_method(:to_s), me_val])
      elsif n.name == :to_s && args.empty? && n.receiver.nil? then raise "to_s with no receiver outside a class defining it"
      elsif n.name == :to_s && args.empty? then to_s(expr(n.receiver))
      elsif n.name == :+@ && args.empty? then expr(n.receiver) # +"" : literals are already fresh copies
      elsif n.name == :new && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Array
        len = args[0] ? expr(args[0]) : const(0); fill = args[1] ? expr(args[1]) : (c = const(0); c.ty = :nil; c)
        emit(:anew, [len, fill])
      elsif n.name == :new && (n.receiver.is_a?(Prism::ConstantReadNode) || n.receiver.is_a?(Prism::ConstantPathNode)) && @classes[n.receiver.name]
        k = @classes[n.receiver.name]
        obj = emit(:onew, [k])
        if (init = k.find_method(:initialize))
          emit(:call, [init, obj, *method_args(init, args)])
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
      elsif n.name == :pow && args.size == 1 && n.receiver && !const_recv?(n) then emit(:pow, [expr(n.receiver), expr(args[0])])
      elsif n.name == :pow && args.size == 2 && n.receiver && !const_recv?(n) then emit(:call, [demand(:__num_pow_mod), expr(n.receiver), expr(args[0]), expr(args[1])])
      elsif %i[length size bytesize].include?(n.name) && args.empty? && n.receiver then emit(:alen, [expr(n.receiver)])
      elsif (n.name == :even? || n.name == :odd?) && args.empty? && n.receiver
        emit(:cmp, [emit(:and, [expr(n.receiver), const(1)]), const(0)], n.name == :even? ? :eq : :ne)
      elsif n.name == :chr && args.empty? && n.receiver then emit(:chr, [expr(n.receiver)])
      elsif n.name == :pass && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Thread then const(0) # no preemption: nothing to yield to
      elsif %i[lock synchronize sleep].include?(n.name) || n.receiver.is_a?(Prism::ConstantReadNode) && %i[Mutex Queue].include?(n.receiver.name)
        raise "#{n.name}: threads run to completion at Thread.new here; anything that would observe interleaving is not supported"
      elsif n.name == :delete && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :File
        emit(:call, [demand(:__file_delete), expr(args[0])])
      elsif n.name == :clock_gettime && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Process
        emit(:clock, [])                 # Process.clock_gettime(any clock): monotonic seconds as a Float
      elsif n.name == :round && args.size == 1 && n.receiver
        if args[0].is_a?(Prism::IntegerNode) && args[0].value <= 0 # x.round(0) is an Integer in Ruby
          emit(:call, [demand(:__float_round0), expr(n.receiver)])
        else
          emit(:call, [demand(:__float_round), expr(n.receiver), expr(args[0])])
        end
      elsif n.name == :raise && n.receiver.nil?
        # raise "m" -> RuntimeError.new("m"); raise K, "m" -> K.new("m"); raise obj -> obj
        exc = if args.empty? then new_exception(:RuntimeError, [])
              elsif args[0].is_a?(Prism::ConstantReadNode) && @classes[args[0].name] then new_exception(args[0].name, args[1..])
              elsif (k = kind_of(args[0])).is_a?(Symbol) && @classes[k] then expr(args[0]) # raise exc_object
              else new_exception(:RuntimeError, [args[0]]) end # raise "message" (any String expression)
        emit(:raise, [exc]); emit(:call, [demand(:__uncaught), exc]) # rt_raise returns only when nothing catches (then exit)
        return const(0)
      elsif %i[printf format sprintf].include?(n.name) && n.receiver.nil? && args[0]
        str = emit(:call, [demand(:__format), expr(args[0]), dyn_array(args[1..])])
        n.name == :printf ? emit(:print_v, [str]) : str

      elsif n.name == :split && args.empty? && n.receiver then emit(:mcall, [:split, expr(n.receiver), emit(:sconst, [" "])]) # split on whitespace
      elsif %i[sort! reverse! uniq! shuffle! compact! flatten!].include?(n.name) && args.empty? && n.receiver && !n.block # in place: compute, then write back into the same handle
        r = expr(n.receiver)
        emit(:call, [demand(:__arr_replace), r, emit(:mcall, [n.name.to_s.chomp("!").to_sym, r])])
      elsif n.name == :each_with_index && args.empty? && n.receiver && !n.block then emit(:mcall, [:each_with_index_pairs, expr(n.receiver)]) # arr.each_with_index.map { |x, i| }
      elsif n.name == :times && args.empty? && n.receiver && !n.block then range_array(n)                 # 3.times.to_a
      elsif n.name == :each_char && args.empty? && n.receiver && !n.block then emit(:mcall, [:chars, expr(n.receiver)]) # "ab".each_char.to_a
      elsif n.name == :to_a && args.empty? && n.receiver && (k = kind_of(n.receiver)) == :array then expr(n.receiver)
      elsif %i[reduce inject].include?(n.name) && n.receiver && !n.block && args.size >= 1 && args.last.is_a?(Prism::SymbolNode)
        op = ARITH.fetch(args.last.unescaped.to_sym) { raise "reduce(:#{args.last.unescaped}): not an operator" }
        arr = expr(n.receiver)
        accv = :"fold#{@f.blocks.size}:v"
        @locals[accv] = args.size == 2 ? expr(args[0]) : emit(:aget, [arr, const(0)])
        counted_loop(args.size == 2 ? const(0) : const(1), emit(:alen, [arr]), :lt, [], []) { |i, _ps, _pfx| @locals[accv] = emit(op, [@locals[accv], emit(:aget, [arr, i])]) }
        @locals.delete(accv)
      elsif n.name == :pop && args.empty? && n.receiver then emit(:apop, [expr(n.receiver)])
      elsif n.name == :to_a && args.empty? && (r = n.receiver.is_a?(Prism::ParenthesesNode) ? n.receiver.body.body.last : n.receiver).is_a?(Prism::RangeNode)
        lo = expr(r.left); hi = expr(r.right); hi = emit(:add, [hi, const(1)]) unless r.exclude_end?
        len = emit(:sub, [hi, lo]); arr = emit(:anew, [len, const(0)])
        outv = :"toa#{@f.blocks.size}:out"; @locals[outv] = arr
        counted_loop(const(0), len, :lt, [], []) { |i, _ps, _pfx| @locals[outv] = emit(:aset, [@locals[outv], i, emit(:add, [lo, i])]) }
        @locals.delete(outv)
      elsif n.name == :push && (n.receiver.is_a?(Prism::LocalVariableReadNode) || n.receiver.is_a?(Prism::InstanceVariableReadNode)) && !((k = kind_of(n.receiver)).is_a?(Symbol) && @classes[k])
        a = expr(n.receiver); v = expr(args[0]); len = emit(:alen, [a])
        r = emit(:aset, [a, len, v]) # may grow: rebind the home
        if n.receiver.is_a?(Prism::LocalVariableReadNode) then @locals[lname(n.receiver.name)] = r
        else emit(:fld_set, [me_val, @klass.ivar(n.receiver.name), r]) end
        r
      elsif n.name == :[] && args.size == 1 && args[0].is_a?(Prism::RangeNode) # s[a..b], a[2..], a[..-2]
        rg = args[0]
        lo = rg.left ? expr(rg.left) : const(0)
        hi = rg.right ? expr(rg.right) : const(-1) # to the end (an endless range)
        excl = rg.exclude_end? && rg.right ? const(1) : const(0)
        emit(:mcall, [:slice_range, expr(n.receiver), lo, hi, excl])
      elsif n.name == :[] # array / hash / string: Types decides
        r = expr(n.receiver)
        return (c = const(0); c.ty = :nil; c) if r.ty == :nil # nil[k] (ARGV) is nil at compile time
        return hash_read_with_default(r, args[0], n.receiver) if (dn = hash_default_of(n.receiver))
        emit(:idx, [r, *args.map { expr(_1) }])
      elsif n.name == :new && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Hash
        raise "Hash.new with a block: not supported yet" if n.block
        emit(:hnew, []) # a default, if any, is recorded by the assignment (hash_default_of)
      elsif n.name == :[]=
        # a[i] = v may grow a: the result is the (possibly new) container, rebound to its home
        a = expr(n.receiver); i = expr(args[0]); v = expr(args[1])
        r = emit(:idx_set, [a, i, v])
        case n.receiver
        when Prism::LocalVariableReadNode then @locals[lname(n.receiver.name)] = r
        when Prism::InstanceVariableReadNode then emit(:fld_set, [me_val, @klass.ivar(n.receiver.name), r])
        when Prism::CallNode then nil # a[i][j] = v, obj.attr[i] = v: the element store is in place; growth would need the cell design
        else raise "[]= on #{n.receiver.class}"
        end
        v
      elsif (n.name == :key? || n.name == :has_key?) && args.size == 1 && n.receiver
        emit(:hkey, [expr(n.receiver), expr(args[0])])
      elsif n.name == :keys && args.empty? && n.receiver
        emit(:hkeys, [expr(n.receiver)])
      elsif n.receiver.is_a?(Prism::ConstantReadNode) && (sf = @funcs[:"#{n.receiver.name}.#{n.name}"])
        emit(:call, [sf, *call_args(sf, args)])                           # Owner.m(...)
      elsif n.receiver.nil? && @owner && (sf = @funcs[:"#{@owner}.#{n.name}"])
        emit(:call, [sf, *call_args(sf, args)])                           # m(...) inside Owner's singleton methods
      elsif n.receiver.is_a?(Prism::ConstantReadNode) && !@classes[n.receiver.name] && !@modules.include?(n.receiver.name) && n.receiver.name != :Math
        emit(:mcall, [n.name, expr(n.receiver), *args.map { expr(_1) }]) # a constant holding an object: RAND.rand
      elsif n.receiver && !n.receiver.is_a?(Prism::ConstantReadNode)
        # a method call on an object: resolved by Types once the receiver's class is known
        rv = expr(n.receiver)
        emit(:mcall, [n.name, rv, *object_args(n, args, nil, rv)])
      elsif @klass && @klass.find_method(n.name) && !@funcs[n.name]
        me = @name_pfx ? @locals.fetch(:"#{@name_pfx}self") : @locals.fetch(:self)
        emit(:call, [@klass.find_method(n.name), me, *method_args(@klass.find_method(n.name), args, me)])
      elsif @klass && args.empty? && n.receiver.nil? && (iv = @klass.find_reader(n.name)) && !@funcs[n.name]
        emit(:fld_get, [me_val, @klass.ivar(iv)]) # a bare attr_reader call inside a method
      else
        f = @funcs.fetch(n.name) { raise "unknown method #{n.name}" }
        f = demand(n.name) if n.name.to_s.start_with?("__")
        emit(:call, [f, *call_args(f, args)])
      end
    end

    def with_default_self(pfx)
      return yield unless @default_self
      recv, cls = @default_self
      saved_k, saved_pfx = @klass, @name_pfx
      @klass, @name_pfx = cls, pfx
      @locals[:"#{pfx}self"] = recv
      yield
    ensure
      @klass, @name_pfx = saved_k, saved_pfx if @default_self
    end

    # optional parameters: missing arguments take their default expressions,
    # evaluated at the call site with earlier parameters bound
    def fill_defaults(f, vals, kw = nil)
      d = @defs_by_func[f] or raise "#{f.name}: wrong number of arguments"
      ps = d.parameters
      names = ps.requireds.map(&:name) + ps.optionals.map(&:name) + (ps.rest.is_a?(Prism::RestParameterNode) ? [ps.rest.name || :__rest] : []) + ps.keywords.map(&:name)
      pfx = :"dflt#{@f.blocks.size}:"
      names.each_with_index { |nm, k| @locals[:"#{pfx}#{nm}"] = vals[k] if vals[k] }
      @blk_pfx = (@blk_pfx || []) << pfx
      with_default_self(pfx) do
        ps.optionals.each_with_index do |o, k|
          idx = ps.requireds.size + k
          next if vals[idx]
          vals[idx] = expr(o.value); @locals[:"#{pfx}#{o.name}"] = vals[idx]
        end
      end
      given = {}
      kw&.elements&.each { |el| given[el.key.unescaped.to_sym] = el.value }
      ps.keywords.each_with_index do |kp, k|
        idx = ps.requireds.size + ps.optionals.size + (ps.rest.is_a?(Prism::RestParameterNode) ? 1 : 0) + k
        node = given.fetch(kp.name) { kp.respond_to?(:value) && kp.value or raise "missing keyword #{kp.name} for #{f.name}" }
        vals[idx] = given.key?(kp.name) ? expr(node) : with_default_self(pfx) { expr(node) }
        @locals[:"#{pfx}#{kp.name}"] = vals[idx]
      end
      if ps.keyword_rest.is_a?(Prism::KeywordRestParameterNode) # **rest: the keywords no parameter names, as a symbol-keyed hash
        idx = ps.requireds.size + ps.optionals.size + (ps.rest.is_a?(Prism::RestParameterNode) ? 1 : 0) + ps.keywords.size
        named = ps.keywords.map(&:name)
        h = emit(:hnew, [])
        given.each { |nm, node| h = emit(:hset, [h, (c = const(sym_id(nm.to_s)); c.ty = :sym; c), expr(node)]) unless named.include?(nm) }
        vals[idx] = h
      end
      @blk_pfx.pop
      @locals.delete_if { |k, _| k.to_s.start_with?(pfx.to_s) }
      vals
    end

    # raw memory / addresses for the collector (lib/indus/rt/gc.rb)
    def intrinsic(name, args)
      case name
      when :__ld then emit(:rawld, [expr(args[0])])
      when :__ld32 then emit(:rawld32, [expr(args[0])])
      when :__ld8 then emit(:rawld8, [expr(args[0]), expr(args[1])])          # byte i of string s
      when :__st8 then (a = expr(args[0]); ix = expr(args[1]); v = expr(args[2]); emit(:rawst8, [a, ix, v]); v)
      when :__sdup then emit(:sdup, [expr(args[0])])
      when :__is_sym then emit(:is_sym, [expr(args[0])]) # true when the value's static type is Symbol (Types folds it)
      when :__is_dyn then emit(:is_dyn, [expr(args[0])])
      when :__hcount then emit(:hcap, [expr(args[0])])                      # entries in insertion order: count, key i, value i
      when :__hkey_at then emit(:hkey_at, [expr(args[0]), expr(args[1])])
      when :__hval_at then emit(:hval_at, [expr(args[0]), expr(args[1])])
      when :__hkey_p then emit(:hkey, [expr(args[0]), expr(args[1])])
      # the five file primitives, libc in-process (a standalone binary needs the syscalls; refused until then)
      when :__sys_open then emit(:sys, [:open, expr(args[0]), expr(args[1])])   # open(path, O_RDONLY): no mode (libc open is variadic; Apple arm64 passes variadic args on the stack)
      when :__sys_creat then emit(:sys, [:creat, expr(args[0]), expr(args[1])]) # creat(path, mode) = open(path, O_WRONLY|O_CREAT|O_TRUNC, mode), not variadic
      when :__sys_read then emit(:sys, [:read, expr(args[0]), expr(args[1]), expr(args[2])])
      when :__sys_write then emit(:sys, [:write, expr(args[0]), expr(args[1]), expr(args[2])])
      when :__sys_close then emit(:sys, [:close, expr(args[0])])
      when :__sys_unlink then emit(:sys, [:unlink, expr(args[0])])
      when :__sys_exit then emit(:sys, [:exit, expr(args[0])])
      when :__salloc then emit(:salloc, [expr(args[0])])                    # a fresh string of n bytes, contents undefined
      when :__st then (a = expr(args[0]); v = expr(args[1]); emit(:rawst, [a, v]); v)
      when :__gbase then emit(:gbase, [])
      when :__adr_tables then emit(:adrlbl, [:__gc_tables])
      when :__adr_text then emit(:adrlbl, [:__text_base])
      when :__dbg then emit(:puts_i, [expr(args[0])])
      when :__mmap then emit(:rawmmap, [expr(args[0])])
      when :__trap then emit(:trap, [])
      # unsigned / wrapping 64-bit arithmetic for the float printer
      when :__fbits then emit(:fbits, [expr(args[0])])
      when :__lsr then emit(:lsr, [expr(args[0]), expr(args[1])])
      when :__clz then emit(:clz, [expr(args[0])])
      when :__umulh then emit(:umulh, [expr(args[0]), expr(args[1])])
      when :__wmul then emit(:wmul, [expr(args[0]), expr(args[1])])
      when :__wadd then emit(:wadd, [expr(args[0]), expr(args[1])])
      when :__wsub then emit(:wsub, [expr(args[0]), expr(args[1])])
      when :__ult then emit(:ucmp, [expr(args[0]), expr(args[1])], :lo)
      when :__ule then emit(:ucmp, [expr(args[0]), expr(args[1])], :ls)
      when :__tag then emit(:dyn_tag, [expr(args[0])])                      # low 4 bits
      when :__same then emit(:ucmp, [expr(args[0]), expr(args[1])], :eq) # raw word identity, never rewritten
      when :__box_int then emit(:box, [expr(args[0]), :int])
      when :__box_str then emit(:box, [expr(args[0]), :str])
      when :__box_float then emit(:box, [expr(args[0]), :float])
      when :__unbox_int then emit(:unbox, [expr(args[0]), :int])
      when :__unbox_str then emit(:unbox, [expr(args[0]), :str])
      when :__unbox_arr then emit(:unbox, [expr(args[0]), [:arr, :dyn]])
      when :__unbox_float then emit(:unbox, [expr(args[0]), :float])
      when :__unbox_bool then emit(:unbox, [expr(args[0]), :bool])
      when :__unbox_sym then emit(:unbox, [expr(args[0]), :sym])
      when :__gset_int then (v = expr(args[1]); emit(:gset, [args[0].unescaped.to_sym, v]); v)
      when :__gget_int then emit(:gget, [args[0].unescaped.to_sym])
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
      if %i[map! collect! select! reject! sort_by!].include?(n.name) && n.receiver && !@recv_value # in place: compute, then write back into the same handle
        fresh = block_call(n.copy(name: n.name.to_s.chomp("!").to_sym), args)
        return emit(:call, [demand(:__arr_replace), expr(n.receiver), fresh])
      end
      # `(a..b).select { }`, `(a..b).reduce { }`, `n.times.map { }`: materialise the range, then iterate the array
      if n.receiver && !@recv_value && !%i[each map each_with_index times upto new open each_line sort_by min_by max_by sum count].include?(n.name)
        r = n.receiver.is_a?(Prism::ParenthesesNode) ? n.receiver.body.body.last : n.receiver
        if r.is_a?(Prism::RangeNode) || times_enum?(r)
          arr = range_array(r)
          return iterate_array_value(n, args, arr)
        end
      end
      if n.receiver && !@recv_value && n.name == :map && times_enum?(n.receiver)
        return iterate_array_value(n, args, range_array(n.receiver))
      end
      if blk.is_a?(Prism::BlockArgumentNode) # m(&:sym) is m { |e| e.sym }
        sym = blk.expression.unescaped.to_sym
        params = [:__e]
        body = ->(pfx) { call_on_value(sym, @locals.fetch(:"#{pfx}__e")) }
      else
        params = case blk.parameters
                 when Prism::NumberedParametersNode then (1..blk.parameters.maximum).map { :"_#{_1}" }
                 when nil then []
                 else blk.parameters.parameters.requireds.map(&:name)
                 end
        body = blk.body&.body || []
      end
      recv = n.receiver
      case n.name
      when :times then counted_loop(const(0), expr(recv), :lt, params, body)
      when :upto then counted_loop(expr(recv), expr(args[0]), :le, params, body)
      when :new # Thread.new(args) { |params| body }: the thread runs to completion here (one legal
                # schedule under the GVL: nothing else is required to run). Its value is the body's.
        if recv.is_a?(Prism::ConstantReadNode) && recv.name == :Thread
          pfx = :"blk#{@f.blocks.size}:"
          params.each_with_index { |pn, k| @locals[:"#{pfx}#{pn}"] = expr(args[k]) if args[k] }
          @blk_pfx = (@blk_pfx || []) << pfx
          last = nil; body.each { last = expr(_1) }
          @blk_pfx.pop
          @locals.delete_if { |k, _| k.to_s.start_with?(pfx.to_s) }
          return last || const(0)
        end
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
      when :lambda, :proc # lambda { |x| } / proc { |x| }: a closure value
        if recv.nil? || (n.name == :new && recv.is_a?(Prism::ConstantReadNode) && recv.name == :Proc)
          blk = n.block
          raise "a block inside a method cannot yet refer to self or @ivars" if @klass && refers_to_self?(blk.body)
          return closure_value(params, free_locals(blk.body, params).select { |nm| @locals.key?(lname(nm)) }, body)
        end
      when :open # File.open(path, mode) { |f| ... }: f is the descriptor, closed after the block
        raise "block passed to #{recv&.name}.open" unless recv.is_a?(Prism::ConstantReadNode) && recv.name == :File
        fd = emit(:call, [demand(:__file_open), expr(args[0]), args[1] ? expr(args[1]) : emit(:sconst, ["r"])])
        pfx = :"blk#{@f.blocks.size}:"
        @locals[:"#{pfx}#{params[0]}"] = fd if params[0]
        @blk_pfx = (@blk_pfx || []) << pfx
        body.each { expr(_1) }
        @blk_pfx.pop
        @locals.delete_if { |k, _| k.to_s.start_with?(pfx.to_s) }
        return emit(:call, [demand(:__file_close), fd])
      when :each_line # fd.each_line { |line| }: the whole file, split keeping each newline
        lines = emit(:call, [demand(:__fd_lines), expr(recv)])
        return array_loop(lines, :each, params, body)
      when :sort_by, :min_by, :max_by # Schwartzian: keys once by `map`, then the prelude sorts/selects by key
        if recv && !@recv_value && kind_of(recv) == :hash # a hash: sort its pairs
          return iterate_array_value(n, args, hash_pairs(expr(recv)))
        end
        arr = recv_val(recv)
        keys = array_loop(arr, :map, params, body)
        return emit(:call, [demand(:"__arr_#{n.name}"), arr, keys])
      when :reduce, :inject # a fold: acc = body(acc, elem)
        arr = recv_val(recv)
        accv = :"fold#{@f.blocks.size}:v"
        start = args[0] ? expr(args[0]) : nil
        first = start ? const(0) : const(1)
        @locals[accv] = start || emit(:aget, [arr, const(0)])
        len = emit(:alen, [arr])
        counted_loop(first, len, :lt, params, body) do |i, ps, pfx|
          @locals[:"#{pfx}#{ps[0]}"] = @locals[accv] if ps[0]
          @locals[:"#{pfx}#{ps[1]}"] = emit(:aget, [arr, i]) if ps[1]
          @fold_target = accv
        end
        return @locals.delete(accv)
      when :any?, :all?, :none?, :find, :detect, :find_index, :count_if # one boolean / one element out of a pass
        arr = recv_val(recv)
        resv = :"pred#{@f.blocks.size}:v"
        @locals[resv] = case n.name when :all? then const(1) when :any?, :none? then const(0) when :find, :detect then (c = const(0); c.ty = :nil; c) else const(-1) end
        len = emit(:alen, [arr])
        counted_loop(const(0), len, :lt, params, body) do |i, ps, pfx|
          @locals[:"#{pfx}#{ps[0]}"] = emit(:aget, [arr, i]) if ps[0]
          @pred_target = [resv, n.name, emit(:aget, [arr, i]), i]
        end
        r = @locals.delete(resv)
        return emit(:cmp, [r, const(0)], n.name == :none? ? :eq : :ne) if %i[any? all? none?].include?(n.name) # a Boolean
        return r
      when :group_by # Hash of key -> [elements]
        arr = recv_val(recv)
        hv = :"grp#{@f.blocks.size}:h"
        @locals[hv] = emit(:hnew, [])
        len = emit(:alen, [arr])
        counted_loop(const(0), len, :lt, params, body) do |i, ps, pfx|
          @locals[:"#{pfx}#{ps[0]}"] = emit(:aget, [arr, i]) if ps[0]
          @group_target = [hv, emit(:aget, [arr, i])]
        end
        return @locals.delete(hv)
      when :partition # [accepted, rejected]
        arr = recv_val(recv)
        yes = :"part#{@f.blocks.size}:y"; no = :"part#{@f.blocks.size}:n"
        @locals[yes] = emit(:anew, [const(0), (c = const(0); c.ty = :nil; c)]); @locals[no] = emit(:anew, [const(0), (c = const(0); c.ty = :nil; c)])
        len = emit(:alen, [arr])
        counted_loop(const(0), len, :lt, params, body) do |i, ps, pfx|
          @locals[:"#{pfx}#{ps[0]}"] = emit(:aget, [arr, i]) if ps[0]
          @partition_target = [yes, no, emit(:aget, [arr, i])]
        end
        pair = emit(:anew, [const(2), (c = const(0); c.ty = :nil; c)])
        pair = emit(:aset, [pair, const(0), @locals.delete(yes)]); emit(:aset, [pair, const(1), @locals.delete(no)])
      when :each_with_object # the memo is the block's second argument and the result
        arr = recv_val(recv); memo = expr(args[0])
        mv = :"ewo#{@f.blocks.size}:m"; @locals[mv] = memo
        len = emit(:alen, [arr])
        counted_loop(const(0), len, :lt, params, body) do |i, ps, pfx|
          @locals[:"#{pfx}#{ps[0]}"] = emit(:aget, [arr, i]) if ps[0]
          @locals[:"#{pfx}#{ps[1]}"] = @locals[mv] if ps[1]
          @memo_target = [mv, :"#{pfx}#{ps[1]}"] if ps[1] # the block may grow the memo: take its view back
        end
        return @locals.delete(mv)
      when :flat_map # map, then one level of concatenation
        arr = recv_val(recv)
        outv = :"fm#{@f.blocks.size}:out"
        @locals[outv] = emit(:anew, [const(0), (c = const(0); c.ty = :nil; c)])
        len = emit(:alen, [arr])
        counted_loop(const(0), len, :lt, params, body) do |i, ps, pfx|
          @locals[:"#{pfx}#{ps[0]}"] = emit(:aget, [arr, i]) if ps[0]
          @flat_target = outv
        end
        return @locals.delete(outv)
      when :select, :reject, :filter # the elements the body accepts
        arr = recv_val(recv)
        outv = :"sel#{@f.blocks.size}:out"
        @locals[outv] = emit(:anew, [const(0), (c = const(0); c.ty = :nil; c)])
        len = emit(:alen, [arr])
        counted_loop(const(0), len, :lt, params, body) do |i, ps, pfx|
          @locals[:"#{pfx}#{ps[0]}"] = emit(:aget, [arr, i]) if ps[0]
          @select_target = [outv, emit(:aget, [arr, i]), n.name == :reject]
        end
        return @locals.delete(outv)
      when :sum, :count # accumulate the block's value / truthiness
        accv = :"acc#{@f.blocks.size}:v"
        @locals[accv] = const(0)
        r = recv.is_a?(Prism::ParenthesesNode) ? recv.body.body.last : recv
        iter = ->(i, ps, pfx) { @locals[:"#{pfx}#{ps[0]}"] = i if ps[0]; @sum_target = [accv, n.name] }
        if r.is_a?(Prism::RangeNode)
          counted_loop(expr(r.left), expr(r.right), r.exclude_end? ? :lt : :le, params, body, &iter)
        else
          arr = expr(recv); len = emit(:alen, [arr])
          counted_loop(const(0), len, :lt, params, body) { |i, ps, pfx| @locals[:"#{pfx}#{ps[0]}"] = emit(:aget, [arr, i]) if ps[0]; @sum_target = [accv, n.name] }
        end
        return @locals.delete(accv)
      when :each, :map, :each_with_index, :each_pair
        r = recv.is_a?(Prism::ParenthesesNode) ? recv.body.body.last : recv
        if @recv_value then return array_loop(@recv_value, n.name == :each_pair ? :each : n.name, params, body) end
        if r.is_a?(Prism::RangeNode)
          lo = expr(r.left); hi = expr(r.right)
          if n.name == :map # a fresh array, filled by the body's value
            len = emit(:add, [emit(:sub, [hi, lo]), const(r.exclude_end? ? 0 : 1)])
            fill = const(0); fill.ty = :nil
            arr = emit(:anew, [len, fill])
            outv = :"rmap#{@f.blocks.size}:out"
            @locals[outv] = arr
            counted_loop(lo, hi, r.exclude_end? ? :lt : :le, params, body) do |i, ps, pfx|
              @locals[:"#{pfx}#{ps[0]}"] = i if ps[0]
              @map_target = [outv, emit(:sub, [i, lo])]
            end
            return @locals.delete(outv)
          end
          return counted_loop(lo, hi, r.exclude_end? ? :lt : :le, params, body)
        end
        if %i[each each_pair map].include?(n.name) && recv && kind_of(recv) == :hash
          return hash_each(expr(recv), params, body, n.name == :map)
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
      ivar = :"#{pfx}$i" # a name no Ruby local can have: a block local `i` must not alias the counter
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
      # the loop's own targets, taken before the body runs: a nested loop sets and clears its own
      map_target, sum_target, fold_target, select_target = @map_target, @sum_target, @fold_target, @select_target
      pred_target, group_target, partition_target, flat_target, memo_target = @pred_target, @group_target, @partition_target, @flat_target, @memo_target
      @map_target = @sum_target = @fold_target = @select_target = @pred_target = @group_target = @partition_target = @flat_target = @memo_target = nil
      if (guard = @body_guard) # hash iteration: run the body only for used slots
        @body_guard = nil
        tb, eb, mb = @f.new_block(:gthen), @f.new_block(:gelse), @f.new_block(:gmerge)
        emit(:condbr, [guard, tb, eb])
        before = @locals.dup
        @cur = tb; last = run_body(body, pfx); tend, tl = @cur, @locals; emit(:br, [mb]) unless @cur.term
        @cur = eb; @locals = before.dup; emit(:br, [mb])
        @cur = mb; @locals = merge_locals(mb, [[tend, tl], [eb, before]])
      else
        last = run_body(body, pfx)
      end
      @blk_pfx.pop
      if map_target && @locals[map_target[0]]
        outv, idx = map_target
        @locals[outv] = emit(:aset, [@locals[outv], idx, last || const(0)])
      end
      if fold_target then @locals[fold_target] = last || const(0) end # reduce: the body's value is the next acc
      if memo_target then mv, pn = memo_target; @locals[mv] = @locals[pn] if @locals[pn] end
      if pred_target # any?/all?/none?/find: fold the body's truthiness
        resv, kind, el, idx = pred_target
        truthy = emit(:cmp, [last || const(0), const(0)], :ne)
        case kind
        when :all? then @locals[resv] = emit(:and, [@locals[resv], truthy])
        when :any?, :none? then @locals[resv] = emit(:or, [@locals[resv], truthy])
        when :find, :detect, :find_index # first hit wins: keep the earlier value once set
          tb, eb, mb = @f.new_block(:fthen), @f.new_block(:felse), @f.new_block(:fmerge)
          found = kind == :find_index ? emit(:cmp, [@locals[resv], const(-1)], :ne) : emit(:cmp, [@locals[resv], const(0)], :ne)
          take = emit(:and, [truthy, emit(:cmp, [found, const(0)], :eq)])
          before = @locals.dup
          emit(:condbr, [take, tb, eb])
          @cur = tb; @locals[resv] = kind == :find_index ? idx : el; tl = @locals; tend = @cur; emit(:br, [mb])
          @cur = eb; @locals = before.dup; emit(:br, [mb])
          @cur = mb; @locals = merge_locals(mb, [[tend, tl], [eb, before]])
        end
      end
      if group_target # group_by: h[key] ||= []; h[key] << el
        hv, el = group_target
        key = last || const(0)
        has = emit(:hkey, [@locals[hv], key])
        tb, eb, mb = @f.new_block(:gthen), @f.new_block(:gelse), @f.new_block(:gmerge)
        before = @locals.dup
        emit(:condbr, [has, tb, eb])
        @cur = tb; bucket = emit(:idx, [@locals[hv], key]); b1 = emit(:aset, [bucket, emit(:alen, [bucket]), el]); @locals[hv] = emit(:idx_set, [@locals[hv], key, b1]); tl = @locals; tend = @cur; emit(:br, [mb])
        @cur = eb; @locals = before.dup
        fresh = emit(:anew, [const(0), (c = const(0); c.ty = :nil; c)]); fresh = emit(:aset, [fresh, const(0), el]); @locals[hv] = emit(:idx_set, [@locals[hv], key, fresh]); el2 = @locals; eend = @cur; emit(:br, [mb])
        @cur = mb; @locals = merge_locals(mb, [[tend, tl], [eend, el2]])
      end
      if partition_target
        yes, no, el = partition_target
        truthy = emit(:cmp, [last || const(0), const(0)], :ne)
        tb, eb, mb = @f.new_block(:pthen), @f.new_block(:pelse), @f.new_block(:pmerge)
        before = @locals.dup
        emit(:condbr, [truthy, tb, eb])
        @cur = tb; @locals[yes] = emit(:aset, [@locals[yes], emit(:alen, [@locals[yes]]), el]); tl = @locals; tend = @cur; emit(:br, [mb])
        @cur = eb; @locals = before.dup; @locals[no] = emit(:aset, [@locals[no], emit(:alen, [@locals[no]]), el]); el2 = @locals; eend = @cur; emit(:br, [mb])
        @cur = mb; @locals = merge_locals(mb, [[tend, tl], [eend, el2]])
      end
      if flat_target # flat_map: append each element of the body's array
        inner = last || const(0)
        iv = :"fmi#{@f.blocks.size}:i"
        n_ = emit(:alen, [inner])
        counted_loop(const(0), n_, :lt, [], []) { |j, _ps, _pfx| @locals[flat_target] = emit(:aset, [@locals[flat_target], emit(:alen, [@locals[flat_target]]), emit(:aget, [inner, j])]) }
      end
      if select_target # select { }: push the element when the body is truthy
        outv, el, invert = select_target
        tb, eb, mb = @f.new_block(:sthen), @f.new_block(:selse), @f.new_block(:smerge)
        cond = last || const(0)
        cond = emit(:cmp, [cond, const(0)], :eq) if invert
        before = @locals.dup
        emit(:condbr, [cond, tb, eb])
        @cur = tb; @locals[outv] = emit(:aset, [@locals[outv], emit(:alen, [@locals[outv]]), el]); tl = @locals; tend = @cur; emit(:br, [mb])
        @cur = eb; @locals = before.dup; emit(:br, [mb])
        @cur = mb; @locals = merge_locals(mb, [[tend, tl], [eb, before]])
      end
      if sum_target # sum { } adds the body's value; count { } adds 1 when it is truthy
        accv, kind = sum_target
        v = last || const(0)
        v = emit(:and, [emit(:cmp, [v, const(0)], :ne), const(1)]) if kind == :count
        @locals[accv] = emit(:add, [@locals[accv], v])
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

    # h.each { |k, v| }: the i-th inserted entry, for i < count (Ruby's insertion order)
    def hash_each(h, params, body, map = false)
      cap = emit(:hcap, [h])
      outv = :"hmap#{@f.blocks.size}:out"
      @locals[outv] = emit(:anew, [cap, (c = const(0); c.ty = :nil; c)]) if map
      counted_loop(const(0), cap, :lt, [], body) do |i, _ps, pfx|
        key = emit(:hkey_at, [h, i]); val = emit(:hval_at, [h, i])
        @locals[:"#{pfx}#{params[0]}"] = key if params[0]
        @locals[:"#{pfx}#{params[1]}"] = val if params[1]
        @map_target = [outv, i] if map
      end
      map ? @locals.delete(outv) : const(0)
    end

    # a hash as an array of [key, value] pairs (Ruby's to_a / sort_by / each over pairs)
    def hash_pairs(h)
      cap = emit(:hcap, [h])
      outv = :"pairs#{@f.blocks.size}:out"
      @locals[outv] = emit(:anew, [cap, (c = const(0); c.ty = :nil; c)])
      counted_loop(const(0), cap, :lt, [], []) do |i, _ps, _pfx|
        pair = emit(:anew, [const(2), (c = const(0); c.ty = :nil; c)])
        pair = emit(:aset, [pair, const(0), emit(:hkey_at, [h, i])])
        pair = emit(:aset, [pair, const(1), emit(:hval_at, [h, i])])
        @locals[outv] = emit(:aset, [@locals[outv], i, pair])
      end
      @locals.delete(outv)
    end

    # printf with a literal format: %d %s %f and literal text, as a chain of prints
    def printf_lower(fmt, vals)
      parts = fmt.split(/(%[-0-9.]*[dsf]|%%)/)
      vi = 0
      parts.each do |part|
        next if part.empty?
        if part == "%%" then emit(:print_v, [emit(:sconst, ["%"])])
        elsif part.start_with?("%") then emit(:print_v, [vals[vi]]); vi += 1
        else emit(:print_v, [emit(:sconst, [part])]) end
      end
      const(0)
    end

    def array_loop(arr, kind, params, body)
      len = emit(:alen, [arr])
      out = (emit(:anew, [len, (c = const(0); c.ty = :nil; c)])) if kind == :map
      outv = :"map#{@f.blocks.size}:out"
      @locals[outv] = out if out
      counted_loop(const(0), len, :lt, params, body) do |i, ps, pfx|
        el = emit(:aget, [arr, i])
        if ps.size >= 2 && kind != :each_with_index # |k, v| over pairs: destructure the element
          ps.each_with_index { |pn, k| @locals[:"#{pfx}#{pn}"] = emit(:idx, [el, const(k)]) }
        else
          @locals[:"#{pfx}#{ps[0]}"] = el if ps[0]
        end
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
      last = run_body(body, bpfx)
      @blk_pfx.pop
      @locals.delete_if { |k, _| k.to_s.start_with?(bpfx.to_s) }
      @name_pfx, @ret_exit = saved_pfx, saved_ret
      last || const(0)
    end

    def if_expr(n, negate: false)
      tb, eb, mb = @f.new_block(:then), @f.new_block(:else), @f.new_block(:merge)
      negate ? cond_branch(n.predicate, eb, tb) : cond_branch(n.predicate, tb, eb)
      before = @locals.dup
      tfacts, efacts = facts(n.predicate, !negate), facts(n.predicate, negate)

      @cur = tb; narrow(tfacts)
      tv = (n.statements&.body || []).map { expr(_1) }.last || const(0)
      unnarrow(tfacts, before)
      tend, tlocals = @cur, @locals; emit(:br, [mb]) unless @cur.term

      @cur = eb; @locals = before.dup; narrow(efacts)
      sub = n.is_a?(Prism::UnlessNode) ? n.else_clause : n.subsequent
      ev = case sub
           when Prism::IfNode then if_expr(sub)
           when Prism::ElseNode then sub.statements&.body&.map { expr(_1) }&.last
           end || const(0)
      unnarrow(efacts, before)
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
        arm_facts = [] # `when Klass` with a local subject: the arm sees the local as a Klass
        if w.conditions.size == 1 && n.predicate.is_a?(Prism::LocalVariableReadNode) && class_const?(w.conditions[0])
          arm_facts = [[lname(n.predicate.name), w.conditions[0].name]]
        end
        [w.conditions.map { |c| when_test(subj, c) }, w.statements&.body || [], arm_facts]
      end
      lower_chain(tests, n.else_clause&.statements&.body || [])
    end

    def class_const?(c) = c.is_a?(Prism::ConstantReadNode) && (@classes[c.name] || %i[Integer Float String Array Hash Symbol].include?(c.name))

    def when_test(subj, c)
      return ->() { expr(c) } unless subj
      return ->() { emit(:isa, [subj, c.name]) } if class_const?(c) # `when Klass` is Klass === subj
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
      (conds, body, arm_facts), *rest = tests
      arm_facts ||= []
      tb, eb, mb = @f.new_block(:then), @f.new_block(:else), @f.new_block(:merge)
      # any of the conditions
      conds.each_with_index do |t, k|
        v = t.call
        nxt = k == conds.size - 1 ? eb : @f.new_block(:or)
        emit(:condbr, [v, tb, nxt]); @cur = nxt
      end
      before = @locals.dup
      @cur = tb; narrow(arm_facts); tv = body.map { expr(_1) }.last || const(0); unnarrow(arm_facts, before)
      tend, tl = @cur, @locals; emit(:br, [mb]) unless @cur.term
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
    # A lambda literal is an anonymous class: the locals it captures are its ivars (copied at
    # the moment of capture), its body is `call`. Dispatch, GC and escape analysis then treat
    # it like any object. The body is lowered after the enclosing function (deferred_lambdas).
    def lambda_value(n)
      params = n.parameters&.parameters&.requireds&.map(&:name) || []
      captured = free_locals(n.body, params).select { |nm| @locals.key?(lname(nm)) }
      raise "a lambda inside a method cannot yet refer to self or @ivars" if @klass && refers_to_self?(n.body)
      closure_value(params, captured, n.body&.body || [])
    end

    def closure_value(params, captured, stmts)
      @lambda_count = (@lambda_count || 0) + 1
      k = @classes[:"__lambda#{@lambda_count}"] = Klass.new(:"__lambda#{@lambda_count}")
      k.id = @classes.size; k.closure = true
      captured.each { k.ivar(:"@#{_1}") }
      f = Func.new(:"#{k.name}#call", 1 + params.size); f.cls = k; k.methods[:call] = f
      (@deferred_lambdas ||= []) << [k, f, params, captured, stmts, captured.select { shared?(_1) }]
      o = emit(:onew, [k])
      captured.each { |nm| emit(:fld_set, [o, k.ivar(:"@#{nm}"), @locals.fetch(lname(nm))]) } # a shared capture stores its cell
      o
    end

    def free_locals(node, bound, out = []) = free_locals_plain(node, bound, out)

    def recv_val(recv) = @recv_value || expr(recv)

    # values as a fresh array (Types gives it the elements' join)
    def pack_values(vals)
      arr = emit(:anew, [const(vals.size), (c = const(0); c.ty = :nil; c)])
      vals.each_with_index { |v, k| arr = emit(:aset, [arr, const(k), v]) }
      arr
    end

    # `v.name` for a value with no AST: ints/strings/arrays through Types, user objects through dispatch
    def call_on_value(name, v) = emit(:mcall, [name, v])
    # Mod.m / Klass.m: a constant naming a class or module, not a value
    def const_recv?(n) = n.receiver.is_a?(Prism::ConstantReadNode) && (@classes[n.receiver.name] || @modules.include?(n.receiver.name) || @funcs.key?(:"#{n.receiver.name}.#{n.name}"))

    # the values as an array whose elements are tagged (a heterogeneous argument list)
    def dyn_array(nodes)
      arr = emit(:anew, [const(nodes.size), (c = const(0); c.ty = :nil; c)])
      arr.ty = [:arr, :dyn] # declared, so each store boxes by its own type
      nodes.each_with_index { |nd, k| arr = emit(:aset, [arr, const(k), expr(nd)]) }
      arr
    end

    # every Symbol the program names, as a String array in the global SYMBOL_NAMES, built at the top of
    # main: Symbol#to_s / inspect / puts read it. (Symbols are ids at run time.)
    def install_symbol_names(main)
      @syms ||= {}
      saved = [@f, @locals, @cur, @klass, @ct, @owner, @shared]
      @f, @cur, @locals, @klass, @ct, @owner, @shared = main, main.entry, {}, nil, {}, nil, []
      head = main.entry.insts.dup; main.entry.insts.clear
      arr = emit(:anew, [const(@syms.size + 1), emit(:sconst, [""])])
      @syms.each { |name, id| arr = emit(:aset, [arr, const(id), emit(:sconst, [name.to_s])]) }
      emit(:gset, [:SYMBOL_NAMES, arr])
      # and every class name by class id: obj.class reads it (classes are ids in the header)
      ks = @classes.values.reject(&:closure)
      carr = emit(:anew, [const((ks.map(&:id).max || 0) + 1), emit(:sconst, [""])])
      ks.each { |k| carr = emit(:aset, [carr, const(k.id), emit(:sconst, [k.name.to_s])]) }
      emit(:gset, [:CLASS_NAMES, carr])
      main.entry.insts.concat(head)
      @f, @locals, @cur, @klass, @ct, @owner, @shared = saved
    end

    def times_enum?(r) = r.is_a?(Prism::CallNode) && r.name == :times && r.block.nil? && r.arguments.nil? && r.receiver

    # (lo..hi) or n.times as an Integer array
    def range_array(r)
      if times_enum?(r) then lo = const(0); hi = expr(r.receiver); excl = true
      else lo = expr(r.left); hi = expr(r.right); excl = r.exclude_end? end
      hi = emit(:add, [hi, const(1)]) unless excl
      len = emit(:sub, [hi, lo]); arr = emit(:anew, [len, const(0)])
      outv = :"rng#{@f.blocks.size}:out"; @locals[outv] = arr
      counted_loop(const(0), len, :lt, [], []) { |i, _ps, _pfx| @locals[outv] = emit(:aset, [@locals[outv], i, emit(:add, [lo, i])]) }
      @locals.delete(outv)
    end

    # the same block call, with an already-evaluated array as receiver
    def iterate_array_value(n, args, arr)
      @recv_value = arr
      block_call(n, args)
    ensure
      @recv_value = nil
    end

    def hash_new_with_default?(v) = v.is_a?(Prism::CallNode) && v.name == :new && v.receiver.is_a?(Prism::ConstantReadNode) && v.receiver.name == :Hash && v.arguments&.arguments&.size == 1

    def hash_default_of(recv)
      case recv
      when Prism::LocalVariableReadNode then @hash_defaults&.[](lname(recv.name))
      when Prism::InstanceVariableReadNode then @hash_defaults&.[]([@klass&.name, recv.name])
      end
    end

    # h[k] on a Hash.new(default): the default on a miss. Decided with has_key? so a stored nil/0 is kept.
    def hash_read_with_default(h, key_node, recv_node)
      k = expr(key_node)
      present = emit(:hkey, [h, k])
      tb, eb, mb = @f.new_block(:hthen), @f.new_block(:helse), @f.new_block(:hmerge)
      emit(:condbr, [present, tb, eb])
      @cur = tb; got = emit(:idx, [h, k]); emit(:br, [mb])
      @cur = eb; dflt = expr(hash_default_of(recv_node)); emit(:br, [mb])
      @cur = mb
      ph = mb.phi; ph.args = [[tb, got], [eb, dflt]]; ph
    end

    # A local a closure captures and that is assigned after the capture (in either scope) is
    # shared, not copied: it lives in a one-word heap cell and every read and write goes
    # through it. Decided per function body by a scan before lowering.
    def shared?(name) = @shared&.include?(name)

    # lower another function in the middle of this one: every piece of per-function state
    # goes back as it was
    NESTED_STATE = %i[@f @locals @cur @klass @ct @owner @loop @blk_pfx @shared @retry @ret_exit @block_param @kinds @hash_defaults @lambdas @name_pfx @default_self @in_safe_nav @in_safe_nav_node].freeze
    def nested
      saved = NESTED_STATE.map { instance_variable_get(_1) }
      NESTED_STATE.each { instance_variable_set(_1, nil) } # the other function starts clean (lower_body sets what it needs)
      yield
    ensure
      NESTED_STATE.zip(saved) { |k, v| instance_variable_set(k, v) }
    end

    def write_shared(name, v)
      key = lname(name)
      if (cell = @locals[key]) && cell.op != :const then emit(:cell_set, [cell, v]); v
      else @locals[key] = emit(:cell_new, [v]); v end
    end

    def shared_locals(stmts)
      closures = []; collect_closures(stmts, closures)
      shared = []
      all_assigned = assigned_locals_plain(stmts)
      closures.each do |(params, body)|
        free = free_locals_plain(body, params)
        assigned_in = assigned_locals_plain(body)
        free.each { |nm| shared << nm if assigned_in.include?(nm) || all_assigned.count(nm) > 1 }
      end
      # a local assigned inside a rescued body is read by the handler as it was at the raise:
      # a cell, not a value, since the raise can come from anywhere in the body
      rescued_bodies(stmts).each { |body| shared.concat(assigned_locals_plain(body).select { all_assigned.count(_1) > 0 }) }
      shared.uniq
    end

    def rescued_bodies(node, out = [])
      case node
      when Array then node.each { rescued_bodies(_1, out) }
      when Prism::BeginNode
        out << node.statements if node.rescue_clause && node.statements
        node.compact_child_nodes.each { rescued_bodies(_1, out) }
      when Prism::Node then node.compact_child_nodes.each { rescued_bodies(_1, out) }
      end
      out
    end

    def collect_closures(nodes, out)
      Array(nodes).each do |n|
        next unless n.is_a?(Prism::Node)
        if n.is_a?(Prism::LambdaNode) then out << [n.parameters&.parameters&.requireds&.map(&:name) || [], n.body]
        elsif closure_block?(n) then out << [n.block.parameters&.parameters&.requireds&.map(&:name) || [], n.block.body]
        end
        collect_closures(n.compact_child_nodes, out)
      end
    end

    # a block that becomes a value: lambda {}, proc {}, Proc.new {}, m { } where m takes &blk
    def closure_block?(n)
      return false unless n.is_a?(Prism::CallNode) && n.block.is_a?(Prism::BlockNode)
      return true if n.receiver.nil? && %i[lambda proc].include?(n.name)
      return true if n.name == :new && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Proc
      n.receiver.nil? && (f = @funcs[n.name]) && (d = @defs_by_func[f]) && d.parameters&.block ? true : false
    end

    def free_locals_plain(node, bound, out = [])
      return out unless node.is_a?(Prism::Node)
      case node
      when Prism::LocalVariableReadNode, Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode
        out << node.name unless bound.include?(node.name) || out.include?(node.name)
      end
      node.compact_child_nodes.each { free_locals_plain(_1, bound, out) }
      out
    end

    def has_node?(node, klass)
      return false unless node.is_a?(Prism::Node)
      return true if node.is_a?(klass)
      node.compact_child_nodes.any? { has_node?(_1, klass) }
    end

    def assigned_locals_plain(node, out = [])
      return (node.each { assigned_locals_plain(_1, out) }; out) if node.is_a?(Array)
      return out unless node.is_a?(Prism::Node)
      out << node.name if node.is_a?(Prism::LocalVariableWriteNode) || node.is_a?(Prism::LocalVariableOperatorWriteNode) || node.is_a?(Prism::LocalVariableOrWriteNode)
      node.compact_child_nodes.each { assigned_locals_plain(_1, out) }
      out
    end

    def refers_to_self?(node)
      return false unless node.is_a?(Prism::Node)
      return true if node.is_a?(Prism::SelfNode) || node.is_a?(Prism::InstanceVariableReadNode) || node.is_a?(Prism::InstanceVariableWriteNode)
      return true if node.is_a?(Prism::CallNode) && node.receiver.nil? && @klass.find_method(node.name)
      node.compact_child_nodes.any? { refers_to_self?(_1) }
    end

    # m(args, &b): a def with &blk takes b as its last argument; a yielder gets a variant with
    # a block parameter; a builtin iterator calls b per element
    def block_arg_call(n, args, bv)
      if n.receiver.nil? && (f = @funcs[n.name]) && (d = @defs_by_func[f]) && d.parameters&.block
        return emit(:call, [f, *call_args(f, args), bv])
      end
      if n.receiver.nil? && (y = @yielders[n.name])
        return emit(:call, [yield_variant(n.name, y[1]), *args.map { expr(_1) }, bv])
      end
      if %i[each map select reject].include?(n.name) && n.receiver # arr.each(&b)
        pn = :__e
        return array_loop(expr(n.receiver), n.name, [pn], ->(pfx) { emit(:mcall, [:call, bv, @locals.fetch(:"#{pfx}#{pn}")]) })
      end
      raise "block argument to #{n.name}: not supported"
    end

    # a yielder called with a block value: compiled once more with the block as a parameter
    def yield_variant(name, d)
      @funcs[:"#{name}$blk"] ||= begin
        f = Func.new(:"#{name}$blk", def_param_names(d).size + 1)
        @defs_by_func[f] = d
        (@deferred_variants ||= []) << [f, def_param_names(d) + [:__blk], d.body&.body || []]
        f
      end
    end

    # the body of each lambda: a method of its class, captures read from self first
    def lower_deferred_lambdas
      loop do
        if (job = @deferred_lambdas&.shift)
          k, f, params, captured, stmts, shared = job
          lower_body(f, [:self, *params], stmts, k, {}, captured, shared)
        elsif (job = @deferred_variants&.shift)
          f, names, stmts = job
          lower_body(f, names, stmts)
        else break end
      end
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

    MATH_CONSTS = { PI: Math::PI, E: Math::E }.freeze
    def expr_const_path(n)
      # Mod::NAME -> the constant; Mod::Klass handled by callers (Klass.new)
      return fconst(MATH_CONSTS.fetch(n.name)) if n.parent.is_a?(Prism::ConstantReadNode) && n.parent.name == :Math
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

    # p of one value: arrays are inspected element by element, everything else by type
    def p_one(a)
      if kind_of(a) == :array then emit(:puts_str, [inspect_str(a)])
      else emit(:p_v, [expr(a)]) end       # inspect form: strings quoted, nil as "nil"
    end

    # the string Array#inspect builds: "[" + elements.inspect.join(", ") + "]"
    def inspect_str(a)
      if kind_of(a) == :array
          arr = expr(a)
        outv = :"insp#{@f.blocks.size}:out"
        @locals[outv] = emit(:sconst, ["["])
        len = emit(:alen, [arr])
        counted_loop(const(0), len, :lt, [], []) do |i, _ps, _pfx|
          # out = out + (i > 0 ? ", " : "") + inspect(arr[i])
          sep = emit(:sconst, [", "]); none = emit(:sconst, [""])
          tb, eb, mb = @f.new_block(:ithen), @f.new_block(:ielse), @f.new_block(:imerge)
          emit(:condbr, [emit(:cmp, [i, const(0)], :gt), tb, eb])
          @cur = tb; emit(:br, [mb])
          @cur = eb; emit(:br, [mb])
          @cur = mb
          ph = mb.phi; ph.args = [[tb, sep], [eb, none]]
          el = emit(:aget, [arr, i])
          @locals[outv] = emit(:scat, [emit(:scat, [@locals[outv], ph]), emit(:inspect_v, [el])])
      end
        emit(:scat, [@locals.delete(outv), emit(:sconst, ["]"])])
      else
        emit(:inspect_v, [expr(a)])
      end
    end

    # a loop body: statements, or a Proc given the block prefix (a block passed as a value)
    def run_body(body, pfx)
      return body.call(pfx) if body.is_a?(Proc)
      last = nil; body.each { last = expr(_1) }; last
    end

    def assigned_ivars(node, out = [])
      return out unless node.is_a?(Prism::Node)
      case node
      when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableTargetNode
        out << node.name unless out.include?(node.name)
      when Prism::CallNode
        if node.receiver.nil? && %i[attr_accessor attr_reader attr_writer].include?(node.name)
          node.arguments&.arguments&.each { |a| out << :"@#{a.unescaped}" if a.is_a?(Prism::SymbolNode) && !out.include?(:"@#{a.unescaped}") }
        end
      end
      node.compact_child_nodes.each { assigned_ivars(_1, out) }
      out
    end

    # locals a loop body assigns exist (as nil) before the loop in Ruby: `while ..; result = f; end; result`
    def assigned_locals(node, out = [])
      return out unless node.is_a?(Prism::Node)
      out << lname(node.name) if node.is_a?(Prism::LocalVariableWriteNode) || node.is_a?(Prism::LocalVariableOperatorWriteNode)
      node.compact_child_nodes.each { assigned_locals(_1, out) } unless node.is_a?(Prism::BlockNode)
      out
    end

    def while_stmt(n, negate: false)
      hb, bb, xb = @f.new_block(:head), @f.new_block(:body), @f.new_block(:exit)
      xb.cold = true
      assigned_locals(n.statements).uniq.each { |nm| @locals[nm] ||= (c = const(0); c.ty = :nil; c) }
      pre = @cur
      emit(:br, [hb])
      phis = @locals.to_h { |nm, v| ph = hb.phi; ph.args << [pre, v]; [nm, ph] }
      @locals = phis.dup
      @cur = hb
      negate ? cond_branch(n.predicate, xb, bb) : cond_branch(n.predicate, bb, xb)
      outer, @loop = @loop, { exit: xb, breaks: [], head: hb, nexts: [] }
      @cur = bb
      bfacts = facts(n.predicate, !negate); head_locals = @locals.dup; narrow(bfacts) # the body runs only when the condition held
      (n.statements&.body || []).each { expr(_1) }
      unnarrow(bfacts, head_locals)
      bend = @cur
      emit(:br, [hb]) unless @cur.term
      phis.each { |nm, ph| ph.args << [bend, @locals[nm]] unless @cur.name.to_s.start_with?("dead") && bend.succs.empty? }
      @loop[:nexts].each { |(b, l)| phis.each { |nm, ph| ph.args << [b, l.fetch(nm)] } } # `next` sites also reach the header
      breaks = @loop[:breaks]; @loop = outer
      @cur = xb
      # exit sees the header's values, or a break site's
      @locals = breaks.empty? ? phis.dup : merge_locals(xb, [[hb, phis.dup], *breaks])
      const(0)
    end
  end
end
