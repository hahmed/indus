# Prism AST -> SSA. Locals are a name->value map per program point.
module Indus
  # Locals are a name->value map per program point. `while` makes a phi per
  # live local at the header; `if` makes a phi per local that differs at the
  # merge. Trivial phis are removed afterwards.
  class Lower
    CMP = { :== => :eq, :!= => :ne, :< => :lt, :<= => :le, :> => :gt, :>= => :ge }
    BUILTIN_CLASS_NODE = { int: [Prism::IntegerNode], float: [Prism::FloatNode], str: [Prism::StringNode, Prism::InterpolatedStringNode], array: [Prism::ArrayNode], hash: [Prism::HashNode],
                           range: [Prism::RangeNode], sym: [Prism::SymbolNode], bool: [Prism::TrueNode, Prism::FalseNode], nil: [Prism::NilNode] }.freeze
    ARITH = { :+ => :add, :- => :sub, :* => :mul, :/ => :div, :% => :mod, :& => :and, :| => :or, :^ => :xor, :<< => :shl, :>> => :shr }

    attr_reader :classes, :syms, :funcs
    attr_reader :user_family_defs # `class String; def dup ... end` bodies, as __str_dup etc.
    # a prelude function's trailing optional parameters: their literal default values (Integer / nil),
    # so a routed call with fewer arguments can be completed at the type level
    def optional_defaults(f)
      d = @defs_by_func[f] or return []
      (d.parameters&.optionals || []).map { |o| o.value.is_a?(Prism::IntegerNode) ? o.value.value : o.value.is_a?(Prism::NilNode) ? nil : :unsupported }
    end
    def required_count(f) = (d = @defs_by_func[f]) ? (d.parameters&.requireds&.size || 0) : f.params.size
    # symbols are small integers, interned at compile time
    def sym_id(name) = (@syms ||= {})[name.to_sym] ||= @syms.size + 1

    def initialize(src) = (@ast, @funcs, @classes, @consts = Lower.normalize(Prism.parse(src).value), {}, {}, {})

    # `def m ... rescue ... end` is a def whose body is a begin: give it the statements body
    # every def site expects, so one shape reaches the lowering
    # a method body lifted out of a builtin's class: `self` is the parameter, a bare call is a call on it
    # reads of the given locals become constant reads (an anonymous module/class held in a local)
    def self.rename_locals(node, names)
      return node.map { rename_locals(_1, names) } if node.is_a?(Array)
      return node unless node.is_a?(Prism::Node)
      return node if node.is_a?(Prism::DefNode) || node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) # a top-level local is not visible in a def / class body
      return Prism::ConstantReadNode.new(node.send(:source), 0, node.location, 0, names[node.name]) if node.is_a?(Prism::LocalVariableReadNode) && names.key?(node.name)
      fields = node.class.instance_method(:initialize).parameters.map(&:last) - %i[source node_id location flags]
      changed = false
      vals = fields.map do |fl|
        next nil unless node.respond_to?(fl)
        v = node.public_send(fl); nv = rename_locals(v, names)
        changed ||= !nv.equal?(v); [fl, nv]
      end.compact
      changed ? node.copy(**vals.to_h) : node
    end

    def self.onto_receiver(node, d, pname)
      return node.map { onto_receiver(_1, d, pname) } if node.is_a?(Array)
      return node unless node.is_a?(Prism::Node)
      src = node.send(:source); loc = node.location
      return Prism::LocalVariableReadNode.new(src, 0, loc, 0, pname, 0) if node.is_a?(Prism::SelfNode)
      if node.is_a?(Prism::CallNode) && node.receiver.nil? && !node.name.to_s.end_with?("=") && !%i[puts p print raise require loop lambda proc format sprintf rand block_given? yield].include?(node.name) && !d.locals.include?(node.name) && !(d.parameters && (d.parameters.requireds.map(&:name) + d.parameters.optionals.map(&:name)).include?(node.name))
        node = node.copy(receiver: Prism::LocalVariableReadNode.new(src, 0, loc, 0, pname, 0))
      end
      fields = node.class.instance_method(:initialize).parameters.map(&:last).reject { %i[source node_id location flags].include?(_1) }
      changes = {}
      fields.each do |fl|
        next unless node.respond_to?(fl)
        v = node.public_send(fl); nv = onto_receiver(v, d, pname)
        changes[fl] = nv unless nv.equal?(v) || v.is_a?(Array) && nv == v
      end
      changes.empty? ? node : node.copy(**changes)
    end

    def self.normalize(node)
      return node.map { normalize(_1) } if node.is_a?(Array)
      return node unless node.is_a?(Prism::Node)
      if (node.is_a?(Prism::DefNode) || node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)) && node.body.is_a?(Prism::BeginNode)
        node = node.copy(body: Prism::StatementsNode.new(node.send(:source), 0, node.body.location, 0, [node.body])) # `do ... rescue ... end`: a statements body holding the begin
      end
      # `{ it + 1 }` and `{ _1 * _2 }`: ordinary blocks with parameters named it / _1.._n
      if node.is_a?(Prism::BlockNode) && (node.parameters.is_a?(Prism::ItParametersNode) || node.parameters.is_a?(Prism::NumberedParametersNode))
        src = node.send(:source); loc = node.location
        names = node.parameters.is_a?(Prism::ItParametersNode) ? [:it] : (1..node.parameters.maximum).map { :"_#{_1}" }
        reqs = names.map { Prism::RequiredParameterNode.new(src, 0, loc, 0, _1) }
        params = Prism::ParametersNode.new(src, 0, loc, 0, reqs, [], nil, [], [], nil, nil)
        node = node.copy(parameters: Prism::BlockParametersNode.new(src, 0, loc, 0, params, [], nil, nil))
      end
      return Prism::LocalVariableReadNode.new(node.send(:source), 0, node.location, 0, :it, 0) if node.is_a?(Prism::ItLocalVariableReadNode)
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
      # A = Class.new(Base) { ... } / A = Module.new { } at the top level: the same as `class A < Base ... end`.
      # mod = Module.new { } in a local likewise: an anonymous module named after the local (`__anon_mod`), and
      # every later read of that local as a module/class argument (include, extend, prepend, raise, <) is the constant
      anon_locals = {}
      # k = Object.const_get(:Array) / const_get("Name") in a local: the local is that constant
      body.each do |st|
        next unless st.is_a?(Prism::LocalVariableWriteNode) && (v = st.value).is_a?(Prism::CallNode) && v.name == :const_get && v.receiver.is_a?(Prism::ConstantReadNode) && v.receiver.name == :Object && (a = v.arguments&.arguments&.first) && (a.is_a?(Prism::SymbolNode) || a.is_a?(Prism::StringNode))
        anon_locals[st.name] = a.unescaped.to_sym
      end
      body = body.reject { |st| st.is_a?(Prism::LocalVariableWriteNode) && anon_locals.key?(st.name) && st.value.is_a?(Prism::CallNode) && st.value.name == :const_get }
      # s = Struct.new(:a) { } / Data.define(:a) in a local: the struct class under a hidden constant
      body = body.map do |st|
        next st unless st.is_a?(Prism::LocalVariableWriteNode) && struct_new?(st.value)
        cname = anon_locals[st.name] = :"__anon_#{st.name}"
        Prism::ConstantWriteNode.new(st.send(:source), 0, st.location, 0, cname, st.location, st.value, st.location)
      end
      body = body.map do |st|
        is_anon = st.value.is_a?(Prism::CallNode) && st.value.name == :new && st.value.receiver.is_a?(Prism::ConstantReadNode) && %i[Class Module].include?(st.value.receiver.name) && st.value.block.is_a?(Prism::BlockNode) if st.is_a?(Prism::ConstantWriteNode) || st.is_a?(Prism::LocalVariableWriteNode)
        next st unless is_anon
        cname = st.is_a?(Prism::ConstantWriteNode) ? st.name : (anon_locals[st.name] = :"__anon_#{st.name}")
        v = st.value; src = st.send(:source); loc = st.location
        path = Prism::ConstantReadNode.new(src, 0, loc, 0, cname)
        if v.receiver.name == :Module
          Prism::ModuleNode.new(src, 0, loc, 0, [], loc, path, v.block.body, loc, cname)
        else
          sup = v.arguments&.arguments&.first
          Prism::ClassNode.new(src, 0, loc, 0, [], loc, path, sup && loc, sup, v.block.body, loc, cname)
        end
      end
      unless anon_locals.empty?
        body = Lower.rename_locals(body, anon_locals)
        @ast = @ast.copy(statements: @ast.statements.copy(body: body)) # the pre-typing and every later walk see the constants
      end
      # X.include(Module.new { }) / obj.extend(Module.new { }): the anonymous module gets a name and a declaration
      anon_n = 0
      body = body.flat_map do |st|
        next [st] unless st.is_a?(Prism::CallNode) && %i[include prepend extend].include?(st.name) && (a = st.arguments&.arguments) && a.size == 1 && a[0].is_a?(Prism::CallNode) && a[0].name == :new && a[0].receiver.is_a?(Prism::ConstantReadNode) && a[0].receiver.name == :Module && a[0].block.is_a?(Prism::BlockNode)
        src = st.send(:source); loc = st.location; cname = :"__anon_mod#{anon_n += 1}"
        path = Prism::ConstantReadNode.new(src, 0, loc, 0, cname)
        [Prism::ModuleNode.new(src, 0, loc, 0, [], loc, path, a[0].block.body, loc, cname), st.copy(arguments: st.arguments.copy(arguments: [path]))]
      end
      # modules are namespaces: hoist their classes and constants to the top level
      mods = body.grep(Prism::ModuleNode)
      # modules nested in modules (module Tr; module CM; end; end) are hoisted: the inner name resolves on its own
      nested_mods = []
      walk_mods = ->(m) { (m.body&.body || []).grep(Prism::ModuleNode).each { |inner| nested_mods << inner; walk_mods.(inner) } }
      mods.each { walk_mods.(_1) }
      mods += nested_mods
      # a module's instance methods: `include M` in a class body compiles them as that class's own
      # (one copy per including class -- typed for that class, like everything else here)
      @module_defs = mods.to_h { |m| [m.constant_path.name, (m.body&.body || []).grep(Prism::DefNode).reject { _1.receiver.is_a?(Prism::SelfNode) }] }
      mod_classes = mods.flat_map { |m| (m.body&.body || []).grep(Prism::ClassNode) }
      mod_consts = mods.flat_map { |m| (m.body&.body || []).grep(Prism::ConstantWriteNode) }
      defs = body.grep(Prism::DefNode).reject { _1.receiver && !_1.receiver.is_a?(Prism::SelfNode) } # def x.m stays a statement (a singleton site)
      # top-level define_method(:name) { |params| body } with a literal symbol and block: a def
      dm = body.select { |st| st.is_a?(Prism::CallNode) && st.name == :define_method && st.receiver.nil? && st.block.is_a?(Prism::BlockNode) && st.arguments&.arguments&.first.is_a?(Prism::SymbolNode) }
      body = body - dm
      cdefs = body.grep(Prism::ClassNode) + mod_classes
      # classes nested in class bodies (class Outer; class Inner; end; end) are hoisted like module-nested ones;
      # Outer::Inner resolves by the inner name. Declared after their outer class so a superclass reference works.
      nested = []
      walk = ->(c) { (c.body&.body || []).grep(Prism::ClassNode).each { |inner| nested << inner; walk.(inner) } }
      cdefs.each { walk.(_1) }
      cdefs += nested
      # `A.include(M)` / `A.prepend(M)` / `A.extend(M)` as a top-level statement: the same as inside A's body (a re-opening)
      body = body.flat_map do |st|
        # A.send(:remove_method, :m) is A.remove_method(:m)
        st = st.copy(name: st.arguments.arguments[0].unescaped.to_sym, arguments: st.arguments.copy(arguments: st.arguments.arguments[1..])) if st.is_a?(Prism::CallNode) && %i[send public_send __send__].include?(st.name) && st.receiver.is_a?(Prism::ConstantReadNode) && st.arguments&.arguments&.first.is_a?(Prism::SymbolNode) && cdefs.any? { _1.constant_path.name == st.receiver.name }
        # X.class_eval { undef_method :m; attr_accessor :z; include M } at the top level with only class-body statements (no defs: those are versions): a re-opening
        if st.is_a?(Prism::CallNode) && %i[class_eval class_exec].include?(st.name) && st.receiver.is_a?(Prism::ConstantReadNode) && st.block.is_a?(Prism::BlockNode) && st.arguments.nil? && cdefs.any? { _1.constant_path.name == st.receiver.name } && (st.block.body&.body || []).all? { |b| b.is_a?(Prism::CallNode) && b.receiver.nil? && %i[undef_method remove_method alias_method attr_accessor attr_reader attr_writer include extend prepend private public protected].include?(b.name) }
          src = st.send(:source); loc = st.location
          next [Prism::ClassNode.new(src, 0, loc, 0, [], loc, st.receiver, nil, nil, st.block.body, loc, st.receiver.name)]
        end
        mixin = st.is_a?(Prism::CallNode) && %i[include prepend extend].include?(st.name) && st.arguments&.arguments&.all? { _1.is_a?(Prism::ConstantReadNode) }
        classop = st.is_a?(Prism::CallNode) && %i[alias_method remove_method undef_method private public protected attr_accessor attr_reader attr_writer].include?(st.name) && st.arguments&.arguments&.all? { _1.is_a?(Prism::SymbolNode) || _1.is_a?(Prism::StringNode) }
        next [st] unless st.is_a?(Prism::CallNode) && (mixin || classop) && st.receiver.is_a?(Prism::ConstantReadNode) && cdefs.any? { _1.constant_path.name == st.receiver.name }
        src = st.send(:source); loc = st.location
        inner = st.copy(receiver: nil)
        [Prism::ClassNode.new(src, 0, loc, 0, [], loc, st.receiver, nil, nil, Prism::StatementsNode.new(src, 0, loc, 0, [inner]), loc, st.receiver.name)]
      end
      cdefs = body.grep(Prism::ClassNode) + mod_classes + nested
      # a class opened several times (class A; ...; end ... class A; ...; end) is one class: the bodies
      # concatenated in order, the superclass from whichever body names it. (Whole program: every body is known.)
      by_name = {}
      @redefine_markers = {} # a later re-opening's ClassNode -> [class, [method names it redefines]]: a slot write at its program position
      cdefs = cdefs.each_with_object([]) do |c, out|
        nm = c.constant_path.name
        if (first = by_name[nm])
          earlier = (first.body&.body || []).grep(Prism::DefNode).reject { _1.receiver }.map(&:name)
          redefs = (c.body&.body || []).grep(Prism::DefNode).reject { _1.receiver }.map(&:name) & earlier
          @redefine_markers[c] = [nm, redefs] unless redefs.empty?
          merged_body = (first.body&.body || []) + (c.body&.body || [])
          src = first.send(:source); loc = first.location
          merged = first.copy(body: Prism::StatementsNode.new(src, 0, loc, 0, merged_body), superclass: first.superclass || c.superclass)
          out[out.index(first)] = merged; by_name[nm] = merged
        else
          by_name[nm] = c; out << c
        end
      end
      @reopened = by_name.keys.select { |nm| body.grep(Prism::ClassNode).count { _1.constant_path.name == nm } > 1 }
      # reopening a builtin (class String; def shout = upcase + "!"; end): each def becomes a family
      # function __str_shout(self__, ...) with self and bare calls rewritten onto the receiver; the
      # call `"hi".shout` then routes like any String method
      builtin_fams = { String: "str", Integer: "num", Float: "num", Numeric: "num", Array: "arr", Hash: "hash" }
      cdefs, builtin_bodies = cdefs.partition { !builtin_fams.key?(_1.constant_path.name) }
      builtin_bodies.each do |c|
        fam = builtin_fams[c.constant_path.name]
        (c.body&.body || []).each do |st|
          raise "class #{c.constant_path.name}: only `def` is supported in a reopened builtin (got #{st.class})" unless st.is_a?(Prism::DefNode) && st.receiver.nil?
          src = st.send(:source); loc = st.location
          selfp = Prism::RequiredParameterNode.new(src, 0, loc, 0, :self__)
          ps = st.parameters || Prism::ParametersNode.new(src, 0, loc, 0, [], [], nil, [], [], nil, nil)
          ps = ps.copy(requireds: [selfp] + ps.requireds)
          body_ = Lower.onto_receiver(st.body, st, :self__)
          defs_extra = Prism::DefNode.new(src, 0, loc, 0, :"__#{fam}_#{st.name.to_s.sub('?', '_p').sub('!', '_bang')}", loc, nil, ps, body_, [:self__] + st.locals, loc, nil, nil, nil, nil, nil)
          body << defs_extra; defs << defs_extra
          (@user_family_defs ||= []) << defs_extra.name # user code under a library name: the aliasing checks treat it as user code
        end
      end
      mod_ivars = (mods + cdefs).flat_map { |m| (m.body&.body || []).grep(Prism::InstanceVariableWriteNode).map { [m.constant_path.name, _1] } } # `@x = v` in a module or class body: the class object's own ivar, set before the program runs
      # `def self.m` in a class or module body: a function named Owner.m, no self
      @modules = mods.map { _1.constant_path.name }
      sdefs = (cdefs + mods).flat_map { |c| (c.body&.body || []).grep(Prism::DefNode).select { _1.receiver.is_a?(Prism::SelfNode) }.map { [c.constant_path.name, _1] } }
      # `include M` where M's `def self.included(base)` is `base.extend(CM)` (the Concern idiom): the including class also
      # extends CM -- rewritten into its body as `extend CM` before the extend pass below
      concern_extends = {}
      mods.each do |m|
        hook = (m.body&.body || []).find { |d| d.is_a?(Prism::DefNode) && d.receiver.is_a?(Prism::SelfNode) && d.name == :included }
        next unless hook && (bp = hook.parameters&.requireds&.first)
        ext = (hook.body&.body || []).filter_map { |s| s.is_a?(Prism::CallNode) && s.name == :extend && s.receiver.is_a?(Prism::LocalVariableReadNode) && s.receiver.name == bp.name && s.arguments&.arguments&.size == 1 && s.arguments.arguments[0].is_a?(Prism::ConstantReadNode) ? s.arguments.arguments[0] : nil }
        concern_extends[m.constant_path.name] = ext unless ext.empty?
        (@structural_hooks ||= []) << hook if !ext.empty? && (hook.body.body.size == ext.size) # every statement applied structurally: the hook is not a function
      end
      unless concern_extends.empty?
        cdefs = cdefs.map do |c|
          adds = (c.body&.body || []).flat_map { |st| st.is_a?(Prism::CallNode) && st.name == :include && st.receiver.nil? && st.arguments ? st.arguments.arguments.flat_map { |a| a.is_a?(Prism::ConstantReadNode) ? (concern_extends[a.name] || []) : [] } : [] }
          next c if adds.empty?
          src = c.send(:source); loc = c.location
          extends = adds.map { |path| Prism::CallNode.new(src, 0, loc, 0, nil, nil, :extend, loc, nil, Prism::ArgumentsNode.new(src, 0, loc, 0, [path]), nil, nil, nil) }
          c.copy(body: Prism::StatementsNode.new(src, 0, loc, 0, (c.body&.body || []) + extends))
        end
      end
      # `extend M` in a class body: M's methods are class methods of that class
      (cdefs + mods).each do |c|
        (c.body&.body || []).each do |st|
          next unless st.is_a?(Prism::CallNode) && st.name == :extend && st.receiver.nil? && st.arguments
          st.arguments.arguments.each do |m|
            raise "extend #{m.class}: a module name" unless m.is_a?(Prism::ConstantReadNode)
            (@module_defs[m.name] || raise("extend #{m.name}: no such module")).each { |d| sdefs << [c.constant_path.name, d]; (@inherited_cm ||= {})[[c.constant_path.name, d.name]] = true } # extended: not the class's own
          end
        end
      end
      # class << self ... end: defs inside are class methods; attr_accessor inside reads/writes the class object's ivars
      (cdefs + mods).each do |c|
        (c.body&.body || []).grep(Prism::SingletonClassNode).each do |sc|
          raise "class << x: only self" unless sc.expression.is_a?(Prism::SelfNode)
          (sc.body&.body || []).each do |st|
            case st
            when Prism::DefNode then sdefs << [c.constant_path.name, st]
            when Prism::CallNode
              if st.name == :alias_method && st.arguments&.arguments&.size == 2 # alias_method :new, :old on the class object: a second def with the old body
                nn, on = st.arguments.arguments.map { _1.unescaped.to_sym }
                src_def = (sc.body&.body || []).grep(Prism::DefNode).find { _1.name == on } || (c.body&.body || []).grep(Prism::DefNode).find { _1.name == on && _1.receiver.is_a?(Prism::SelfNode) } or raise "alias_method #{nn}: no class method #{on}"
                sdefs << [c.constant_path.name, src_def.copy(name: nn)]; next
              end
              next if %i[private public protected private_class_method].include?(st.name)
              raise "unsupported in class << self: #{st.name}" unless %i[attr_accessor attr_reader attr_writer].include?(st.name)
              (st.arguments&.arguments || []).each do |sym|
                nm = sym.unescaped.to_sym; src = sym.send(:source); loc = sym.location
                ivar = Prism::InstanceVariableReadNode.new(src, 0, loc, 0, :"@#{nm}")
                if %i[attr_accessor attr_reader].include?(st.name)
                  sdefs << [c.constant_path.name, Prism::DefNode.new(src, 0, loc, 0, nm, loc, Prism::SelfNode.new(src, 0, loc, 0), nil, Prism::StatementsNode.new(src, 0, loc, 0, [ivar]), [], loc, nil, nil, nil, nil, nil)]
                end
                if %i[attr_accessor attr_writer].include?(st.name)
                  prm = Prism::RequiredParameterNode.new(src, 0, loc, 0, :v)
                  ps = Prism::ParametersNode.new(src, 0, loc, 0, [prm], [], nil, [], [], nil, nil)
                  w = Prism::InstanceVariableWriteNode.new(src, 0, loc, 0, :"@#{nm}", loc, Prism::LocalVariableReadNode.new(src, 0, loc, 0, :v, 0), loc)
                  sdefs << [c.constant_path.name, Prism::DefNode.new(src, 0, loc, 0, :"#{nm}=", loc, Prism::SelfNode.new(src, 0, loc, 0), ps, Prism::StatementsNode.new(src, 0, loc, 0, [w]), [:v], loc, nil, nil, nil, nil, nil)]
                end
              end
            else raise "unsupported in class << self: #{st.class}"
            end
          end
        end
      end
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
      # a class method is inherited: Q.m where only P.m exists is P's def compiled for Q (so `kind` inside
      # resolves to Q.kind and `new` to Q.new), one copy per subclass that lacks its own
      sup_of = cdefs.to_h { |c| [c.constant_path.name, c.superclass&.name] }
      cdefs.each do |c|
        anc = sup_of[c.constant_path.name]
        while anc
          sdefs.select { |(o, _)| o == anc }.each do |(_, d)|
            next if sdefs.any? { |(o, dd)| o == c.constant_path.name && dd.name == d.name }
            sdefs << [c.constant_path.name, d]; (@inherited_cm ||= {})[[c.constant_path.name, d.name]] = true
          end
          anc = sup_of[anc]
        end
      end
      # constants written inside class bodies run before everything else
      # a class's constants are its own (Base::PREFIX and Child::PREFIX are two globals, "Base::PREFIX" and
      # "Child::PREFIX"); bare X inside a class resolves lexically through the ancestors (see const_owner)
      @top_consts = body.grep(Prism::ConstantWriteNode).map(&:name) # the program's top-level constants
      @class_const_owners = Hash.new { |h, k| h[k] = [] } # const name -> classes that define it
      cdefs.each { |c| (c.body&.body || []).grep(Prism::ConstantWriteNode).each { |w| @class_const_owners[w.name] << c.constant_path.name } }
      class_consts = cdefs.flat_map { |c| (c.body&.body || []).grep(Prism::ConstantWriteNode).map { |w| w.copy(name: :"#{c.constant_path.name}::#{w.name}") } + (c.body&.body || []).grep(Prism::ClassVariableWriteNode) } # @@x = v in a class body: run first, like a constant
      # Name = Struct.new(:a, :b) defines a class with accessors and an initialize
      structs = body.select { |st| st.is_a?(Prism::ConstantWriteNode) && struct_new?(st.value) }
      @lazy = {}; @defs_by_func = {} # prelude functions (__name): lowered on first demand, see `demand`
      @def_versions = {} # DefNode (a later definition) -> [primary Func, version Func]: its site writes the slot
      defs.each do |d|
        next if yields?(d) && !d.parameters&.block # a yielder without &blk inlines at its call sites
        ps = d.parameters
        if (prev = @funcs[d.name]) && !d.name.to_s.start_with?("__") # `def f` again at the top level: a version behind f's slot
          f = Func.new(:"#{d.name}@v#{(prev.versions || []).size + 1}", def_param_names(d).size)
          f.rest = true if ps&.rest.is_a?(Prism::RestParameterNode)
          f.primary = prev; (prev.versions ||= []) << f; prev.patchable = true
          @defs_by_func[f] = d; @def_versions[d] = [prev, f]
          (@deferred_variants ||= []) << [f, def_param_names(d), d.body&.body || []]
          next
        end
        f = @funcs[d.name] = Func.new(d.name, def_param_names(d).size)
        f.rest = true if ps&.rest.is_a?(Prism::RestParameterNode)
        @defs_by_func[f] = d
        @lazy[d.name] = d if d.name.to_s.start_with?("__")
      end
      # `class B < A` where an ancestor defines `self.inherited`: the hook runs at the declaration's program position
      # (the first declaration of each class only), with the subclass's name as the class value
      seen_decl = {}
      inherited_hook = lambda do |st|
        out = []
        out << [:inherited, st.constant_path.name] if st.superclass && !seen_decl[st.constant_path.name]
        seen_decl[st.constant_path.name] = true
        # `def self.method_added(m)` in this class: called once per def in the body, in order (the class body runs at its position)
        (st.body&.body || []).each { |d| out << [:method_added, st.constant_path.name, d.name] if d.is_a?(Prism::DefNode) && !d.receiver && d.name != :method_added }
        # `def self.extended(o)` / `self.included(b)` on a module named by `extend M` / `include M` in the body
        (st.body&.body || []).each { |c| out << [:mod_hook, c.name == :extend ? :extended : :included, c.arguments.arguments[0].name, st.constant_path.name] if c.is_a?(Prism::CallNode) && %i[extend include].include?(c.name) && c.receiver.nil? && c.arguments&.arguments&.size == 1 && c.arguments.arguments[0].is_a?(Prism::ConstantReadNode) }
        out
      end
      top = (body - (defs - @def_versions.keys) - mods - structs).flat_map { |st| st.is_a?(Prism::ClassNode) ? inherited_hook.(st) + (@redefine_markers[st] ? [[:redefine, *@redefine_markers[st]]] : []) : [st] } # a re-opening that redefines methods, or a second `def f`: a slot write at its position
      top = class_consts + mod_consts + top
      @mod_ivars = mod_ivars
      # methods that take a block (contain yield) are inlined at call sites with a literal block;
      # they still get compiled as functions for block-less callers
      @yielders = {} # name -> [klass or nil, def]
      defs.each { |d| @yielders[d.name] = [nil, d] if yields?(d) && !d.parameters&.block }
      @dm_bodies = {}
      dm.each do |st|
        name = st.arguments.arguments.first.unescaped.to_sym
        params = st.block.parameters&.parameters&.requireds&.map(&:name) || []
        f = @funcs[name] = Func.new(name, params.size)
        @dm_bodies[f] = [params, st.block.body&.body || []]
      end
      sdefs.reject! { |(_, d)| @structural_hooks&.any? { _1.equal?(d) } } # a hook applied at compile time is not a function
      @sdef_nodes = Hash.new { |h, kk| h[kk] = [] }
      sdefs.each { |_, d| @sdef_nodes[d.name] << d }
      sdefs.each do |owner, d|
        ps = d.parameters
        f = @funcs[:"#{owner}.#{d.name}"] = Func.new(:"#{owner}.#{d.name}", def_param_names(d).size)
        f.rest = true if ps&.rest.is_a?(Prism::RestParameterNode)
        @defs_by_func[f] = d
      end
      methods = [] # [klass, def, func]
      @nested_defs = [] # [enclosing class name or nil, DefNode] found below the hoisted positions
      collect_nested_defs(body, nil, @nested_defs, top_level: true)
      structs.each do |st|
        k = @classes[st.name] = Klass.new(st.name)
        k.id = @classes.size
        sargs = (st.value.arguments&.arguments || []).dup
        kw = sargs.last.is_a?(Prism::KeywordHashNode) ? sargs.pop : nil
        is_data = data_define?(st.value) # Data.define: positional or keyword construction, no writers, `with`
        (@struct_kw ||= {})[k.name] = true if kw && kw.elements.any? { |e| e.key.unescaped == "keyword_init" && e.value.is_a?(Prism::TrueNode) }
        (@struct_kw_ok ||= {})[k.name] = true if is_data # keywords accepted alongside positionals
        (@data_classes ||= {})[k.name] = true if is_data
        fields = sargs.map { |a| a.unescaped.to_sym }
        (@struct_fields ||= {})[k.name] = fields
        fields.each { |f| k.ivar(:"@#{f}"); k.readers[f] = :"@#{f}"; k.writers[:"#{f}="] = :"@#{f}" unless is_data }
        init = Func.new(:"#{k.name}#initialize", 1 + fields.size)
        init.cls = k; k.methods[:initialize] = init
        # body: @a = a; @b = b ...  built as AST-free lowering below
        methods << [k, nil, init, [:self, *fields], fields.map { |f| [:struct_set, f] }, {}]
        # the Struct protocol as Ruby defs the body may override: to_a, members, to_h, ==, [], []=, each, values, size, inspect/to_s
        fl = fields.map(&:to_s)
        synth = <<~RUBY
          def to_a = [#{fl.join(", ")}]
          def values = to_a
          def deconstruct = to_a
          def members = [#{fl.map { ":#{_1}" }.join(", ")}]
          def size = #{fl.size}
          def length = #{fl.size}
          def to_h = { #{fl.map { "#{_1}: #{_1}" }.join(", ")} }
          def ==(o) = #{fl.empty? ? "true" : fl.map { "#{_1} == o.#{_1}" }.join(" && ")}
          def [](i) = i.is_a?(Integer) ? to_a[i] : to_h[i.to_sym]
          def each(&blk) = to_a.each(&blk)
          def inspect = "#<#{is_data ? "data" : "struct"} #{k.name} " + [#{fl.map { "\"#{_1}=\" + #{_1}.inspect" }.join(", ")}].join(", ") + ">"
          def to_s = inspect
        RUBY
        synth_defs = Prism.parse(synth).value.statements.body
        body_defs = st.value.block.is_a?(Prism::BlockNode) ? (st.value.block.body&.body || []) : []
        own = body_defs.grep(Prism::DefNode).map(&:name)
        # only the protocol methods the program can reach (a never-called `==` would be typed against nothing)
        text = @ast.send(:source).source
        used = ->(nm) { %i[to_s inspect].include?(nm) || text.include?(nm == :[] ? "[" : nm == :== ? "==" : nm.to_s) }
        register_class_body(k, synth_defs.reject { own.include?(_1.name) || !used.(_1.name) } + body_defs, methods) # Struct.new(...) do ... end
      end
      cdefs.each do |c|
        sup = c.superclass && @classes.fetch(c.superclass.name) { raise "superclass #{c.superclass.name} must be defined first" }
        k = @classes[c.constant_path.name] = Klass.new(c.constant_path.name, sup)
        k.id = @classes.size
        # every @ivar this class body writes, registered now: a subclass declared below copies
        # the parent's layout at declaration, before the parent's methods are lowered
        has = ->(cn) { kk = k; (return true if @class_const_owners[cn].include?(kk.name); kk = kk.superclass && @classes[kk.superclass]) while kk; false }
        readers = @class_const_owners.keys.select { has.(_1) }.map do |cn| # def __const_X = X, so self.class::X can dispatch
          src = c.send(:source); loc = c.location
          Prism::DefNode.new(src, 0, loc, 0, :"__const_#{cn}", loc, nil, nil, Prism::StatementsNode.new(src, 0, loc, 0, [Prism::ConstantReadNode.new(src, 0, loc, 0, cn)]), [], loc, nil, nil, nil, nil, nil)
        end
        register_class_body(k, (c.body&.body || []) + readers, methods)
      end
      # a class reflecting on its ivars with a name computed at run time (instance_variable_get(iv), instance_variable_set("@#{k}", v)):
      # every field is dyn-typed and the class gets a run-time name table (symbol id -> field index). Its fields: the ones its
      # bodies name, every keyword key in the program (the `**attrs` idiom), and four spare slots for anything else.
      kw_keys = all_kwarg_keys(@ast)
      cdefs.each do |c|
        k = @classes[c.constant_path.name]
        next unless reflects_ivars?(c)
        k.reflective = true
        kw_keys.each { |key| k.ivar(:"@#{key}") }
        k.reserve_spares
        k.dyn_ivars = k.ivars.dup
      end
      # nested defs (inside methods, conditionals, blocks, class_eval blocks): versions behind the method's slot
      @nested_defs.each do |owner, d|
        raise "a `def` with yield nested in #{owner || 'the top level'}: not supported (yielders are inlined)" if yields?(d) && !d.parameters&.block
        if owner
          k = @classes.fetch(owner) { raise "def #{d.name} inside unknown class #{owner}" }
          prev = k.methods[d.name]
          f = Func.new(:"#{k.name}##{d.name}#{prev ? "@v#{((prev.primary || prev).versions || []).size + 1}" : ""}", 1 + def_param_names(d).size)
          f.rest = true if d.parameters&.rest.is_a?(Prism::RestParameterNode)
          f.cls = k; @defs_by_func[f] = d
          if prev && prev.cls == k
            primary = prev.primary || prev
            f.primary = primary; (primary.versions ||= []) << f; primary.patchable = true; @def_versions[d] = [primary, f]
          else
            k.methods[d.name] = f # first definition of the method anywhere: it is the method (defined when its site runs, approximately)
          end
          methods << [k, d, f]
        else
          prev = @funcs[d.name]
          f = Func.new(prev ? :"#{d.name}@v#{(prev.versions || []).size + 1}" : d.name, def_param_names(d).size)
          f.rest = true if d.parameters&.rest.is_a?(Prism::RestParameterNode)
          @defs_by_func[f] = d
          if prev then f.primary = prev; (prev.versions ||= []) << f; prev.patchable = true; @def_versions[d] = [prev, f]
          else @funcs[d.name] = f end
          (@deferred_variants ||= []) << [f, def_param_names(d), d.body&.body || []]
        end
      end
      @pre = Pretype.new(@ast, @classes) # receiver kinds for the structural decisions below
      # a method on one object (`def x.m`, `x.extend(M)`, `x.define_singleton_method(:m) { }`): the object is
      # retagged to a hidden subclass of its class carrying that method; dispatch by class id does the rest
      @singletons = {} # node -> hidden Klass
      scan_singletons(body) do |node, recv_node, defs|
        kd = kind_of(recv_node)
        raise "a singleton method on #{recv_node.class}: the object's class must be known at compile time" unless kd.is_a?(Symbol) && @classes[kd]
        base = @classes[kd]
        # one hidden subclass per receiver expression (`x`): several singleton defs on x accumulate on it
        key = [kd, recv_node.respond_to?(:name) ? recv_node.name : recv_node.location.start_offset]
        @single_subs ||= {}
        sub = @single_subs[key] ||= begin
          @single_count = (@single_count || 0) + 1
          s = @classes[:"#{base.name}$#{@single_count}"] = Klass.new(:"#{base.name}$#{@single_count}", base); s.id = @classes.size; s
        end
        defs.each do |d|
          f = Func.new(:"#{sub.name}##{d.name}#{sub.methods[d.name] ? "@v#{(sub.methods[d.name].versions || []).size + 1}" : ""}", 1 + def_param_names(d).size)
          f.rest = true if d.parameters&.rest.is_a?(Prism::RestParameterNode)
          f.cls = sub; @defs_by_func[f] = d
          if (prev = sub.methods[d.name]) then f.primary = prev; (prev.versions ||= []) << f; prev.patchable = true; @def_versions[d] = [prev, f]
          else sub.methods[d.name] = f end
          methods << [sub, d, f]
        end
        base.tagged = true; sub.tagged = true # the class id sits in word 0 from the start
        @singletons[node] = sub
      end
      main = Func.new(:main, 0)
      lower_body(main, [], top)
      # prelude functions are lowered only when something names them (most of the prelude is
      # never used by a given program, and typing it first was half the compile)
      defs.each { |d| lower_body(@funcs[d.name], def_param_names(d), d.body&.body || []) if @funcs[d.name] && !@def_versions.key?(d) && !@lazy.key?(d.name) && !(@lowered_late || []).include?(@funcs[d.name]) } # a version lowers as its own function (deferred)
      @dm_bodies.each { |f, (params, stmts)| lower_body(f, params, stmts) }
      sdefs.each do |owner, d|
        if macro_body?(d) # a class-level macro (define_method / attr_* from a class method): unrolled at its class-body call sites, never a function
          f = @funcs.delete(:"#{owner}.#{d.name}"); @defs_by_func.delete(f); (@macro_defs ||= {})[:"#{owner}.#{d.name}"] = d
          next
        end
        @owner = owner
        lower_body(@funcs[:"#{owner}.#{d.name}"], def_param_names(d), d.body&.body || [])
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
      # a class with method_missing may receive any call's name as a Symbol: every called name is a symbol
      if @classes.each_value.any? { _1.methods.key?(:method_missing) }
        all_call_names(@ast).each { sym_id(_1.to_s) }
      end
      install_symbol_names(main)
      demand(:__gc_run) if @funcs[:__gc_run] # the collector is entered from the runtime, not by a call
      demand(:__gc_keep) if @funcs[:__gc_keep] # loop regions call it from codegen
      drain_demands
      all = [main, *@funcs.values.reject { @lazy.key?(_1.name) }, *methods.map { _1[2] }, *@classes.values.select(&:closure).map { _1.methods[:call] }, *@def_versions.values.map(&:last)].uniq
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
      # `attribute :email` in a class body, where `def self.attribute(n)` is a class method of this class or an ancestor
      # and every argument is a compile-time value: a class-level macro -- the method's body is unrolled here with its
      # parameters bound to the literals, so define_method / attr_* / instance_variable_get("@#{n}") in it resolve statically
      if st.is_a?(Prism::CallNode) && st.receiver.nil? && !%i[attr_accessor attr_reader attr_writer define_method include extend prepend each each_with_index private public protected alias_method module_function].include?(st.name) && (d = class_macro_def(k, st.name))
        args = (st.arguments&.arguments || []).dup
        kw = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
        ps = d.parameters
        reqs = ps&.requireds&.map(&:name) || []
        opts = ps&.optionals || []
        raise "#{k.name}.#{st.name}: a class-level call with #{args.size} arguments for #{reqs.size} parameters" if args.size < reqs.size || args.size > reqs.size + opts.size && !ps&.rest
        env = ct.dup
        reqs.each_with_index { |nm, ix| env[nm] = ct_value(args[ix], ct) }
        opts.each_with_index { |o, ix| env[o.name] = args[reqs.size + ix] ? ct_value(args[reqs.size + ix], ct) : ct_value(o.value, env) }
        env[ps.rest.name] = args[(reqs.size + opts.size)..].map { ct_value(_1, ct) } if ps&.rest.is_a?(Prism::RestParameterNode) && ps.rest.name
        given = (kw&.elements || []).to_h { |el| [el.key.unescaped.to_sym, el.value] }
        (ps&.keywords || []).each { |kp| env[kp.name] = given.key?(kp.name) ? ct_value(given[kp.name], ct) : (kp.respond_to?(:value) && kp.value ? ct_value(kp.value, env) : raise("#{k.name}.#{st.name}: missing keyword #{kp.name}")) }
        (@macro_depth = (@macro_depth || 0) + 1) < 8 or raise "#{k.name}.#{st.name}: class-level macros nest too deep"
        body = d.body&.body || []
        body = body.flat_map { |b| b.is_a?(Prism::ParenthesesNode) ? (b.body&.body || []) : [b] }
        body.each { |inner| class_body_call(k, inner, env, methods) }
        @macro_depth -= 1
        return
      end
      if st.is_a?(Prism::CallNode) && %i[send public_send __send__].include?(st.name) && st.arguments&.arguments&.first.is_a?(Prism::SymbolNode) # send(:define_method, ...) is the call itself
        sym, *rest = st.arguments.arguments
        st = st.copy(name: sym.unescaped.to_sym, arguments: st.arguments.copy(arguments: rest))
      end
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
      when :each, :each_with_index # [:a, :b].each do |f| ... end  -> unrolled at compile time
        recv = st.receiver
        recv = recv.receiver if recv.is_a?(Prism::CallNode) && recv.name == :each_with_index && recv.receiver.is_a?(Prism::ArrayNode) # a.each_with_index.each
        elements = if recv.is_a?(Prism::ArrayNode) then recv.elements
                   elsif recv.is_a?(Prism::LocalVariableReadNode) && ct[recv.name].is_a?(Array) then ct[recv.name] # a macro's *rest or array parameter
                   else raise "class-body each over a non-literal array" end
        blk = st.block; var, ivar = blk.parameters.parameters.requireds.map(&:name)
        elements.each_with_index do |el, ix|
          env = ct.merge(var => (el.is_a?(Prism::Node) ? (el.is_a?(Prism::StringNode) ? el.unescaped : ct_symbol(el, ct)) : el)) # a %w element stays a String in the body; a ct value is itself
          env[ivar] = ix if ivar
          (blk.body&.body || []).each { |inner| class_body_call(k, inner, env, methods) }
        end
      when :extend then nil # handled in run (the module's defs became class methods)
      else raise "unsupported in class body: #{st.name}"
      end
    end

    # the DefNode of `def self.name` on k or an ancestor, when it is the kind of body a class-level macro has:
    # define_method / attr_* / instance_variable_* / nested macro calls, and nothing that needs a run-time value
    # does this class body use instance_variable_get/set/defined? with a name that is not a literal (or a macro parameter)?
    def reflects_ivars?(c)
      found = false
      walk = lambda do |node|
        return if found || !node.is_a?(Prism::Node)
        if node.is_a?(Prism::CallNode) && %i[instance_variable_get instance_variable_set instance_variable_defined?].include?(node.name) && (a = node.arguments&.arguments&.first) && !a.is_a?(Prism::SymbolNode) && !a.is_a?(Prism::StringNode)
          found = true; return
        end
        node.compact_child_nodes.each { walk.(_1) }
      end
      walk.(c.body)
      found
    end
    def all_kwarg_keys(node, out = [])
      return out unless node.is_a?(Prism::Node)
      node.elements.each { |el| out << el.key.unescaped.to_sym if el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode) } if node.is_a?(Prism::KeywordHashNode)
      node.compact_child_nodes.each { all_kwarg_keys(_1, out) }
      out.uniq
    end

    # a compile-time value as IR
    def ct_materialize(v)
      case v
      when String then emit(:sconst, [v])
      when Integer then const(v)
      when Symbol then (c = const(sym_id(v)); c.ty = :sym; c)
      when true, false then (c = const(v ? 1 : 0); c.ty = :bool; c)
      when nil then nil_const
      when Array then pack_values(v.map { ct_materialize(_1) })
      else raise "a compile-time value of #{v.class} cannot be used at run time"
      end
    end

    # an ivar named through a class-level macro's parameter: a real field of every instance, whether or not set yet
    def macro_field?(iv) = @ct && !@ct.empty?

    def class_macro_def(k, name)
      c = k
      while c
        f = @funcs[:"#{c.name}.#{name}"]
        return @defs_by_func[f] if f && @defs_by_func[f] && macro_body?(@defs_by_func[f])
        c = c.superclass
      end
      nil
    end
    MACRO_CALLS = %i[define_method attr_accessor attr_reader attr_writer alias_method private public protected].freeze
    def macro_body?(d, depth = 0)
      stmts = (d.body&.body || []).flat_map { |b| b.is_a?(Prism::ParenthesesNode) ? (b.body&.body || []) : [b] }
      !stmts.empty? && stmts.all? { |s| macro_stmt?(s, d, depth) }
    end
    def macro_stmt?(s, d, depth)
      return false unless s.is_a?(Prism::CallNode)
      return true if s.receiver.nil? && MACRO_CALLS.include?(s.name)
      # names.each { |n| attribute(n) } over a parameter: unrolled over the compile-time array
      if s.name == :each && s.receiver.is_a?(Prism::LocalVariableReadNode) && s.block.is_a?(Prism::BlockNode)
        return (s.block.body&.body || []).all? { |b| macro_stmt?(b, d, depth) }
      end
      return false unless s.receiver.nil? && depth < 4
      @sdef_nodes&.[](s.name)&.any? { |d2| !d2.equal?(d) && macro_body?(d2, depth + 1) } || false # a call to another class-level macro
    end

    # a Symbol known at compile time: literal, interpolated from ct, or a ct variable
    def ct_symbol(node, ct)
      case node
      when Prism::SymbolNode then node.unescaped.to_sym
      when Prism::StringNode then node.unescaped.to_sym
      when Prism::LocalVariableReadNode then ct.fetch(node.name) { raise "#{node.name} is not a compile-time symbol" }.to_sym
      when Prism::InterpolatedSymbolNode, Prism::InterpolatedStringNode
        node.parts.map do |part|
          case part
          when Prism::StringNode then part.unescaped
          when Prism::EmbeddedStatementsNode then ct_symbol(part.statements.body.last, ct).to_s
          else raise "not a compile-time symbol: #{part.class} in interpolation"
          end
        end.join.to_sym
      when Prism::CallNode # n.to_s / n.to_sym / "x".to_sym on a compile-time value
        return ct_symbol(node.receiver, ct) if %i[to_s to_sym].include?(node.name) && node.arguments.nil? && node.receiver
        raise "not a compile-time symbol: #{node.name}(...)"
      else raise "not a compile-time symbol: #{node.class}"
      end
    end

    # a value known at compile time, for a class-method DSL unrolled into the class body: symbol, string, integer,
    # true/false/nil, or an array of those
    def ct_value(node, ct)
      case node
      when Prism::SymbolNode then node.unescaped.to_sym
      when Prism::StringNode then node.unescaped
      when Prism::IntegerNode then node.value
      when Prism::TrueNode then true
      when Prism::FalseNode then false
      when Prism::NilNode then nil
      when Prism::ArrayNode then node.elements.map { ct_value(_1, ct) }
      when Prism::LocalVariableReadNode then ct.fetch(node.name) { raise "#{node.name} is not a compile-time value" }
      when Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode then ct_symbol(node, ct).then { node.is_a?(Prism::InterpolatedStringNode) ? _1.to_s : _1 }
      else raise "not a compile-time value: #{node.class}"
      end
    end

    # arguments for a method call on an object whose class Types resolves later. Defaults, *rest
    # and keywords are shaped here, when the class is known or every class defining the name
    # agrees on the parameter shape
    # a Hash.new(default) is a property of its home (the local or ivar), decided at compile time: passing it on
    # would read misses as nil in the callee
    def check_default_hash_args(args)
      args.each { |a| raise "a Hash with a default (Hash.new(v) / Hash.new { }) passed as an argument: the default belongs to its home; not supported" if hash_default_of(a) }
    end

    def object_args(n, args, klass, recv = nil)
      check_default_hash_args(args)
      # the receiver's class unknown: candidates are user classes (the library's own classes -- MatchData, Set, exceptions --
      # take arguments as the builtin families do; packing a *rest for them would mis-shape a Hash#values_at(:a, :b))
      return args.map { expr(_1) } if klass.nil? && n.receiver && (bk = kind_of(n.receiver)) && (bk == :hash || bk == :array || bk == :str || bk == :int || bk == :float || bk == :range) # a builtin receiver: its methods take arguments as given
      cands = klass ? [klass.find_method(n.name)].compact : @classes.values.filter_map { |k| k.methods[n.name] }
      cands = cands.select { @defs_by_func[_1] }
      needs = args.last.is_a?(Prism::KeywordHashNode) || cands.any? { |f| f.rest || @defs_by_func[f].parameters&.then { |ps| ps.optionals.any? || ps.keywords.any? || ps.keyword_rest.is_a?(Prism::KeywordRestParameterNode) } }
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
      check_default_hash_args(args)
      args = args.dup
      kw = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
      d = @defs_by_func[f]
      nfixed = d ? (d.parameters&.requireds&.size || 0) + (d.parameters&.optionals&.size || 0) : f.params.size - skip
      if (si = args.index { _1.is_a?(Prism::SplatNode) }) # m(*arr): the array's elements by index, up to the callee's fixed arity; a rest callee takes the array itself
        before = args[0...si].map { expr(_1) }; after = (args[(si + 1)..] || []).map { expr(_1) }
        sp = args[si].expression ? expr(args[si].expression) : @locals.fetch(lname(:__rest)) { raise "anonymous * outside a method taking *" } # f(*): this method's own rest
        if f.rest # the rest array is everything past the fixed parameters: pieces of before, the splat, after
          fixed_from_splat = [nfixed - before.size, 0].max
          taken = (0...fixed_from_splat).map { |k| emit(:idx, [sp, const(k)]) }
          tail = fixed_from_splat.zero? ? sp : emit(:call, [demand(:__arr_drop), sp, const(fixed_from_splat)])
          lead = before[nfixed..] || []
          rest = lead.empty? ? tail : emit(:call, [demand(:__arr_plus), pack_values(lead), tail])
          rest = emit(:call, [demand(:__arr_plus), rest, pack_values(after)]) unless after.empty?
          return (before[0, nfixed] + taken + [rest]) # keywords with a splat: unsupported, fall through would mis-place them
        end
        need = nfixed - before.size - after.size
        raise "#{f.name}: splat arguments cannot fill #{need} parameters" if need < 0
        vals = before + (0...need).map { |k| emit(:idx, [sp, const(k)]) } + after
        return vals unless d && (d.parameters&.optionals&.any? || d.parameters&.keywords&.any?)
        return fill_defaults(f, vals, kw)
      end
      vals = args.map { expr(_1) }
      if f.rest && d # the extra positionals become the *rest array
        ps = d.parameters
        fixed, extra = vals[0, nfixed], vals[nfixed..] || []
        fixed += [nil] * (nfixed - fixed.size) # omitted optionals: the rest array still sits at its own position (fill_defaults fills the nils)
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
    # x[k] = v for a receiver that is a hash or an array (Types decides which store)
    def idx_set_value(recv_node, key_node, v)
      emit(:idx_set, [expr(recv_node), expr(key_node), v])
    end

    def append_root(n)
      r = n.receiver
      r = r.body.body.last while r.is_a?(Prism::ParenthesesNode) && r.body&.body&.size == 1 # (expr) << v
      r = r.receiver while r.is_a?(Prism::CallNode) && r.name == :<<
      case r
      when Prism::LocalVariableReadNode then @int_locals&.include?(r.name) ? nil : r
      when Prism::InstanceVariableReadNode then r
      when Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableOperatorWriteNode then r # (@x ||= []) << v: the ivar is the home
      when Prism::CallNode
        return r if r.arguments.nil? && r.block.nil? && r.receiver # `obj.attr << v`: the slot becomes a cell (Types)
        if r.name == :[] && r.receiver && r.arguments&.arguments&.size == 1 && r.block.nil? # `h[k] << v`: the slot is written back
          # ... when the container has a home. `h.first[1] << v` / `f(x)[0] << v`: the container is a call's result; the slot written is a copy's
          raise "`<<` on an element of #{r.receiver.name}'s result: the container is a value here, the appended String would be shared with it in Ruby; not supported" if r.receiver.is_a?(Prism::CallNode) && !(r.receiver.arguments.nil? && r.receiver.block.nil? && r.receiver.receiver && kind_of(r.receiver.receiver).is_a?(Symbol) && @classes[kind_of(r.receiver.receiver)]) && kind_of(r.receiver) != :str
          return r
        end
        return r if r.arguments.nil? && r.block.nil? && r.receiver.nil? && @owner && @funcs[:"#{@owner}.#{r.name}"] # `registry << o` in a class method: the class object's ivar, through its reader
      when Prism::ConstantReadNode, Prism::GlobalVariableReadNode, Prism::ClassVariableReadNode then r # LIST << v: the global is rebound
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
      emit(:gset, [:__current_exception, exc]) if rescues.any? { |(_, _, body)| body.any? { has_global?(_1, :"$!") } } # $! inside the handler
      arms = rescues.map do |(classes, ref, body)|
        test = classes.map { |cn| emit(:isa, [exc, cn]) }.reduce { |a, b| emit(:or, [a, b]) }
        [test, ref, body, classes]
      end
      ends = []
      arms.each do |test, ref, body, classes|
        tb, nb = @f.new_block(:rescue), @f.new_block(:norescue)
        emit(:condbr, [test, tb, nb])
        @cur = tb; @locals = before.dup
        if ref.is_a?(Prism::LocalVariableTargetNode) # the bound exception is narrowed to the rescued class (one class; several stay the union)
          # one class with descendants that override its methods (`def message`): the set, so e.message dispatches
          if classes.size == 1 && (rk = @classes[classes[0]])
            descendants = @classes.values.select { |c| !c.equal?(rk) && !c.closure && (a = c.superclass; a = a.superclass while a && !a.equal?(rk); a) }
            overriding = descendants.select { |c| c.methods.keys.any? { |m| rk.find_method(m) } }
            @locals[lname(ref.name)] = overriding.empty? ? emit(:unbox, [exc, classes[0]]) : (u = emit(:unbox, [exc, [:poly, [rk.name, *descendants.map(&:name)].sort]]); u)
          else
            @locals[lname(ref.name)] = exc
          end
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
      ends << [@cur, before.dup, (c = const(0); c.ty = :nil; c)]; emit(:br, [mb]) # unreachable: a nil joins any arm type without widening it (an int 0 made str arms dyn)
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


    # a class body's statements, registered into k: defs, mixins, attr_* and friends
    def register_class_body(k, stmts, methods)
      stmts = stmts.flat_map do |st| # `private def x = 1`: the def, then `private :x`
        if st.is_a?(Prism::CallNode) && %i[private public protected module_function].include?(st.name) && st.receiver.nil? && st.arguments&.arguments&.size == 1 && st.arguments.arguments[0].is_a?(Prism::DefNode)
          d = st.arguments.arguments[0]; src = st.send(:source); loc = st.location
          [d, st.copy(arguments: st.arguments.copy(arguments: [Prism::SymbolNode.new(src, 0, loc, 0, nil, loc, nil, d.name.to_s)]))]
        else [st] end
      end
      assigned_ivars(stmts).each { k.ivar(_1) }
      # the method resolution order, flattened into this class: included modules first (a
      # later definition overrides an earlier one), the body, then prepended modules on top.
      # An overridden definition stays reachable as the overrider's `shadowed`: super's target
      mods_named = ->(kind) { stmts.select { |st| st.is_a?(Prism::CallNode) && st.name == kind && st.receiver.nil? }
                                .flat_map { |st| st.arguments.arguments.map { |a| a.is_a?(Prism::ConstantReadNode) ? a.name : raise("#{kind} needs a module name") } } }
      mod_defs = ->(m) { @module_defs.fetch(m) { m == :Comparable || m == :Enumerable ? [] : raise("include #{m}: unknown module") } }
      included, prepended = mods_named.(:include), mods_named.(:prepend)
      if included.include?(:Enumerable) # every Enumerable method is the array method on what each yields
        k.enumerable = true
        unless stmts.any? { |st| st.is_a?(Prism::DefNode) && st.name == :to_a }
          @enum_to_a_defs ||= Prism.parse("def to_a\n  __out = []\n  each { |__x| __out << __x }\n  __out\nend").value.statements.body
          stmts = stmts + @enum_to_a_defs
        end
      end
      (k.mixins ||= []).concat(included + prepended)
      mixed_in, prepended_defs = included.flat_map(&mod_defs), prepended.flat_map(&mod_defs)
      (mixed_in + stmts.grep(Prism::DefNode) + prepended_defs).each { |d| assigned_ivars(d).each { k.ivar(_1) } } # every field known before any method is lowered
      (k.nullable_ivars ||= []).concat((mixed_in + stmts.grep(Prism::DefNode) + prepended_defs).flat_map { or_written_ivars(_1) }).uniq!
      @visibility = nil
      (mixed_in + stmts + prepended_defs).each do |st|
        case st
        when Prism::DefNode
          next if st.receiver.is_a?(Prism::SelfNode) # Owner.m, registered above
          if yields?(st) then @yielders[st.name] = [k, st]; next end # inlined only
          ps = st.parameters
          f = Func.new(:"#{k.name}##{st.name}#{k.methods[st.name] ? "'" * (1 + k.methods[st.name].name.to_s.count("'")) : ""}", 1 + def_param_names(st).size)
          f.rest = true if ps&.rest.is_a?(Prism::RestParameterNode)
          if (prev = k.methods[st.name]) && prev.cls == k && !(mixed_in + prepended_defs).include?(st) && !(mixed_in + prepended_defs).include?(@defs_by_func[prev])
            # the same class defines the method again (a later re-opening): a version. Callers bind to the first;
            # the method is patchable and a `redefine` at the re-opening's position points its slot at this body.
            primary = prev.primary || prev
            f.name = :"#{k.name}##{st.name}@v#{(primary.versions || []).size + 1}" # one label per version
            f.primary = primary; (primary.versions ||= []) << f; primary.patchable = true
            f.cls = k; methods << [k, st, f]; @defs_by_func[f] = st
            next
          end
          f.shadowed = k.methods[st.name] if k.methods[st.name]&.cls == k
          f.cls = k; k.methods[st.name] = f; methods << [k, st, f]; @defs_by_func[f] = st
          (k.hidden ||= {})[st.name] = @visibility if @visibility && @visibility != :public
        when Prism::ConstantWriteNode then nil # hoisted above
        when Prism::AliasMethodNode, Prism::CallNode # alias new old / alias_method :new, :old: the same Func under a second name (a yielder: a second inline site)
          if st.is_a?(Prism::CallNode)
            if st.name == :alias_method && st.receiver.nil? && st.arguments&.arguments&.size == 2
              new_name = st.arguments.arguments[0].unescaped.to_sym; old_name = st.arguments.arguments[1].unescaped.to_sym
            else
              next if st.name == :include || st.name == :prepend # mixed in above
              if %i[private public protected].include?(st.name) && st.receiver.nil?
                if st.arguments.nil? then @visibility = st.name # a bare `private`: the defs below are not public
                else (st.arguments.arguments).each { |a| nm = a.unescaped.to_sym; (k.methods[nm] || k.readers[nm]) && (st.name == :public ? k.hidden&.delete(nm) : (k.hidden ||= {})[nm] = st.name) } end # private :m
                next
              end
              next if %i[private_constant module_function freeze].include?(st.name) && st.receiver.nil? # visibility is not enforced (every call is resolved at compile time)
              if %i[remove_method undef_method].include?(st.name) && st.receiver.nil? # the method is gone from this class
                st.arguments.arguments.each { |a| nm = a.unescaped.to_sym; k.methods.delete(nm); k.readers.delete(nm); k.writers.delete(nm); (k.removed ||= {})[nm] = true }
                next
              end
              class_body_call(k, st, {}, methods); next
            end
          else
            new_name = st.new_name.unescaped.to_sym; old_name = st.old_name.unescaped.to_sym
          end
          if (y = @yielders[old_name]) then @yielders[new_name] = y
          elsif (m = k.methods[old_name])
            # the alias names the body as it is now; a later `def old` makes old a patchable slot pointing at the new version,
            # so the alias must not go through that slot: a non-patchable copy bound to the current (latest) version
            cur = m.versions&.last || m
            if cur.patchable || m.patchable || (@redefine_markers&.values&.any? { |(cn, names)| cn == k.name && names.include?(old_name) })
              copy = Func.new(:"#{k.name}##{new_name}", cur.params.size); copy.cls = k; copy.rest = cur.rest
              @defs_by_func[copy] = @defs_by_func[cur]; methods << [k, @defs_by_func[cur], copy]
              k.methods[new_name] = copy
            else k.methods[new_name] = m end
          elsif k.readers[old_name] then k.readers[new_name] = k.readers[old_name]
          else raise "alias #{new_name} #{old_name}: no such method in #{k.name}" end
        when Prism::ClassVariableWriteNode, Prism::InstanceVariableWriteNode, Prism::SingletonClassNode, Prism::ClassNode, Prism::ModuleNode then nil # hoisted above
        else raise "unsupported in class body: #{st.class}"
        end
      end
    end

    def struct_new?(v) = v.is_a?(Prism::CallNode) && (v.name == :new && v.receiver.is_a?(Prism::ConstantReadNode) && v.receiver.name == :Struct || data_define?(v))
    def data_define?(v) = v.is_a?(Prism::CallNode) && v.name == :define && v.receiver.is_a?(Prism::ConstantReadNode) && v.receiver.name == :Data

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

    def lower_body(f, names, stmts, klass = nil, ct = {}, captured = nil, shared_in = [], hash_param = nil)
      @f, @locals, @cur, @klass, @ct = f, names.zip(f.params).to_h, f.entry, klass, ct
      (@hash_defaults ||= {})[lname(hash_param)] = :closure_self if hash_param # a Hash.new default block: reads of its hash parameter miss into this very block
      @block_param = (d = @defs_by_func[f]) && d.parameters&.block ? (d.parameters.block.name || :__blk) : (f.name.to_s.end_with?("$blk") ? :__blk : nil)
      @shared = (stmts.is_a?(Array) ? shared_locals(stmts) : []) + shared_in
      captured&.each { |nm| @locals[nm] = emit(:fld_get, [@locals[:self], klass.ivar(:"@#{nm}")]) } # a lambda's captures: the value, or the shared cell
      if klass&.closure && klass.outer # a lambda written inside a method: `self` and @ivars are the enclosing object's
        @locals[:self] = emit(:fld_get, [@locals[:self], klass.ivar(:@__self)])
        @klass = klass.outer
      end
      if f.name == :main && @mod_ivars # `module M; @x = 1; end` runs before the program
        @mod_ivars.each { |owner, w| @owner = owner; expr(w); @owner = nil }
      end
      if stmts.first.is_a?(Array) && stmts.first[0] == :struct_set # a Struct's initialize
        stmts.each { |(_, fld)| emit(:fld_set, [@locals[:self], klass.ivar(:"@#{fld}"), @locals.fetch(fld)]) }
        emit(:ret, [@locals[:self]])
        return
      end
      last = nil
      stmts.each do |st|
        if st.is_a?(Array) && st[0] == :method_added # A.method_added(:m) for each def, if the class (or an ancestor) defines the hook
          anc = @classes[st[1]]
          anc = anc.superclass while anc && !@funcs[:"#{anc.name}.method_added"]
          emit(:call, [@funcs[:"#{anc.name}.method_added"], (c = const(sym_id(st[2].to_s)); c.ty = :sym; c)]) if anc
          next
        end
        if st.is_a?(Array) && st[0] == :mod_hook # M.extended(o) / M.included(k) when a class body extends/includes M
          emit(:call, [@funcs[:"#{st[2]}.#{st[1]}"], emit(:sconst, [st[3].to_s])]) if @funcs[:"#{st[2]}.#{st[1]}"]
          next
        end
        if st.is_a?(Array) && st[0] == :inherited # Parent.inherited(Sub) at the subclass's declaration, if an ancestor defines the hook
          anc = @classes[st[1]]&.superclass
          anc = anc.superclass while anc && !@funcs[:"#{anc.name}.inherited"]
          emit(:call, [@funcs[:"#{anc.name}.inherited"], emit(:sconst, [st[1].to_s])]) if anc
          next
        end
        if st.is_a?(Array) && st[0] == :redefine # a re-opening that redefines methods, at its program position: the slots take the next versions
          _, cname, names = st
          k = @classes[cname]
          names.each do |nm|
            primary = k.methods[nm]; primary = primary.primary || primary
            @redefine_count ||= Hash.new(0); v = primary.versions[@redefine_count[[cname, nm]]]; @redefine_count[[cname, nm]] += 1
            raise "redefinition of #{cname}##{nm} without a version" unless v
            emit(:setslot, [primary, v])
          end
          last = nil_const; next
        end
        last = expr(st)
      end
      last = const(0) if f.name == :main # the program's last expression is not a value anyone reads
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

    # "on_#{event}" where every piece is a literal (a symbol/string constant folded by the
    # compile-time environment): the name, or nil when it is computed
    def interpolated_literal(n)
      parts = n.parts.map do |p|
        case p
        when Prism::StringNode then p.unescaped
        when Prism::EmbeddedStatementsNode
          e = p.statements.body.last
          case e
          when Prism::SymbolNode, Prism::StringNode then e.unescaped
          when Prism::LocalVariableReadNode then @ct&.key?(e.name) ? @ct[e.name].to_s : nil
          end
        end
      end
      parts.all? ? parts.join : nil
    end

    def nil_const = (c = const(0); c.ty = :nil; c)

    # a regexp literal: compiled now (lib/indus/regex.rb) into a program the prelude matcher
    # runs; one Regexp object per literal, built when first evaluated and kept in a global
    def regexp_groups(n) = Regex.compile(n.unescaped, n.ignore_case? ? "i" : "")[1]

    def regexp_value(n)
      raise "regexp with interpolation: not supported (the pattern must be known at compile time)" unless n.is_a?(Prism::RegularExpressionNode)
      fl = +""
      fl << "i" if n.ignore_case?
      raise "regexp /x flag: not supported" if n.extended?
      raise "regexp /m flag: not supported" if n.multi_line?
      prog, ngroups, names = Regex.compile(n.unescaped, fl)
      @regexps ||= {}
      key = [n.unescaped, fl]
      gname = (@regexps[key] ||= :"__RE#{@regexps.size}")
      # the object: lazily built at the use site when the global is still nil (a cheap check)
      cur = emit(:gget, [gname])
      tb, eb, mb = @f.new_block(:remk), @f.new_block(:rehave), @f.new_block(:remerge)
      isnil = emit(:cmp, [cur, nil_const], :eq)
      emit(:condbr, [isnil, tb, eb])
      @cur = tb
      # the program travels as bytes in the data section (4 per word, two's complement), decoded once
      bytes = prog.map { |w| [w & 0xffffffff].pack("V") }.join
      arr = emit(:call, [demand(:__re_decode), emit(:sconst, [bytes])])
      k = @classes.fetch(:Regexp)
      o = emit(:onew, [k])
      names_v = emit(:anew, [const(ngroups + 1), emit(:sconst, [""])])
      names.each_with_index { |nm, ix| names_v = emit(:aset, [names_v, const(ix), emit(:sconst, [nm])]) if nm }
      emit(:call, [k.methods.fetch(:initialize), o, arr, const((ngroups + 1) * 2), emit(:sconst, [n.unescaped]), names_v])
      emit(:gset, [gname, o])
      tend = @cur; emit(:br, [mb])
      @cur = eb; emit(:br, [mb])
      @cur = mb
      ph = mb.phi; ph.args = [[tend, o], [eb, cur]]; ph
    end

    # obj.x = v with the receiver already evaluated: the class's writer (an attr_accessor's
    # field store, or a user-defined x=)
    def attr_assign(recv_node, rv, writer, v)
      emit(:mcall, [writer, rv, v])
      v
    end
    def me_val = @name_pfx ? @locals.fetch(:"#{@name_pfx}self") : @locals.fetch(:self)
    # @x outside any class (main, top-level defs): the toplevel object's ivars, as globals
    def ivar_owner = @owner || (@klass.nil? && !@locals.key?(:self) && !(@name_pfx && @locals.key?(:"#{@name_pfx}self")) ? :main : nil)
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
      when Prism::CaseMatchNode then case_match_expr(n)
      when Prism::DefinedNode then defined_expr(n.value)
      when Prism::BeginNode then begin_expr(n)
      when Prism::RescueModifierNode then rescue_modifier(n) # expr rescue fallback
      when Prism::SuperNode, Prism::ForwardingSuperNode # super(args) / super: the superclass's version of this method
        raise "super outside a method" unless @klass && @f.cls
        mname = @f.name.to_s.split("#").last.delete("'").sub(/@v\d+\z/, "").to_sym
        sup = @f.shadowed || @klass.superclass&.find_method(mname)
        if sup.nil? # Object's own: method_missing raises NoMethodError, respond_to? is false (no method above answered)
          case mname
          when :method_missing
            nm = (n.is_a?(Prism::SuperNode) ? n.arguments&.arguments&.first : nil) || Prism::LocalVariableReadNode.new(n.send(:source), 0, n.location, 0, @f.params[1] && @defs_by_func[@f]&.parameters&.requireds&.first&.name || :__none, 0)
            src = n.send(:source); loc = n.location
            msg = Prism::InterpolatedStringNode.new(src, 0, loc, 0, nil, [Prism::StringNode.new(src, 0, loc, 0, nil, loc, nil, "undefined method '"), Prism::EmbeddedStatementsNode.new(src, 0, loc, 0, loc, Prism::StatementsNode.new(src, 0, loc, 0, [nm]), loc), Prism::StringNode.new(src, 0, loc, 0, nil, loc, nil, "' for an instance of #{@klass.name}")], nil)
            exc = new_exception(:NoMethodError, [msg])
            emit(:raise, [exc]); emit(:call, [demand(:__uncaught), exc])
            return nil_const
          when :respond_to?, :respond_to_missing? then return (c = const(0); c.ty = :bool; c)
          when :initialize then return nil_const # Object#initialize takes nothing and does nothing
          when :to_s, :inspect then return emit(:sconst, ["#<#{@klass.name}>"])
          when :freeze, :dup, :clone, :itself then return me_val # no frozen bit; the object itself
          when :== then return emit(:cmp, [me_val, expr(n.arguments.arguments[0])], :eq) # Object#==: identity
          when :hash then return emit(:handle, [me_val])
          end
          raise "super: no #{mname} above #{@klass.name}"
        end
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
      when Prism::CallOperatorWriteNode # obj.x += v  ->  obj.x = (obj.x + v)
        recv = n.receiver
        read = Prism::CallNode.new(n.send(:source), 0, n.location, 0, recv, nil, n.read_name, nil, nil, nil, nil, nil, nil)
        rv = expr(recv)
        cur = call(read)
        v = emit(ARITH.fetch(n.binary_operator), [cur, expr(n.value)])
        attr_assign(recv, rv, n.write_name, v)
      when Prism::CallOrWriteNode, Prism::CallAndWriteNode # obj.x ||= v / obj.x &&= v
        recv = n.receiver
        read = Prism::CallNode.new(n.send(:source), 0, n.location, 0, recv, nil, n.read_name, nil, nil, nil, nil, nil, nil)
        rv = expr(recv)
        cur = call(read)
        cond_assign(cur, n.is_a?(Prism::CallAndWriteNode), -> { expr(n.value) }, ->(v) { attr_assign(recv, rv, n.write_name, v) })
      when Prism::GlobalVariableOperatorWriteNode # $x += v
        v = emit(ARITH.fetch(n.binary_operator), [emit(:gget, [n.name]), expr(n.value)]); emit(:gset, [n.name, v]); v
      when Prism::GlobalVariableOrWriteNode then cond_assign(emit(:gget, [n.name]), false, -> { expr(n.value) }, ->(v) { emit(:gset, [n.name, v]) })
      when Prism::GlobalVariableAndWriteNode then cond_assign(emit(:gget, [n.name]), true, -> { expr(n.value) }, ->(v) { emit(:gset, [n.name, v]) })
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
          when Prism::AssocSplatNode then h = emit(:call, [demand(:__hash_merge_into), h, el.value ? expr(el.value) : @locals.fetch(lname(:__kwrest))]) # { **other } / { ** } (anonymous)
          else raise "unsupported hash element #{el.class}"
          end
        end
        h
      when Prism::InstanceVariableReadNode
        ow = ivar_owner # a module's / class object's / the toplevel's own ivar
        return emit(:gget, [:"#{ow}#{n.name}"]) if ow
        emit(:fld_get, [me_val, @klass.ivar(n.name)])
      when Prism::InstanceVariableOrWriteNode # @x ||= v
        ow = ivar_owner
        cur = ow ? emit(:gget, [:"#{ow}#{n.name}"]) : emit(:fld_get, [me_val, @klass.ivar(n.name)])
        cond_assign(cur, false, -> { expr(n.value) }, ->(v) { ow ? emit(:gset, [:"#{ow}#{n.name}", v]) : emit(:fld_set, [me_val, @klass.ivar(n.name), v]) })
      when Prism::InstanceVariableAndWriteNode # @x &&= v
        ow = ivar_owner
        cur = ow ? emit(:gget, [:"#{ow}#{n.name}"]) : emit(:fld_get, [me_val, @klass.ivar(n.name)])
        cond_assign(cur, true, -> { expr(n.value) }, ->(v) { ow ? emit(:gset, [:"#{ow}#{n.name}", v]) : emit(:fld_set, [me_val, @klass.ivar(n.name), v]) })
      when Prism::InstanceVariableOperatorWriteNode # @x += v
        ow = ivar_owner
        cur = ow ? emit(:gget, [:"#{ow}#{n.name}"]) : emit(:fld_get, [me_val, @klass.ivar(n.name)])
        v = emit(ARITH.fetch(n.binary_operator), [cur, expr(n.value)])
        ow ? emit(:gset, [:"#{ow}#{n.name}", v]) : emit(:fld_set, [me_val, @klass.ivar(n.name), v])
        v
      when Prism::InstanceVariableWriteNode
        if (ow = ivar_owner) then v = expr(n.value); emit(:gset, [:"#{ow}#{n.name}", v]); return v end
        (@hash_defaults ||= {})[[@klass&.name, n.name]] = hash_default_node(n.value) if hash_new_with_default?(n.value)
        v = expr(n.value)
        ((@ivar_kinds ||= {})[[@klass&.name, n.name]] ||= kind_of(n.value)) if @klass
        emit(:fld_set, [me_val, @klass.ivar(n.name), v]); v
      when Prism::ConstantReadNode
        if n.name == :ARGV then emit(:anew, [const(0), emit(:sconst, [""])]) # no arguments: an empty array of strings (ARGV[k] is nil, ARGV.size 0)
        elsif (o = const_owner(n.name)) then emit(:gget, [:"#{o}::#{n.name}"]) # a class's constant, found lexically
        else emit(:gget, [n.name]) end
      when Prism::ConstantWriteNode
        v = expr(n.value); emit(:gset, [n.name, v]); v
      when Prism::GlobalVariableReadNode
        case n.name
        when :$~ then emit(:call, [demand(:__re_groups_array)])
        when :$! then emit(:gget, [:__current_exception])
        else emit(:gget, [n.name]) end
      when Prism::NumberedReferenceReadNode then emit(:call, [demand(:__re_group), const(n.number)]) # $1..$9 after the last match
      when Prism::BackReferenceReadNode # $~ (the groups of the last match as an array; $~[0] the whole match), $& the match
        raise "#{n.name}: only $~ and $& are supported" unless %i[$~ $&].include?(n.name)
        n.name == :$& ? emit(:call, [demand(:__re_group), const(0)]) : emit(:call, [demand(:__re_groups_array)])
      when Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode then regexp_value(n)
      when Prism::MatchWriteNode then expr(n.call) # /(?<x>..)/ =~ s with named captures: the match itself (names unsupported, parser refuses)
      when Prism::GlobalVariableWriteNode, Prism::ClassVariableWriteNode # @@x: one global per name (a hierarchy shares it in Ruby too)
        v = expr(n.value); emit(:gset, [n.name, v]); v
      when Prism::ClassVariableReadNode then emit(:gget, [n.name])
      when Prism::ClassVariableOperatorWriteNode # @@count += 1
        v = emit(ARITH.fetch(n.binary_operator), [emit(:gget, [n.name]), expr(n.value)]); emit(:gset, [n.name, v]); v
      when Prism::LocalVariableReadNode
        if @in_safe_nav && @in_safe_nav_node.equal?(n) then @in_safe_nav
        elsif @ct&.key?(n.name) then ct_materialize(@ct[n.name]) # a compile-time value (a class-level macro's parameter), string or index
        elsif shared?(n.name) then emit(:cell_get, [@locals.fetch(lname(n.name)) { raise "undefined local #{n.name}" }])
        else @locals.fetch(lname(n.name)) { raise "undefined local #{n.name}" } end
      when Prism::LocalVariableWriteNode
        if n.value.is_a?(Prism::LambdaNode) # inlined at `x.call(...)` sites; a value wherever else x is used
          (@lambdas ||= {})[lname(n.name)] = n.value
          return (@locals[lname(n.name)] = lambda_value(n.value))
        end
        v = expr(n.value) # value first: loops replace @locals
        (@kinds ||= {})[lname(n.name)] = kind_of(n.value)
        (@hash_defaults ||= {})[lname(n.name)] = hash_default_node(n.value) if hash_new_with_default?(n.value)
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
        vals = if n.value.is_a?(Prism::ArrayNode) && !n.rest && n.value.elements.none? { _1.is_a?(Prism::SplatNode) } then n.value.elements.map { expr(_1) }
               else
                 src = n.value.is_a?(Prism::ArrayNode) && n.value.elements.size == 1 && n.value.elements[0].is_a?(Prism::SplatNode) ? n.value.elements[0].expression : n.value # x, y = *obj
                 arr = expr(src)
                 arr = emit(:mcall, [:to_a, arr]) if (kd = kind_of(src)).is_a?(Symbol) && @classes[kd] # an object: its to_a (a Struct)
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
          when Prism::LocalVariableTargetNode, Prism::RequiredParameterNode then shared?(t.name) ? write_shared(t.name, v) : @locals[lname(t.name)] = v # a captured local: through its cell (a RequiredParameterNode: a destructured block parameter)
          when Prism::InstanceVariableTargetNode
            if (ow = ivar_owner) then emit(:gset, [:"#{ow}#{t.name}", v])
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
        bv = n.arguments ? expr(n.arguments.arguments[0]) : nil
        (@loop[:break_values] ||= []) << [@cur, bv] if bv
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
        if @block == :none then emit(:trap, []); return nil_const end # a yielder called without a block: yield raises LocalJumpError in Ruby
        raise "yield outside an inlined block method" unless @block
        yield_block(n.arguments&.arguments || [])
      when Prism::RangeNode then range_array(n) # a Range as a value: its elements (each/map/times fuse before reaching here)
      when Prism::SymbolNode then (c = const(sym_id(n.unescaped)); c.ty = :sym; c)
      when Prism::InterpolatedSymbolNode # :"a#{x}": the string, interned at run time
        str = expr(Prism::InterpolatedStringNode.new(n.send(:source), 0, n.location, 0, nil, n.parts, nil))
        emit(:call, [demand(:__str_to_sym), str])
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
      when Prism::ForNode # for x in coll: each over the collection; the variable is an ordinary local
        src = n.send(:source); loc = n.location
        names = n.index.is_a?(Prism::MultiTargetNode) ? n.index.lefts.map(&:name) : [n.index.name]
        reqs = names.map { Prism::RequiredParameterNode.new(src, 0, loc, 0, _1) }
        params = Prism::BlockParametersNode.new(src, 0, loc, 0, Prism::ParametersNode.new(src, 0, loc, 0, reqs, [], nil, [], [], nil, nil), [], nil, nil)
        blk = Prism::BlockNode.new(src, 0, loc, 0, [], params, n.statements, loc, loc)
        names.each { |nm| @locals[lname(nm)] ||= nil_const } # visible after the loop
        each = Prism::CallNode.new(src, 0, loc, 0, n.collection, nil, :each, loc, nil, nil, nil, nil, blk)
        expr(each)
      when Prism::CallNode then call(n)
      when Prism::OrNode
        l = expr(n.left)
        if l.ty == :nil then expr(n.right)                       # nil || y  ->  y, at compile time
        else or_value(l) { expr(n.right) } end
      when Prism::AndNode # a && b as a value: b when a is truthy, else a (Ruby returns the operand, not a boolean)
        l = expr(n.left)
        l.ty == :nil ? l : and_value(l) { expr(n.right) }
      when Prism::IndexTargetNode then raise "unsupported index target"
      when Prism::DefNode # a def reached as a statement: a later definition writes the method's slot; the first is already compiled
        if (sub = @singletons&.[](n)) then emit(:retag, [expr(n.receiver), sub]); return (c = const(sym_id(n.name.to_s)); c.ty = :sym; c) end # def x.m: x joins the hidden subclass
        if (pv = @def_versions[n]) then emit(:setslot, pv) end
        c = const(sym_id(n.name.to_s)); c.ty = :sym; c
      when Prism::ClassNode # a class body reached at run time (under an if, inside a method): its defs' slot writes
        (n.body&.body || []).each { |st| expr(st) if st.is_a?(Prism::DefNode) }
        nil_const
      else raise "unsupported: #{n.class}"
      end
    end

    # singleton sites: yields [node, receiver node, [DefNodes]] for `def x.m`, `x.extend(M)`, `x.define_singleton_method(:m) { }`
    def scan_singletons(node, &blk)
      return node.each { scan_singletons(_1, &blk) } if node.is_a?(Array)
      return unless node.is_a?(Prism::Node)
      case node
      when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode then return
      when Prism::DefNode
        if node.receiver && !node.receiver.is_a?(Prism::SelfNode) then blk.call(node, node.receiver, [node.copy(receiver: nil)]); return end
      when Prism::CallNode
        if node.name == :extend && node.receiver && !node.receiver.is_a?(Prism::ConstantReadNode) && node.arguments
          defs = node.arguments.arguments.flat_map { |m| m.is_a?(Prism::ConstantReadNode) ? (@module_defs[m.name] || raise("extend #{m.name}: no such module")) : raise("extend: a module name") }
          blk.call(node, node.receiver, defs); return
        end
        if node.name == :define_singleton_method && node.receiver && node.block.is_a?(Prism::BlockNode) && node.arguments&.arguments&.first.is_a?(Prism::SymbolNode)
          src = node.send(:source); loc = node.location; b = node.block
          ps = b.parameters.is_a?(Prism::BlockParametersNode) ? b.parameters.parameters : nil
          d = Prism::DefNode.new(src, 0, loc, 0, node.arguments.arguments.first.unescaped.to_sym, loc, nil, ps, b.body, b.locals, loc, nil, nil, nil, nil, nil)
          blk.call(node, node.receiver, [d]); return
        end
      end
      node.compact_child_nodes.each { scan_singletons(_1, &blk) }
    end

    # a string known at compile time: a literal, a heredoc, or an interpolation of literals and constants
    def literal_string(node)
      case node
      when Prism::StringNode then node.unescaped
      when Prism::InterpolatedStringNode
        parts = node.parts.map { |pt| pt.is_a?(Prism::StringNode) ? pt.unescaped : (pt.is_a?(Prism::EmbeddedStatementsNode) && pt.statements.body.size == 1 && pt.statements.body[0].is_a?(Prism::StringNode) ? pt.statements.body[0].unescaped : nil) }
        parts.all? ? parts.join : nil
      end
    end

    # defs nested below the hoisted positions: inside methods, conditionals, blocks, class_eval blocks.
    # Each is a version of the method on the lexically enclosing class (nil: the top level).
    def collect_nested_defs(node, owner, out, top_level: false)
      return node.each { collect_nested_defs(_1, owner, out, top_level: top_level) } if node.is_a?(Array)
      return unless node.is_a?(Prism::Node)
      case node
      when Prism::ClassNode
        cname = node.constant_path.name
        (node.body&.body || []).each do |st|
          st = st.arguments.arguments[0] if st.is_a?(Prism::CallNode) && %i[private public protected module_function].include?(st.name) && st.receiver.nil? && st.arguments&.arguments&.size == 1 && st.arguments.arguments[0].is_a?(Prism::DefNode) # `private def x`
          if st.is_a?(Prism::DefNode)
            out << [cname, st] if !top_level && !st.receiver # a class body reached at run time (under an if, in a method): its defs are versions
            collect_nested_defs(st.body, cname, out)
          else collect_nested_defs(st, cname, out) end
        end
        return
      when Prism::ModuleNode, Prism::SingletonClassNode then return # a module's defs are mixed into classes; class << self defs are class methods
      when Prism::DefNode
        return if node.receiver # def self.m: a class method (versions of those: not yet)
        out << [owner, node] unless top_level
        collect_nested_defs(node.body, owner, out); return
      when Prism::CallNode
        if %i[private public protected module_function].include?(node.name) && node.receiver.nil? && node.arguments&.arguments&.size == 1 && node.arguments.arguments[0].is_a?(Prism::DefNode)
          return collect_nested_defs(node.arguments.arguments[0], owner, out, top_level: top_level) # `private def x`: the def itself, at this level
        end
        if %i[send public_send __send__].include?(node.name) && node.receiver.is_a?(Prism::ConstantReadNode) && node.arguments&.arguments&.first.is_a?(Prism::SymbolNode) && node.arguments.arguments.first.unescaped == "define_method" && node.block
          sym, *rest = node.arguments.arguments # X.send(:define_method, :m) { }: the define_method call itself
          rewritten = node.copy(name: :define_method, arguments: node.arguments.copy(arguments: rest))
          (@send_rewrites ||= {})[node] = rewritten
          return collect_nested_defs(rewritten, owner, out, top_level: top_level)
        end
        if node.name == :class_eval && node.receiver.is_a?(Prism::ConstantReadNode) && node.block.is_a?(Prism::BlockNode) # X.class_eval { def ... }: defs on X
          (node.block.body&.body || []).each { |st| out << [node.receiver.name, st] if st.is_a?(Prism::DefNode) }
          return
        end
        if %i[class_eval module_eval].include?(node.name) && node.receiver.is_a?(Prism::ConstantReadNode) && (lit = literal_string(node.arguments&.arguments&.first))
          # X.class_eval "def ..." with a literal: known at compile time, the same as a block
          (@eval_parsed ||= {})[node] = Lower.normalize(Prism.parse(lit).value).statements.body
          @eval_parsed[node].each { |st| out << [node.receiver.name, st] if st.is_a?(Prism::DefNode) }
          return
        end
        return if struct_new?(node)
        if node.name == :define_method && node.block.is_a?(Prism::BlockNode) && node.arguments&.arguments&.first.is_a?(Prism::SymbolNode) && (node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.nil? && owner && !top_level)
          # X.define_method(:m) { |a| ... } at run time: a def of m on X, written at this site
          return if node.receiver.nil? && top_level # inside a class body: handled by class_body_call
          cname = node.receiver ? node.receiver.name : owner
          blk = node.block; src = node.send(:source); loc = node.location
          ps = blk.parameters.is_a?(Prism::BlockParametersNode) ? blk.parameters.parameters : nil
          d = Prism::DefNode.new(src, 0, loc, 0, node.arguments.arguments.first.unescaped.to_sym, loc, nil, ps, blk.body, blk.locals, loc, nil, nil, nil, nil, nil)
          (@define_method_defs ||= {})[node] = d
          out << [cname, d]; return
        end
        return if node.name == :define_method
      when Prism::ConstantWriteNode
        return if struct_new?(node.value)
      end
      node.compact_child_nodes.each { |c| collect_nested_defs(c, owner, out, top_level: top_level && node.is_a?(Prism::StatementsNode)) }
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

    # l && <right>: right if l is truthy, else l, as a value
    def and_value(l)
      tb, eb, mb = @f.new_block(:andt), @f.new_block(:andf), @f.new_block(:andm)
      emit(:condbr, [l, tb, eb])
      before = @locals.dup
      @cur = tb; r = yield; tend, tl = @cur, @locals; emit(:br, [mb])
      @cur = eb; emit(:br, [mb])
      @cur = mb; @locals = merge_locals(mb, [[tend, tl], [eb, before]])
      p = mb.phi; p.args = [[tend, r], [eb, l]]; p
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

    ENUMERABLE = %i[map collect select filter reject sum count min max min_by max_by sort sort_by group_by partition each_with_index each_with_object
                    reduce inject find detect find_index any? all? none? one? include? first take drop take_while drop_while flat_map
                    each_slice each_cons zip to_a entries tally uniq reverse_each filter_map minmax each_entry to_set lazy].freeze

    # a receiver whose class includes Enumerable and does not define the method itself: the
    # array method on what each yields (to_a is synthesized from each at declaration)
    def enumerable_receiver(n)
      recv = n.receiver
      k = if recv.nil? then @klass
          elsif (kd = kind_of(recv)).is_a?(Symbol) then @classes[kd] end
      return nil unless k&.enumerable && ENUMERABLE.include?(n.name) && n.name != :to_a && !k.find_method(n.name)
      src = recv || Prism::SelfNode.new(n.send(:source), 0, n.location, 0)
      Prism::CallNode.new(n.send(:source), 0, n.location, 0, src, nil, :to_a, nil, nil, nil, nil, nil, nil)
    end

    def call(n)
      args = n.arguments&.arguments || []
      if (ta = enumerable_receiver(n)) then return call(n.copy(receiver: ta)) end
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
      if n.receiver && !n.block && !n.receiver.is_a?(Prism::ConstantReadNode) && (k = kind_of(n.receiver)).is_a?(Symbol) && @classes[k] && (y = @yielders[n.name]) && y[0] && (k == y[0].name)
        return inline_yielder(y, n.receiver, args, nil, :none) # obj.m without a block, m yields: inlined with block_given? false
      end
      if n.receiver && !n.receiver.is_a?(Prism::SelfNode) && (k = kind_of(n.receiver)).is_a?(Symbol) && (kk = @classes[k]) && kk.hidden&.[](n.name) && !(kk.hidden[n.name] == :protected && @klass && (@klass.equal?(kk) || (c = @klass.superclass; c = c.superclass while c && !c.equal?(kk); c)))
        # a private (or, from outside the class, protected) method called with an explicit receiver: NoMethodError
        expr(n.receiver); args.each { expr(_1) }
        src = n.send(:source); loc = n.location
        msg = Prism::StringNode.new(src, 0, loc, 0, nil, loc, nil, "#{kk.hidden[n.name] == :protected ? "protected" : "private"} method '#{n.name}' called for an instance of #{kk.name}")
        exc = new_exception(:NoMethodError, [msg])
        emit(:raise, [exc]); emit(:call, [demand(:__uncaught), exc])
        return nil_const
      end
      if n.receiver && !n.block && !n.receiver.is_a?(Prism::ConstantReadNode) && (k = kind_of(n.receiver)).is_a?(Symbol) && @classes[k] && !%i[== != < <= > >= + - * / % [] []= nil? is_a? ! << send public_send __send__ respond_to? extend define_singleton_method methods public_methods singleton_methods singleton_class instance_variable_get instance_variable_set instance_variable_defined? instance_variables instance_eval instance_exec define_method method class_eval instance_variable_get].include?(n.name)
        rv = expr(n.receiver)
        return emit(:mcall, [n.name, rv, *object_args(n, args, @classes[k], rv)])
      end
      if n.block.is_a?(Prism::BlockNode) && n.receiver.nil? && (f = @funcs[n.name]) && (d = @defs_by_func[f]) && d.parameters&.block
        blk = n.block
        params = blk.parameters&.parameters&.requireds&.map(&:name) || []
        c = closure_value(params, free_locals(blk.body, params).select { |nm| @locals.key?(lname(nm)) }, blk.body&.body || [], ie_self: ie_target(f))
        return emit(:call, [f, *call_args(f, args), c])
      end
      # a method taking &blk on self or on an object of a known class, called with a block literal: the block is a closure value
      if n.block.is_a?(Prism::BlockNode)
        mk = n.receiver.nil? ? @klass : ((kd = kind_of(n.receiver)).is_a?(Symbol) ? @classes[kd] : nil)
        if n.receiver.is_a?(Prism::ConstantReadNode) && (sf = @funcs[:"#{n.receiver.name}.#{n.name}"]) && (d = @defs_by_func[sf]) && d.parameters&.block && (iek = ie_target(sf))
          # Owner.m { ... } where m does obj.instance_eval(&blk): the block's self is that object (its class is known)
          blk = n.block
          params = blk.parameters&.parameters&.requireds&.map(&:name) || []
          c = closure_value(params, free_locals(blk.body, params).select { |nm| @locals.key?(lname(nm)) }, blk.body&.body || [], ie_self: iek)
          return emit(:call, [sf, *call_args(sf, args), c])
        end
        if mk.nil? && n.receiver && !n.receiver.is_a?(Prism::ConstantReadNode) && !ENUMERABLE.include?(n.name) && !%i[each each_with_index times upto downto step each_char each_byte each_line each_pair each_key each_value loop fetch].include?(n.name) # a receiver of unknown class: every user class defining the method takes a block the same way
          cands = @classes.values.filter_map { |k| k.methods[n.name] }.select { @defs_by_func[_1] && !_1.cls.name.to_s.start_with?("__") }
          mk = cands[0].cls if !cands.empty? && cands.all? { |mf| @defs_by_func[mf].parameters&.block }
        end
        if mk && (mf = mk.find_method(n.name)) && (d = @defs_by_func[mf]) && d.parameters&.block
          blk = n.block
          params = blk.parameters&.parameters&.requireds&.map(&:name) || []
          c = closure_value(params, free_locals(blk.body, params).select { |nm| @locals.key?(lname(nm)) }, blk.body&.body || [], ie_self: ie_target(mf))
          rv = n.receiver ? expr(n.receiver) : me_val
          return emit(:mcall, [n.name, rv, *method_args(mf, args, rv), c])
        end
      end
      if n.block.is_a?(Prism::BlockArgumentNode) && n.block.expression.is_a?(Prism::SymbolNode) && n.receiver
        return block_call(n, args) # map(&:upcase), group_by(&:length), ...: the block { |e| e.sym }
      end
      if n.block.is_a?(Prism::BlockArgumentNode) && n.block.expression && (kd = kind_of(n.block.expression)).is_a?(Symbol) && @classes[kd]&.find_method(:to_proc)
        # m(&obj) where obj's class defines to_proc: the block is obj.to_proc
        src = n.send(:source); loc = n.location
        tp = Prism::CallNode.new(src, 0, loc, 0, n.block.expression, nil, :to_proc, nil, nil, nil, nil, nil, nil)
        return expr(n.copy(block: n.block.copy(expression: tp)))
      end
      if n.block.is_a?(Prism::BlockArgumentNode) && !(%i[instance_eval instance_exec].include?(n.name) && n.block.expression) # m(&b): the block is already a value; m(&) forwards this method's own block
        bv = n.block.expression ? expr(n.block.expression) : @locals.fetch(@block_param || :__blk) { raise "anonymous & outside a method taking a block" }
        return block_arg_call(n, args, bv)
      end
      return block_call(n, args) if n.block.is_a?(Prism::BlockNode) && !(n.name == :new && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Hash) && !(%i[class_eval class_exec].include?(n.name) && n.receiver.is_a?(Prism::ConstantReadNode)) && !(n.name == :define_method && @define_method_defs&.key?(n)) && !(%i[instance_eval instance_exec].include?(n.name) && (n.receiver || n.block.is_a?(Prism::BlockArgumentNode))) && !@singletons&.key?(n) && !@send_rewrites&.key?(n)
      if n.name == :<< && (kd = kind_of(n.receiver)).is_a?(Symbol) && @classes[kd] && args.size == 1 # obj << v: the class's own method
        rv = expr(n.receiver)
        return emit(:mcall, [:<<, rv, expr(args[0])])
      end
      if n.name == :concat && args.size >= 1 && n.receiver && (root = append_root(n)) # a.concat(b[, c]): grown in place, the home rebound like <<
        a = expr(n.receiver)
        r = emit(:call, [demand(args.size == 1 ? :__arr_concat : :__arr_concat2), a, *args.map { expr(_1) }]); r.routed = :concat # Types reroutes to the String helper by the receiver's type
        case root
        when Prism::LocalVariableReadNode then shared?(root.name) ? write_shared(root.name, r) : @locals[lname(root.name)] = r
        when Prism::InstanceVariableReadNode then (ow = ivar_owner) ? emit(:gset, [:"#{ow}#{root.name}", r]) : emit(:fld_set, [me_val, @klass.ivar(root.name), r])
        when Prism::ConstantReadNode, Prism::GlobalVariableReadNode then emit(:gset, [root.name, r])
        end
        return r
      end
      if n.name == :<< && (root = append_root(n)) # `<<` is append on strings/arrays and shift on integers; Types fixes up a misguess
        a = expr(n.receiver); v = expr(args[0])
        r = emit(:lshift_or_append, [a, v])
        case root # the chain's home is rebound to the result (a grown string/array may have moved)
        when Prism::LocalVariableReadNode then shared?(root.name) ? write_shared(root.name, r) : @locals[lname(root.name)] = r
        when Prism::InstanceVariableReadNode, Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableOperatorWriteNode
          (ow = ivar_owner) ? emit(:gset, [:"#{ow}#{root.name}", r]) : emit(:fld_set, [me_val, @klass.ivar(root.name), r])
        when Prism::CallNode
          if root.name == :[] # h[k] << v / a[i] << v: the element slot takes the grown handle
            idx_set_value(root.receiver, root.arguments.arguments[0], r)
          elsif root.receiver.nil? && @owner # the class object's ivar behind a class-level reader
            emit(:gset, [:"#{@owner}@#{root.name}", r])
          end
        when Prism::ConstantReadNode, Prism::GlobalVariableReadNode, Prism::ClassVariableReadNode then emit(:gset, [root.name, r])
        end
        return r
      end
      if n.receiver.nil? && n.name.to_s.start_with?("__") && !@funcs[n.name] && !(@klass && @klass.find_method(n.name))
        return (r = emit(:shl, [expr(args[0]), expr(args[1])]); r.raw_shift = true; r) if n.name == :__shl_raw
        return (r = emit(:shr, [expr(args[0]), expr(args[1])]); r.raw_shift = true; r) if n.name == :__shr_raw
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
      return expr(@send_rewrites[n]) if @send_rewrites&.key?(n) # X.send(:define_method, ...): the call itself
      if n.name == :send || n.name == :public_send || n.name == :__send__
        name, *rest = args
        recv_v = n.receiver ? expr(n.receiver) : me_val
        if name.is_a?(Prism::SymbolNode) # send(:literal) is a plain call
          return emit(:mcall, [name.unescaped.to_sym, recv_v, *rest.map { expr(_1) }])
        end
        nv = expr(name)
        nv = emit(:call, [demand(:__str_to_sym), nv]) if name.is_a?(Prism::StringNode) || name.is_a?(Prism::InterpolatedStringNode) || kind_of(name) == :str # a computed name: its symbol (Types converts a str-typed name too)
        @classes.each_value { |k| (k.methods.keys + k.readers.keys + k.writers.keys).each { sym_id(_1.to_s) } } # every method name is a symbol the table knows: a computed name interns to the same id
        return emit(:dsend, [nv, recv_v, *rest.map { expr(_1) }]) # switch over the class's methods
      end
      if n.name == :% && n.receiver && (kind_of(n.receiver) == :str || n.receiver.is_a?(Prism::StringNode) || n.receiver.is_a?(Prism::InterpolatedStringNode))
        list = args[0].is_a?(Prism::ArrayNode) ? args[0].elements : [args[0]] # "fmt" % args
        return emit(:call, [demand(:__format), expr(n.receiver), dyn_array(list)])
      end
      if (op = ARITH[n.name])
        l = expr(n.receiver); r = expr(args[0])
        return emit(:mcall, [n.name, l, r]) if (kd = kind_of(n.receiver)).is_a?(Symbol) && @classes[kd] # an operator the class defines
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
      elsif n.name == :p && n.receiver.nil? && args.size > 1 # p a, b: every argument evaluated, then one line each
        vals = args.map { |a| inline_inspect?(a) ? [:str, inspect_str(a)] : class_valued?(a) ? [:puts, expr(a)] : [:p, expr(a)] }
        vals.each { |(k, v)| emit(k == :str ? :puts_str : k == :puts ? :puts_v : :p_v, [v]) }; return const(0)
      elsif n.name == :p && n.receiver.nil? && args.size == 1 then p_one(args[0])
      elsif n.name == :inspect && args.empty? && n.receiver then inspect_str(n.receiver)
      elsif n.name == :print && n.receiver.nil? && args.size > 1
        r = nil
        args.each { |a| r = emit(:print_v, [expr(a)]) } # print a, b: no separator
        r
      elsif n.name == :print && n.receiver.nil? && args.size == 1
        emit(:print_v, [expr(args[0])])   # no newline
      elsif n.name == :Integer && n.receiver.nil? && args.size == 1
        r = emit(:to_i, [expr(args[0])]); r.strict = true; r # Integer("junk") raises ArgumentError (Types: a String goes to __kernel_integer)
      elsif n.name == :Integer && n.receiver.nil? && args.size == 2 then expr(n.copy(name: :to_i, receiver: args[0], arguments: n.arguments.copy(arguments: [args[1]]))) # Integer("1f", 16)
      elsif n.name == :Float && n.receiver.nil? && args.size == 1 then emit(:to_f, [expr(args[0])])
      elsif n.name == :String && n.receiver.nil? && args.size == 1 then to_s(expr(args[0]))
      elsif n.name == :Array && n.receiver.nil? && args.size == 1 # Array(x): nil -> [], an array itself, a range its elements, a scalar wrapped
        a = args[0]
        if a.is_a?(Prism::NilNode) then emit(:anew, [const(0), (c = const(0); c.ty = :nil; c)])
        elsif a.is_a?(Prism::RangeNode) || a.is_a?(Prism::ParenthesesNode) && a.body.body.last.is_a?(Prism::RangeNode) then range_array(a.is_a?(Prism::ParenthesesNode) ? a.body.body.last : a)
        elsif a.is_a?(Prism::ArrayNode) || kind_of(a).is_a?(Array) && kind_of(a)[0] == :array then expr(a)
        else expr(Prism::ArrayNode.new(a.send(:source), 0, a.location, 0, [a], nil, nil)) end
      elsif n.name == :respond_to? && n.receiver && (kd = kind_of(n.receiver)).is_a?(Symbol) && (rk = @classes[kd]) && (um = rk.find_method(:respond_to?)) # the class's own respond_to?
        rv = expr(n.receiver); emit(:call, [um, rv, *method_args(um, args, rv)])
      elsif n.name == :respond_to? && args.size == 1 && (args[0].is_a?(Prism::SymbolNode) || args[0].is_a?(Prism::StringNode) || args[0].is_a?(Prism::InterpolatedStringNode))
        # the class is known at compile time, so is the answer; an interpolated name must be a literal-with-constants
        nm = case args[0]
             when Prism::SymbolNode, Prism::StringNode then args[0].unescaped
             else interpolated_literal(args[0])
             end&.to_sym
        k = n.receiver.nil? ? @klass : ((kd = kind_of(n.receiver)).is_a?(Symbol) ? @classes[kd] : nil)
        if k.nil? && nm && n.receiver # the receiver's class is decided at run time: Types answers per class of the set (respond_to_q)
          return emit(:respond_to_q, [expr(n.receiver), nm])
        end
        raise "respond_to?: the receiver's class is not known at compile time" unless k
        if nm # a literal name: a compile-time fact
          rv = n.receiver ? expr(n.receiver) : me_val # the receiver is still evaluated
          has = (k.find_method(nm) || k.find_reader(nm) || k.find_writer(nm)) && !k.hidden&.[](nm)
          if !has && (rtm = k.find_method(:respond_to_missing?)) # the class decides at run time
            sc = const(sym_id(nm.to_s)); sc.ty = :sym; fc = const(0); fc.ty = :bool
            return emit(:call, [rtm, rv, sc, fc])
          end
          c = const(has ? 1 : 0); c.ty = :bool; c # a private method does not respond
        else # a computed name: its symbol against the class's own, at run time
          nv = expr(args[0])
          nv = emit(:call, [demand(:__str_to_sym_q), nv]) unless args[0].is_a?(Prism::SymbolNode)
          ids = []
          Types.each_method(k) { |mn, _, _, _| ids << sym_id(mn.to_s) }
          ids.uniq!
          hit = nil
          ids.each { |sid| t = emit(:cmp, [nv, const(sid)], :eq); hit = hit ? emit(:or, [hit, t]) : t }
          hit || (c = const(0); c.ty = :bool; c)
        end
      elsif n.name == :include? && args.size == 1 && n.receiver.is_a?(Prism::ConstantReadNode) && (k = @classes[n.receiver.name]) && args[0].is_a?(Prism::ConstantReadNode)
        c = const(Types.ancestor?(k, args[0].name) ? 1 : 0); c.ty = :bool; c # Klass.include?(M): a compile-time fact
      elsif %i[name to_s inspect].include?(n.name) && args.empty? && n.receiver.is_a?(Prism::ConstantReadNode) && (@classes[n.receiver.name] || @modules.include?(n.receiver.name))
        emit(:sconst, [n.receiver.name.to_s]) # Klass.name
      elsif n.name == :class && args.empty? && n.receiver.is_a?(Prism::ConstantReadNode) && (@classes[n.receiver.name] || @modules.include?(n.receiver.name))
        emit(:sconst, [@modules.include?(n.receiver.name) ? "Module" : "Class"])
      elsif n.name == :singleton_methods && n.receiver && (kd = kind_of(n.receiver)).is_a?(Symbol) && (kk = @classes[kd])
        # the methods defined on this very object (def o.m / extend): those of the hidden subclass it was retagged into, by class id
        expr(n.receiver)
        subs = @classes.values.select { |c| c.superclass.equal?(kk) && c.name.to_s.include?("$") }
        if subs.empty? then pack_values([])
        else
          raise "singleton_methods: several singleton sites on #{kk.name}; not supported" if subs.size > 1
          names = subs[0].methods.keys.map { |nm| c = const(sym_id(nm.to_s)); c.ty = :sym; c }
          # a retag happens at the def site: before it the object is a plain kk (no singleton methods)
          tagged = emit(:isa_tag, [expr(n.receiver), subs[0].id]); tagged.ty = :bool
          tb, eb, mb = @f.new_block(:sm_yes), @f.new_block(:sm_no), @f.new_block(:sm_merge)
          emit(:condbr, [tagged, tb, eb])
          @cur = tb; yes = pack_values(names); emit(:br, [mb])
          @cur = eb; no = pack_values([]); emit(:br, [mb])
          @cur = mb; ph = mb.phi; ph.args = [[tb, yes], [eb, no]]; ph
        end
      elsif n.name == :instance_methods && n.receiver.is_a?(Prism::CallNode) && n.receiver.name == :singleton_class && n.receiver.receiver && (kd = kind_of(n.receiver.receiver)).is_a?(Symbol) && @classes[kd]
        expr(n.copy(name: :singleton_methods, receiver: n.receiver.receiver, arguments: nil)) # obj.singleton_class.instance_methods(false)
      elsif %i[methods public_methods].include?(n.name) && n.receiver && !n.receiver.is_a?(Prism::ConstantReadNode) && (kd = kind_of(n.receiver)).is_a?(Symbol) && (kk = @classes[kd])
        # obj.methods / obj.public_methods(false): the class's instance methods (its own only with false)
        expr(n.receiver)
        own_only = args[0].is_a?(Prism::FalseNode)
        chain = []; c = kk; while c; chain << c; c = c.superclass; end
        chain = [kk] if own_only
        names = chain.flat_map { |c| c.methods.keys.reject { _1 == :initialize || _1.to_s.start_with?("__") || c.hidden&.[](_1) } + c.readers.keys + c.writers.keys }.uniq
        pack_values(names.map { |nm| c = const(sym_id(nm.to_s)); c.ty = :sym; c })
      elsif %i[instance_methods public_instance_methods singleton_methods methods public_methods].include?(n.name) && n.receiver.is_a?(Prism::ConstantReadNode) && ((kk = @classes[n.receiver.name]) || @modules.include?(n.receiver.name))
        own_only = args[0].is_a?(Prism::FalseNode)
        names = if n.name == :singleton_methods || n.name == :methods # the class object's methods (inherited class methods too, unless (false))
                  chain = []; c = kk; while c; chain << c.name; c = c.superclass && @classes[c.superclass]; end
                  chain = [n.receiver.name] if own_only || chain.empty?
                  chain.flat_map { |cn| @funcs.keys.map(&:to_s).select { _1.start_with?("#{cn}.") }.map { _1.split(".", 2)[1].to_sym }.reject { own_only && @inherited_cm&.[]([cn, _1]) } }.uniq
                else
                  chain = []; c = kk; while c; chain << c; c = c.superclass && @classes[c.superclass]; end
                  chain = [kk] if own_only
                  chain.flat_map { |c| c.methods.keys.reject { _1 == :initialize || _1.to_s.start_with?("__") } + c.readers.keys + c.writers.keys }.uniq
                end
        pack_values(names.map { |nm| c = const(sym_id(nm.to_s)); c.ty = :sym; c })
      elsif %i[owner name arity].include?(n.name) && args.empty? && n.receiver.is_a?(Prism::CallNode) && n.receiver.name == :instance_method && n.receiver.receiver.is_a?(Prism::ConstantReadNode) && (uk = @classes[n.receiver.receiver.name]) && n.receiver.arguments&.arguments&.first.is_a?(Prism::SymbolNode)
        um = n.receiver.arguments.arguments.first.unescaped.to_sym
        case n.name
        when :owner then (c = uk; c = c.superclass while c && !c.methods.key?(um) && !c.readers.key?(um) && !c.writers.key?(um); emit(:sconst, [(c || uk).name.to_s]))
        when :name then (c = const(sym_id(um.to_s)); c.ty = :sym; c)
        else (m = uk.find_method(um)) ? const(m.params.size - 1) : const(uk.find_reader(um) ? 0 : 1) end
      elsif %i[call bind_call].include?(n.name) && n.receiver.is_a?(Prism::CallNode) && (um = unbound_method_of(n.receiver, n.name == :bind_call ? args[0] : nil))
        kname, mname, obj = um
        rest = n.name == :bind_call ? args[1..] : args
        expr(Prism::CallNode.new(n.send(:source), 0, n.location, 0, obj, nil, mname, nil, nil, rest.empty? ? nil : Prism::ArgumentsNode.new(n.send(:source), 0, n.location, 0, rest), nil, nil, nil))
      elsif %i[method_defined? instance_method public_method_defined? private_method_defined?].include?(n.name) && n.receiver.is_a?(Prism::ConstantReadNode) && (kk = @classes[n.receiver.name]) && args[0].is_a?(Prism::SymbolNode)
        nm = args[0].unescaped.to_sym; has = kk.find_method(nm) || kk.find_reader(nm) || kk.find_writer(nm)
        raise "#{n.receiver.name}.instance_method(:#{nm}): no such method" if n.name == :instance_method && !has
        return emit(:sconst, ["#<UnboundMethod: #{n.receiver.name}##{nm}>"]) if n.name == :instance_method # a method object: bind(obj).call is the call (below)
        c = const(has && (n.name == :private_method_defined? ? kk.hidden&.[](nm) : !kk.hidden&.[](nm)) ? 1 : 0); c.ty = :bool; c
      elsif n.name == :const_get && n.receiver.is_a?(Prism::ConstantReadNode) && args.size == 1 && (args[0].is_a?(Prism::SymbolNode) || args[0].is_a?(Prism::StringNode))
        cn = args[0].unescaped.to_sym
        if n.receiver.name == :Object then expr(Prism::ConstantReadNode.new(n.send(:source), 0, n.location, 0, cn))
        else emit(:gget, [:"#{n.receiver.name}::#{cn}"]) end
      elsif n.name == :const_defined? && n.receiver.is_a?(Prism::ConstantReadNode) && args.size == 1 && (args[0].is_a?(Prism::SymbolNode) || args[0].is_a?(Prism::StringNode))
        cn = args[0].unescaped.to_sym
        known = n.receiver.name == :Object ? (@classes.key?(cn) || @modules.include?(cn) || has_const?(cn) || %i[String Integer Float Array Hash Symbol Object Kernel Comparable Enumerable Math Struct].include?(cn)) : has_const?(:"#{n.receiver.name}::#{cn}")
        c = const(known ? 1 : 0); c.ty = :bool; c
      elsif n.name == :constants && args.empty? && n.receiver.is_a?(Prism::ConstantReadNode) && @classes[n.receiver.name]
        pfx = "#{n.receiver.name}::"
        pack_values(const_names.select { _1.to_s.start_with?(pfx) }.map { |cn| c = const(sym_id(cn.to_s.delete_prefix(pfx))); c.ty = :sym; c })
      elsif n.name == :members && args.empty? && n.receiver.is_a?(Prism::ConstantReadNode) && @struct_fields&.[](n.receiver.name)
        pack_values(@struct_fields[n.receiver.name].map { |fl| c = const(sym_id(fl.to_s)); c.ty = :sym; c })
      elsif n.name == :superclass && args.empty? && n.receiver.is_a?(Prism::ConstantReadNode) && @classes[n.receiver.name]
        emit(:sconst, [(@classes[n.receiver.name].superclass&.name || :Object).to_s])
      elsif n.name == :frozen? && args.empty? && n.receiver # no frozen bit: literals and objects report false, symbols/numbers/nil true
        k = n.receiver
        emit(:const, [k.is_a?(Prism::SymbolNode) || k.is_a?(Prism::IntegerNode) || k.is_a?(Prism::FloatNode) || k.is_a?(Prism::NilNode) || k.is_a?(Prism::TrueNode) || k.is_a?(Prism::FalseNode) ? 1 : 0]).tap { _1.ty = :bool }
      elsif n.name == :name && args.empty? && n.receiver.is_a?(Prism::CallNode) && n.receiver.name == :class && n.receiver.arguments.nil? && n.receiver.receiver
        expr(n.receiver) # obj.class.name: the class is already its name (no class objects)
      elsif n.name == :ancestors && args.empty? && n.receiver.is_a?(Prism::ConstantReadNode) then raise "ancestors: no class objects at run time"
      elsif n.name == :extend && args.size == 1 && n.receiver && !@singletons&.key?(n) then raise "extend on #{n.receiver.class}: the object's class must be known at compile time"
      elsif %i[is_a? kind_of? instance_of?].include?(n.name) && args.size == 1 && n.receiver && args[0].is_a?(Prism::ConstantReadNode)
        emit(:isa, [expr(n.receiver), args[0].name])
      elsif n.name == :=== && args.size == 1 && n.receiver.is_a?(Prism::ConstantReadNode) && (@classes[n.receiver.name] || @modules.include?(n.receiver.name) || %i[Integer Float String Array Hash Symbol NilClass Numeric Comparable].include?(n.receiver.name))
        emit(:isa, [expr(args[0]), n.receiver.name]) # Klass === x
      elsif n.name == :class && args.empty? && n.receiver && (bk = builtin_kind(n.receiver))
        emit(:sconst, [{ int: "Integer", float: "Float", str: "String", array: "Array", hash: "Hash", range: "Range", sym: "Symbol", bool: n.receiver.is_a?(Prism::TrueNode) ? "TrueClass" : "FalseClass", nil: "NilClass" }[bk]]) # a builtin's class: its name (no class objects at run time)
      elsif n.name == :method && args.size == 1 && args[0].is_a?(Prism::SymbolNode) # method(:m): a closure over the call
        mname = args[0].unescaped.to_sym; src = n.send(:source); loc = n.location
        target = n.receiver.nil? ? (@funcs[mname] || @yielders[mname] || (@klass && @klass.find_method(mname))) : ((kd = kind_of(n.receiver)).is_a?(Symbol) && @classes[kd] ? @classes[kd].find_method(mname) : nil)
        d = target.is_a?(Func) ? @defs_by_func[target] : (target.is_a?(Array) ? target[1] : nil)
        zero_arity = %i[upcase downcase size length to_s to_i to_f reverse strip chars bytes sum min max first last sort uniq inspect succ abs even? odd? zero? empty? keys values to_a to_sym capitalize swapcase chomp chop hash].include?(mname)
        nparams = d ? def_param_names(d).size : (n.receiver ? (zero_arity ? 0 : (mname == :pow ? 2 : 1)) : (%i[puts p print String Integer Float Array].include?(mname) ? 1 : raise("method(:#{mname}): unknown method")))
        params = (0...nparams).map { :"a#{_1}__" }
        arg_nodes = params.map { Prism::LocalVariableReadNode.new(src, 0, loc, 0, _1, 0) }
        recv_node = n.receiver
        if recv_node && !recv_node.is_a?(Prism::LocalVariableReadNode) && !recv_node.is_a?(Prism::IntegerNode) && !recv_node.is_a?(Prism::StringNode) && !recv_node.is_a?(Prism::ConstantReadNode)
          # obj_expr.method(:m): the receiver is evaluated once, into a hidden local the Method object captures
          hidden = :"__mrecv#{@f.blocks.size}_#{@lambda_count || 0}"
          @locals[lname(hidden)] = expr(recv_node)
          recv_node = Prism::LocalVariableReadNode.new(src, 0, loc, 0, hidden, 0)
        end
        captured = recv_node.is_a?(Prism::LocalVariableReadNode) ? [recv_node.name] : []
        call_node = Prism::CallNode.new(src, 0, loc, 0, recv_node, nil, mname, loc, nil, arg_nodes.empty? ? nil : Prism::ArgumentsNode.new(src, 0, loc, 0, arg_nodes), nil, nil, nil)
        c = closure_value(params, captured, [call_node])
        owner = n.receiver.nil? ? (target.is_a?(Func) && target.cls ? target.cls.name : (@klass&.name || :Object)) : ((kd = kind_of(recv_node)).is_a?(Symbol) && @classes[kd] ? kd : { int: :Integer, str: :String, float: :Float, array: :Array, hash: :Hash }[kd])
        c.args[0].method_of = [owner, mname, nparams, recv_node ? captured.first : nil]
        sym_id(mname.to_s) # .name answers with the symbol: in the table now
        c
      elsif n.name == :block_given? && args.empty? && n.receiver.nil?
        if @block == :none then (c = const(0); c.ty = :bool; c)
        elsif @block then (c = const(1); c.ty = :bool; c)
        elsif @block_param && @locals[@block_param] then emit(:cmp, [@locals[@block_param], (c = const(0); c.ty = :nil; c)], :ne) # &blk given?
        else raise "block_given? outside a method that can take a block" end
      elsif n.name == :nil? && args.empty? && n.receiver
        v = expr(n.receiver); emit(:cmp, [v, (c = const(0); c.ty = :nil; c)], :eq)
      elsif n.name == :to_s && args.empty? && n.receiver.nil? && @klass && @klass.find_method(:to_s) # bare to_s: self's
        emit(:call, [@klass.find_method(:to_s), me_val])
      elsif n.name == :to_s && args.empty? && n.receiver.nil? then raise "to_s with no receiver outside a class defining it"
      elsif n.name == :to_s && args.empty? then to_s(expr(n.receiver))
      elsif n.name == :+@ && args.empty? then expr(n.receiver) # +"" : literals are already fresh copies
      elsif n.name == :cover? && args.size == 1 && (r = n.receiver.is_a?(Prism::ParenthesesNode) ? n.receiver.body.body.last : n.receiver).is_a?(Prism::RangeNode)
        v = expr(args[0]) # (a..b).cover?(x) / include?: the comparison, no array
        lo = emit(:cmp, [v, expr(r.left)], :ge)
        hi = emit(:cmp, [v, expr(r.right)], r.exclude_end? ? :lt : :le)
        emit(:and, [lo, hi])
      elsif n.name == :clamp && args.size == 2 && n.receiver && !((kd = kind_of(n.receiver)).is_a?(Symbol) && @classes[kd]) # x.clamp(lo, hi) returns lo or hi themselves (an Integer bound stays an Integer)
        x = expr(n.receiver); lo = expr(args[0]); hi = expr(args[1])
        below = emit(:cmp, [x, lo], :lt)
        tb, eb, mb = @f.new_block(:cl), @f.new_block(:ch), @f.new_block(:cm)
        emit(:condbr, [below, tb, eb])
        @cur = tb; emit(:br, [mb])
        @cur = eb
        above = emit(:cmp, [x, hi], :gt)
        tb2, eb2, mb2 = @f.new_block(:cl2), @f.new_block(:ch2), @f.new_block(:cm2)
        emit(:condbr, [above, tb2, eb2])
        @cur = tb2; emit(:br, [mb2]); @cur = eb2; emit(:br, [mb2])
        @cur = mb2; inner = mb2.phi; inner.args = [[tb2, hi], [eb2, x]]; emit(:br, [mb])
        @cur = mb; p = mb.phi; p.args = [[tb, lo], [mb2, inner]]; p
      elsif n.name == :~ && args.empty? && n.receiver then emit(:xor, [expr(n.receiver), const(-1)]) # bitwise not
      elsif %i[match match? scan sub gsub split =~ !~].include?(n.name) && args.size >= 1 && args[0].is_a?(Prism::RegularExpressionNode) && n.receiver && !((kd = kind_of(n.receiver)).is_a?(Symbol) && @classes[kd])
        re = expr(args[0]); sv = expr(n.receiver)
        case n.name
        when :match then (r = emit(:call, [demand(:__str_match_re), sv, re]); r.routed = :match; r) # Types reroutes when the receiver turns out not to be a String
        when :match? then emit(:call, [demand(:__str_match_p_re), sv, re])
        when :scan then emit(:call, [demand(regexp_groups(args[0]) > 0 ? :__str_scan_groups_re : :__str_scan_re), sv, re])
        when :sub then emit(:call, [demand(:__str_sub_re), sv, re, expr(args[1])])
        when :gsub then emit(:call, [demand(:__str_gsub_re), sv, re, expr(args[1])])
        when :split then emit(:call, [demand(:__str_split_re), sv, re])
        when :=~ then emit(:call, [demand(:__str_index_re), sv, re])
        when :!~ then emit(:cmp, [emit(:call, [demand(:__str_match_p_re), sv, re]), (c = const(0); c.ty = :bool; c)], :eq)
        end
      elsif n.name == :=~ && args.size == 1 && n.receiver.is_a?(Prism::RegularExpressionNode) # /re/ =~ s
        emit(:call, [demand(:__str_index_re), expr(args[0]), expr(n.receiver)])
      elsif n.name == :first && args.size == 1 && n.receiver.is_a?(Prism::CallNode) && n.receiver.name == :cycle && n.receiver.arguments.nil? && n.receiver.receiver
        emit(:call, [demand(:__arr_cycle_first), expr(n.receiver.receiver), expr(args[0])]) # xs.cycle.first(n): the only finite view of a cycle
      elsif n.name == :step && args.size == 1 && n.receiver.is_a?(Prism::ParenthesesNode) && n.receiver.body.body.last.is_a?(Prism::RangeNode) # (a..b).step(n)
        rg = n.receiver.body.body.last
        hi = rg.exclude_end? ? emit(:sub, [expr(rg.right), const(1)]) : expr(rg.right)
        emit(:call, [demand(:__num_step_to), expr(rg.left), hi, expr(args[0])])
      elsif n.name == :step && args.size == 2 && n.receiver # a.step(b, by)
        emit(:call, [demand(:__num_step_to), expr(n.receiver), expr(args[0]), expr(args[1])])
      elsif n.name == :sqrt && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Integer
        emit(:call, [demand(:__num_isqrt), expr(args[0])])
      elsif %i[cbrt hypot log2 log10 log exp atan2 atan tan asin acos].include?(n.name) && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Math
        emit(:libm, [n.name, *args.map { expr(_1) }]) # libm in-process; the Ruby libm (rt/libm.rb) standalone
      elsif n.name == :rand && n.receiver.nil? && args.size <= 1
        if args.empty? then emit(:call, [demand(:__rand_float)])
        elsif args[0].is_a?(Prism::RangeNode) then emit(:call, [demand(:__rand_range), expr(args[0].left), expr(args[0].right)])
        else emit(:call, [demand(:__rand_int), expr(args[0])]) end
      elsif n.name == :new && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Array
        len = args[0] ? expr(args[0]) : const(0); fill = args[1] ? expr(args[1]) : (c = const(0); c.ty = :nil; c)
        emit(:anew, [len, fill])
      elsif n.name == :new && (n.receiver.is_a?(Prism::ConstantReadNode) || n.receiver.is_a?(Prism::ConstantPathNode)) && @classes[n.receiver.name]
        k = @classes[n.receiver.name]
        obj = emit(:onew, [k])
        if (init = k.find_method(:initialize))
          if (fields = @struct_fields&.[](k.name)) && (@struct_kw&.[](k.name) || args.size < fields.size || args.last.is_a?(Prism::KeywordHashNode) && @struct_kw_ok&.[](k.name)) # Struct: keyword_init, or fewer values than members (the rest nil); Data: either
            given = {}
            if args.last.is_a?(Prism::KeywordHashNode) then args.last.elements.each { |e| given[e.key.unescaped.to_sym] = e.value }; args = args[0...-1] end
            vals = fields.each_with_index.map { |fl, ix| given.key?(fl) ? expr(given[fl]) : args[ix] ? expr(args[ix]) : nil_const }
            emit(:call, [init, obj, *vals])
          else
            emit(:call, [init, obj, *method_args(init, args)])
          end
        end
        obj
      elsif n.name == :class_eval && n.receiver.is_a?(Prism::ConstantReadNode) && @classes[n.receiver.name] && n.block.is_a?(Prism::BlockNode)
        (n.block.body&.body || []).each { |st| expr(st) if st.is_a?(Prism::DefNode) } # X.class_eval { def m ... }: versions written here
        nil_const
      elsif %i[class_eval module_eval].include?(n.name) && n.receiver.is_a?(Prism::ConstantReadNode) && @classes[n.receiver.name] && @eval_parsed&.key?(n)
        @eval_parsed[n].each { |st| st.is_a?(Prism::DefNode) ? expr(st) : nil } # a literal string: its defs' slot writes here (other statements in it: ignored)
        nil_const
      elsif n.name == :values_at && n.receiver && args.any? { _1.is_a?(Prism::RangeNode) && _1.left.is_a?(Prism::IntegerNode) && _1.right.is_a?(Prism::IntegerNode) }
        expanded = args.flat_map do |a| # m.values_at(1..2): the integers
          next [a] unless a.is_a?(Prism::RangeNode) && a.left.is_a?(Prism::IntegerNode) && a.right.is_a?(Prism::IntegerNode)
          (a.left.value..(a.exclude_end? ? a.right.value - 1 : a.right.value)).map { |k| a.left.copy(value: k) }
        end
        expr(n.copy(arguments: n.arguments.copy(arguments: expanded)))
      elsif %i[instance_variable_get instance_variable_set instance_variable_defined? instance_variables].include?(n.name) && (n.receiver ? (kd = kind_of(n.receiver)).is_a?(Symbol) && @classes[kd] : @klass && !@klass.closure)
        k = n.receiver ? @classes[kd] : @klass; rv = n.receiver ? expr(n.receiver) : me_val
        if n.name == :instance_variables && k.reflective # the table's names whose field holds something (nil = unset), claimed spares included
          k.ivars.each { sym_id(_1.to_s) }
          @reflective_tabs = (@reflective_tabs || {}).merge(k.name => true)
          tab = emit(:gget, [:"__IVTAB_#{k.name}"])
          outv = :"ivs#{@f.blocks.size}:out" # a loop-carried local: the loop's phis carry the grown array
          @locals[outv] = emit(:anew, [const(0), nil_const])
          n_pairs = emit(:call, [demand(:__ivtab_end), tab])
          counted_loop(const(2), n_pairs, :lt, [], [], step: 2) do |i, _ps, _pfx|
            ix = emit(:idx, [tab, emit(:add, [i, const(1)])])
            v = emit(:fld_get_i, [rv, ix]); v.ty = :dyn
            tb, eb, mb = @f.new_block(:ivset), @f.new_block(:ivunset), @f.new_block(:ivmerge)
            emit(:condbr, [emit(:cmp, [v, nil_const], :ne), tb, eb])
            before = @locals.dup
            @cur = tb; sc = emit(:idx, [tab, i]); sc = (c = emit(:nop, [sc]); c.ty = :sym; c); @locals[outv] = emit(:aset, [@locals[outv], emit(:alen, [@locals[outv]]), sc]); tl = @locals; emit(:br, [mb])
            @cur = eb; @locals = before.dup; emit(:br, [mb])
            @cur = mb; @locals = merge_locals(mb, [[tb, tl], [eb, before]])
          end
          return @locals.delete(outv)
        end
        if n.name == :instance_variables then pack_values(k.ivars.reject { _1.to_s.start_with?("@__") }.map { |iv| c = const(sym_id(iv.to_s)); c.ty = :sym; c })
        else
          literal = begin ct_symbol(args[0], @ct || {}) rescue nil end
          literal = nil if k.reflective && literal && !k.ivars.include?(:"@#{literal.to_s.delete_prefix("@")}") # a reflective class: an unknown literal name goes through the table (a spare slot), never a new field
          if literal.nil? && k.reflective # a run-time name: the class's table gives the field index
            nv = expr(args[0]); nv = emit(:call, [demand(:__str_to_sym), nv]) if kind_of(args[0]) == :str || args[0].is_a?(Prism::InterpolatedStringNode)
            k.ivars.each { sym_id(_1.to_s) } # every field name is a symbol the table knows
            @reflective_tabs = (@reflective_tabs || {}).merge(k.name => true)
            tab = emit(:gget, [:"__IVTAB_#{k.name}"])
            ix = emit(:call, [demand(:__ivtab_index), tab, nv])
            bad, ok, mb = @f.new_block(:ivbad), @f.new_block(:ivok), @f.new_block(:ivmerge)
            emit(:condbr, [emit(:cmp, [ix, const(0)], :lt), bad, ok])
            @cur = bad # a name the class has not seen: get -> nil, defined? -> false, set -> the next spare slot
            badv = case n.name
                   when :instance_variable_set
                     spare_base = k.ivars.index { _1.to_s.start_with?("@__spare") }
                     six = emit(:call, [demand(:__ivtab_claim), tab, nv, const(spare_base), const(Klass::SPARES)])
                     v0 = expr(args[1]); emit(:fld_set_i, [rv, six, v0]); v0
                   when :instance_variable_get then nil_const
                   else (c = const(0); c.ty = :bool; c) end
            badend = @cur; emit(:br, [mb])
            @cur = ok
            r = case n.name
                when :instance_variable_get then (g = emit(:fld_get_i, [rv, ix]); g.ty = :dyn; g)
                when :instance_variable_set then (v = expr(args[1]); emit(:fld_set_i, [rv, ix, v]); v)
                else emit(:cmp, [(g = emit(:fld_get_i, [rv, ix]); g.ty = :dyn; g), nil_const], :ne) end
            okend = @cur; emit(:br, [mb])
            @cur = mb; ph = mb.phi; ph.args = [[badend, badv], [okend, r]]
            return ph
          end
          iv = literal or raise("#{n.name}: the name must be known at compile time (a literal, or built from a class-level macro's parameter)")
          iv = :"@#{iv}" unless iv.to_s.start_with?("@")
          # a name the class has not seen yet (a setter lowered later, a macro's field): registered now; the field reads nil until set.
          # instance_variable_defined? is "the field is not nil" (an ivar assigned nil counts as undefined: an approximation)
          case n.name
          when :instance_variable_get then (k.ivars.include?(iv) || macro_field?(iv)) ? emit(:fld_get, [rv, k.ivar(iv)]) : nil_const
          when :instance_variable_set then (k.ivar(iv); v = expr(args[1]); emit(:fld_set, [rv, k.ivar(iv), v]); v)
          else
            if k.ivars.include?(iv) || macro_field?(iv) then emit(:cmp, [emit(:fld_get, [rv, k.ivar(iv)]), nil_const], :ne)
            else (c = const(0); c.ty = :bool; c) end
          end
        end
      elsif %i[instance_eval instance_exec].include?(n.name) && n.block.is_a?(Prism::BlockArgumentNode) && n.block.expression
        # obj.instance_eval(&blk): the block was compiled with self = obj's class (ie_target at its call site); field 0 of the closure takes obj
        rv = n.receiver ? expr(n.receiver) : me_val; bv = expr(n.block.expression)
        emit(:fld_set, [bv, 0, rv])
        emit(:mcall, [:call, bv, *args.map { expr(_1) }])
      elsif n.name == :extend && args.size == 1 && n.receiver && args[0].is_a?(Prism::ConstantReadNode) && @modules.include?(args[0].name) && !@singletons&.key?(n) && !(kind_of(n.receiver).is_a?(Symbol) && @classes[kind_of(n.receiver)])
        # expr.extend(M) on an Object with no class of ours (Object.new): only M.extended(obj) observes it
        rv = expr(n.receiver)
        (hook = @funcs[:"#{args[0].name}.extended"]) ? emit(:call, [hook, rv]) : rv
      elsif (sub = @singletons&.[](n)) # x.extend(M) / x.define_singleton_method: the object joins the hidden subclass
        rv = expr(n.receiver); emit(:retag, [rv, sub])
        if n.name == :extend # M.extended(obj) hooks
          n.arguments.arguments.each { |m| (hook = @funcs[:"#{m.name}.extended"]) && emit(:call, [hook, rv]) }
        end
        rv
      elsif n.name == :define_method && (d = @define_method_defs&.[](n)) # a run-time define_method site: the slot write
        expr(d)
      elsif %i[instance_eval instance_exec].include?(n.name) && n.receiver && n.block.is_a?(Prism::BlockNode) && (kd = kind_of(n.receiver)).is_a?(Symbol) && @classes[kd]
        # obj.instance_eval { body }: the block inlined with self = obj (ivars are obj's)
        rv = expr(n.receiver)
        saved_self, saved_k = @locals[:self], @klass
        @locals[:self] = rv; @klass = @classes[kd]
        params = n.block.parameters&.parameters&.requireds&.map(&:name) || []
        pfx = :"ie#{@f.blocks.size}:"
        @locals[:"#{pfx}#{params[0]}"] = rv if params[0]
        (n.arguments&.arguments || []).each_with_index { |a, k| @locals[:"#{pfx}#{params[k + (n.name == :instance_eval ? 1 : 0)]}"] = expr(a) if params[k + (n.name == :instance_eval ? 1 : 0)] }
        @blk_pfx = (@blk_pfx || []) << pfx
        r = (n.block.body&.body || []).map { expr(_1) }.last || nil_const
        @blk_pfx.pop; @locals.delete_if { |k, _| k.to_s.start_with?(pfx.to_s) }
        saved_self ? @locals[:self] = saved_self : @locals.delete(:self); @klass = saved_k
        r
      elsif n.name == :eval && n.receiver.nil? && args.size == 1 # eval "literal": the code, compiled here
        lit = literal_string(args[0]) or raise "eval of a computed string: the resident compiler for arbitrary code is not available yet (a literal string compiles in place)"
        Lower.normalize(Prism.parse(lit).value).statements.body.map { expr(_1) }.last || nil_const
      elsif n.name == :class_eval && n.receiver.is_a?(Prism::ConstantReadNode) && @classes[n.receiver.name]
        # a puncture: the methods this string defines can change at run time.
        # They are called through a slot from here on; nothing else changes.
        k = @classes[n.receiver.name]
        src = args[0]
        # a computed string: the code arrives at run time. Every method of the class becomes redefinable (a slot
        # each); the resident compiler parses, types and compiles the string's defs against the running program.
        k.methods.each_value { |m| m.patchable = true unless m.primary }
        raise "class_eval with a run-time string on #{k.name}, which has subclasses: not supported (new ivars would need room in every subclass)" if @classes.each_value.any? { _1.superclass.equal?(k) }
        k.reserve_spares # a new ivar named by the string takes a spare slot (dyn-typed)
        emit(:seam, [k, nil, expr(src)])
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
      elsif n.name == :chr && args.empty? && n.receiver && (kind_of(n.receiver) == :str || n.receiver.is_a?(Prism::StringNode)) then emit(:call, [demand(:__str_chr), expr(n.receiver)])
      elsif n.name == :chr && args.size == 1 && n.receiver then emit(:call, [demand(:__utf8_encode), expr(n.receiver)]) # n.chr("UTF-8") / n.chr(Encoding::UTF_8)
      elsif n.name == :chr && args.empty? && n.receiver then emit(:chr, [expr(n.receiver)])
      elsif n.name == :pass && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Thread then const(0) # no preemption: nothing to yield to
      elsif %i[lock synchronize sleep].include?(n.name) || n.receiver.is_a?(Prism::ConstantReadNode) && %i[Mutex Queue].include?(n.receiver.name)
        raise "#{n.name}: threads run to completion at Thread.new here; anything that would observe interleaving is not supported"
      elsif n.name == :delete && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :File
        emit(:call, [demand(:__file_delete), expr(args[0])])
      elsif n.name == :clock_gettime && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Process
        emit(:clock, [])                 # Process.clock_gettime(any clock): monotonic seconds as a Float
      elsif n.name == :round && args.empty? && n.receiver && (kind_of(n.receiver) == :float || n.receiver.is_a?(Prism::FloatNode) || n.receiver.is_a?(Prism::ParenthesesNode) && kind_of(n.receiver.body.body.last) == :float)
        emit(:call, [demand(:__float_round0), expr(n.receiver)])
      elsif %i[floor ceil].include?(n.name) && args.size == 1 && n.receiver && (kind_of(n.receiver) == :float || n.receiver.is_a?(Prism::FloatNode))
        emit(:call, [demand(n.name == :floor ? :__float_floor1 : :__float_ceil1), expr(n.receiver), expr(args[0])])
      elsif n.name == :divmod && args.size == 1 && n.receiver && (kind_of(n.receiver) == :float || n.receiver.is_a?(Prism::FloatNode) || kind_of(args[0]) == :float)
        emit(:call, [demand(:__float_divmod), expr(n.receiver), expr(args[0])])
      elsif n.name == :round && args.size == 1 && n.receiver
        if kind_of(n.receiver) == :int || n.receiver.is_a?(Prism::IntegerNode) || n.receiver.is_a?(Prism::ParenthesesNode) && n.receiver.body.body.last.is_a?(Prism::IntegerNode)
          emit(:call, [demand(:__num_round_int), expr(n.receiver), expr(args[0])]) # Integer#round(-n): tens, hundreds
        elsif args[0].is_a?(Prism::IntegerNode) && args[0].value == 0 # x.round(0) is an Integer in Ruby
          emit(:call, [demand(:__float_round0), expr(n.receiver)])
        elsif args[0].is_a?(Prism::IntegerNode) && args[0].value < 0 # x.round(-1): tens, an Integer
          emit(:call, [demand(:__float_round_neg), expr(n.receiver), expr(args[0])])
        else
          emit(:call, [demand(:__float_round), expr(n.receiver), expr(args[0])])
        end
      elsif n.name == :throw && n.receiver.nil? && args.size >= 1 # throw :tag, value
        exc = new_exception(:IndusThrow, [args[0], args[1] || Prism::NilNode.new(n.send(:source), 0, n.location, 0)])
        emit(:raise, [exc]); emit(:call, [demand(:__uncaught), exc]); nil_const
      elsif n.name == :raise && n.receiver.nil?
        # raise "m" -> RuntimeError.new("m"); raise K, "m" -> K.new("m"); raise obj -> obj
        exc = if args.empty? then new_exception(:RuntimeError, [])
              elsif args[0].is_a?(Prism::ConstantReadNode) && @classes[args[0].name] then new_exception(args[0].name, args[1..])
              elsif (k = kind_of(args[0])).is_a?(Symbol) && @classes[k] then expr(args[0]) # raise exc_object
              elsif k == :str || args[0].is_a?(Prism::StringNode) || args[0].is_a?(Prism::InterpolatedStringNode) then new_exception(:RuntimeError, [args[0]]) # raise "message"
              else expr(args[0]) end # raise x where x is a String or an exception object: decided by type (Types turns raise_any into raise of an object)
        if exc.op != :raise_any && !(args.size == 1 && !args[0].is_a?(Prism::ConstantReadNode) && !((k = kind_of(args[0])).is_a?(Symbol) && @classes[k]) && k != :str && !args[0].is_a?(Prism::StringNode) && !args[0].is_a?(Prism::InterpolatedStringNode))
          emit(:raise, [exc])
        else
          emit(:raise_any, [exc]) # Types wraps a String in RuntimeError, then it is a plain raise
        end
        emit(:call, [demand(:__uncaught), exc]) # rt_raise returns only when nothing catches (then exit)
        emit(:ret, [nil_const]) unless @cur.term # never reached (rt_raise does not return): what follows a raise is dead and contributes no type
        @cur = @f.new_block(:dead)
        return nil_const
      elsif %i[printf format sprintf].include?(n.name) && n.receiver.nil? && args[0]
        str = emit(:call, [demand(:__format), expr(args[0]), dyn_array(args[1..])])
        n.name == :printf ? emit(:print_v, [str]) : str

      elsif n.name == :split && args.empty? && n.receiver then emit(:mcall, [:split, expr(n.receiver), emit(:sconst, [" "])]) # split on whitespace
      elsif %i[sort! reverse! uniq! shuffle! compact! flatten!].include?(n.name) && args.empty? && n.receiver && !n.block # in place: compute, then write back into the same handle
        r = expr(n.receiver)
        emit(:call, [demand(:__arr_replace), r, emit(:mcall, [n.name.to_s.chomp("!").to_sym, r])])
      elsif n.name == :each_with_index && args.empty? && n.receiver && !n.block # arr.each_with_index.map { |x, i| }; a hash: its pairs, indexed
        base = kind_of(n.receiver) == :hash ? hash_pairs(expr(n.receiver)) : expr(n.receiver)
        emit(:mcall, [:each_with_index_pairs, base])
      elsif n.name == :with_index && args.size <= 1 && !n.block && n.receiver.is_a?(Prism::CallNode) && %i[each_char each map each_byte chars].include?(n.receiver.name) && n.receiver.block.nil? && n.receiver.receiver
        r = n.receiver # s.each_char.with_index.map { |c, i| }: the pairs
        base = case r.name when :each_char, :chars then emit(:mcall, [:chars, expr(r.receiver)]) when :each_byte then emit(:mcall, [:bytes, expr(r.receiver)]) else expr(r.receiver) end
        args[0] ? emit(:call, [demand(:__arr_each_with_index_pairs_from), base, expr(args[0])]) : emit(:mcall, [:each_with_index_pairs, base])
      elsif n.name == :times && args.empty? && n.receiver && !n.block then range_array(n)                 # 3.times.to_a
      elsif %i[upto downto].include?(n.name) && args.size == 1 && n.receiver && !n.block # 1.upto(3).to_a, 10.downto(7).to_a
        emit(:call, [demand(n.name == :upto ? :__num_upto_a : :__num_downto_a), expr(n.receiver), expr(args[0])])
      elsif n.name == :=== && args.size == 1 && (r = n.receiver.is_a?(Prism::ParenthesesNode) ? n.receiver.body.body.last : n.receiver).is_a?(Prism::RangeNode)
        expr(n.copy(name: :cover?)) # (1..10) === x
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
      elsif n.name == :to_a && args.empty? && (r = n.receiver.is_a?(Prism::ParenthesesNode) ? n.receiver.body.body.last : n.receiver).is_a?(Prism::RangeNode) && str_range?(r)
        range_array(r)
      elsif n.name == :to_a && args.empty? && (r = n.receiver.is_a?(Prism::ParenthesesNode) ? n.receiver.body.body.last : n.receiver).is_a?(Prism::RangeNode)
        lo = expr(r.left); hi = expr(r.right); hi = emit(:add, [hi, const(1)]) unless r.exclude_end?
        len = emit(:sub, [hi, lo]); arr = emit(:anew, [len, const(0)])
        outv = :"toa#{@f.blocks.size}:out"; @locals[outv] = arr
        counted_loop(const(0), len, :lt, [], []) { |i, _ps, _pfx| @locals[outv] = emit(:aset, [@locals[outv], i, emit(:add, [lo, i])]) }
        @locals.delete(outv)
      elsif n.name == :insert && args.size == 2 && (n.receiver.is_a?(Prism::LocalVariableReadNode) || n.receiver.is_a?(Prism::InstanceVariableReadNode) || n.receiver.is_a?(Prism::ArrayNode))
        r = emit(:call, [demand(:__arr_insert), expr(n.receiver), expr(args[0]), expr(args[1])]); r.routed = :insert # grows: rebind the home, as push does (Types reroutes a String to __str_insert)
        if n.receiver.is_a?(Prism::LocalVariableReadNode) then shared?(n.receiver.name) ? write_shared(n.receiver.name, r) : @locals[lname(n.receiver.name)] = r
        elsif n.receiver.is_a?(Prism::InstanceVariableReadNode) then emit(:fld_set, [me_val, @klass.ivar(n.receiver.name), r]) end
        r
      elsif n.name == :push && (n.receiver.is_a?(Prism::LocalVariableReadNode) || n.receiver.is_a?(Prism::InstanceVariableReadNode)) && !((k = kind_of(n.receiver)).is_a?(Symbol) && @classes[k])
        a = expr(n.receiver); v = expr(args[0]); len = emit(:alen, [a])
        r = emit(:aset, [a, len, v]) # may grow: rebind the home
        if n.receiver.is_a?(Prism::LocalVariableReadNode) then shared?(n.receiver.name) ? write_shared(n.receiver.name, r) : @locals[lname(n.receiver.name)] = r
        else emit(:fld_set, [me_val, @klass.ivar(n.receiver.name), r]) end
        r
      elsif n.name == :[] && n.receiver.is_a?(Prism::ConstantReadNode) && (sf = @funcs[:"#{n.receiver.name}.[]"]) # Klass[x]: the class method
        emit(:call, [sf, *call_args(sf, args)])
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
      elsif n.name == :new && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :String && args.size <= 1
        args.empty? ? emit(:sconst, [""]) : emit(:mcall, [:dup, expr(args[0])]) # String.new / String.new(s): a fresh mutable copy
      elsif n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :GC && %i[start compact stat count disable enable].include?(n.name)
        n.name == :start ? emit(:gc_now, []) : const(0) # GC.start: a collection now; the rest: no-ops
      elsif n.name == :new && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Hash
        emit(:hnew, []) # a default (value or block), if any, is recorded by the assignment (hash_default_of)
      elsif n.name == :[]=
        # a[i] = v may grow a: the result is the (possibly new) container, rebound to its home
        a = expr(n.receiver); i = expr(args[0]); v = expr(args[1])
        r = emit(:idx_set, [a, i, v])
        case n.receiver
        when Prism::LocalVariableReadNode then shared?(n.receiver.name) ? write_shared(n.receiver.name, r) : @locals[lname(n.receiver.name)] = r
        when Prism::InstanceVariableReadNode then emit(:fld_set, [me_val, @klass.ivar(n.receiver.name), r])
        when Prism::CallNode then nil # a[i][j] = v, obj.attr[i] = v: the element store is in place; growth would need the cell design
        when Prism::ConstantReadNode, Prism::GlobalVariableReadNode, Prism::ClassVariableReadNode then emit(:gset, [n.receiver.name, r]) # TABLE[k] = v: the global takes the grown handle
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
      elsif n.name == :new && n.receiver.nil? && @owner && (ok = @classes[@owner]) # `new` inside def self.x: this class
        obj = emit(:onew, [ok])
        (init = ok.find_method(:initialize)) && emit(:call, [init, obj, *method_args(init, args)])
        obj
      elsif @klass && n.receiver.nil? && @klass.find_method(n.name) # the class's own method shadows a top-level def of the same name
        me = @name_pfx ? @locals.fetch(:"#{@name_pfx}self") : @locals.fetch(:self)
        emit(:call, [@klass.find_method(n.name), me, *method_args(@klass.find_method(n.name), args, me)])
      elsif @klass && args.empty? && n.receiver.nil? && (iv = @klass.find_reader(n.name))
        if @classes.each_value.any? { |k| k.methods.key?(n.name) && (c = k.superclass; c = c.superclass while c && !c.equal?(@klass); c) } # a descendant overrides the reader with a def: dispatch
          emit(:mcall, [n.name, me_val])
        else emit(:fld_get, [me_val, @klass.ivar(iv)]) end # a bare attr_reader call inside a method
      elsif n.receiver.nil? && (y = @yielders[n.name]) && (y[0].nil? || @klass && (y[0].name == @klass.name)) # a yielding method called without a block: inlined, block_given? false
        inline_yielder(y, nil, args, nil, :none)
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
      given = {}; splats = []
      kw&.elements&.each { |el| el.is_a?(Prism::AssocSplatNode) ? splats << (el.value ? expr(el.value) : @locals.fetch(lname(:__kwrest))) : given[el.key.unescaped.to_sym] = el.value } # m(**h, k: v); m(**) forwards
      ps.keywords.each_with_index do |kp, k|
        idx = ps.requireds.size + ps.optionals.size + (ps.rest.is_a?(Prism::RestParameterNode) ? 1 : 0) + k
        if !given.key?(kp.name) && !splats.empty? # from the splatted hash at run time, else the default
          raise "**hash with several splats: not supported" if splats.size > 1
          key = (c = const(sym_id(kp.name.to_s)); c.ty = :sym; c)
          vals[idx] = if kp.respond_to?(:value) && kp.value then emit(:mcall, [:fetch, splats[0], key, with_default_self(pfx) { expr(kp.value) }])
                      else emit(:idx, [splats[0], key]) end
          @locals[:"#{pfx}#{kp.name}"] = vals[idx]
          next
        end
        node = given.fetch(kp.name) { kp.respond_to?(:value) && kp.value or raise "missing keyword #{kp.name} for #{f.name}" }
        vals[idx] = given.key?(kp.name) ? expr(node) : with_default_self(pfx) { expr(node) }
        @locals[:"#{pfx}#{kp.name}"] = vals[idx]
      end
      if ps.keyword_rest.is_a?(Prism::KeywordRestParameterNode) # **rest: the keywords no parameter names, as a symbol-keyed hash
        idx = ps.requireds.size + ps.optionals.size + (ps.rest.is_a?(Prism::RestParameterNode) ? 1 : 0) + ps.keywords.size
        named = ps.keywords.map(&:name)
        raise "**hash with several splats into **rest: not supported" if splats.size > 1
        h = splats.empty? ? emit(:hnew, []) : emit(:mcall, [:dup, splats[0]]) # m(**other): a copy of other's pairs (its type is other's)
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
      when :__handle then emit(:handle, [expr(args[0])]) # a container's address as an integer (raw memory below)
      when :__ld then emit(:rawld, [expr(args[0])])
      when :__ld32 then emit(:rawld32, [expr(args[0])])
      when :__ld8 then emit(:rawld8, [expr(args[0]), expr(args[1])])          # byte i of string s
      when :__byte_at then emit(:rawld8, [expr(args[0]), expr(args[1])])
      when :__st8 then (a = expr(args[0]); ix = expr(args[1]); v = expr(args[2]); emit(:rawst8, [a, ix, v]); v)
      when :__sdup then emit(:sdup, [expr(args[0])])
      when :__ascii_p then emit(:sascii, [expr(args[0])])   # every byte < 0x80 (eight bytes a step)
      when :__blen then emit(:alen, [expr(args[0])])        # the byte length, whatever the Types rule for .length
      when :__clen then emit(:sclen, [expr(args[0])])       # the UTF-8 character count
      when :__is_arr then emit(:is_arr, [expr(args[0])]) # folded by Types from the operand's type
      when :__to_dyn then emit(:todyn, [expr(args[0])])  # tag by the operand's type (Types fills it in)
      when :__is_sym then emit(:is_sym, [expr(args[0])]) # true when the value's static type is Symbol (Types folds it)
      when :__is_dyn then emit(:is_dyn, [expr(args[0])])
      when :__hcount then emit(:hcap, [expr(args[0])])                      # entries in insertion order: count, key i, value i
      when :__hkey_at then emit(:hkey_at, [expr(args[0]), expr(args[1])])
      when :__hval_at then emit(:hval_at, [expr(args[0]), expr(args[1])])
      when :__hkey_p then emit(:hkey, [expr(args[0]), expr(args[1])])
      when :__hset_raw then emit(:hset_raw, [expr(args[0]), expr(args[1]), expr(args[2])]) # store into a hash in its own representation (tagged key/value unboxed), no widening
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
      when :__munmap then emit(:rawmunmap, [expr(args[0]), expr(args[1])])
      when :__trap then emit(:trap, [])
      # unsigned / wrapping 64-bit arithmetic for the float printer
      when :__fbits then emit(:fbits, [expr(args[0])])
      when :__ffrom then emit(:ffrom, [expr(args[0])])
      when :__lsr then emit(:lsr, [expr(args[0]), expr(args[1])])
      when :__clz then emit(:clz, [expr(args[0])])
      when :__umulh then emit(:umulh, [expr(args[0]), expr(args[1])])
      when :__wmul then emit(:wmul, [expr(args[0]), expr(args[1])])
      when :__wadd then emit(:wadd, [expr(args[0]), expr(args[1])])
      when :__wshl then emit(:shl, [expr(args[0]), expr(args[1])]) # the shift wraps (lslv); the name says so at the call site
      when :__wsub then emit(:wsub, [expr(args[0]), expr(args[1])])
      when :__ult then emit(:ucmp, [expr(args[0]), expr(args[1])], :lo)
      when :__ule then emit(:ucmp, [expr(args[0]), expr(args[1])], :ls)
      when :__tag then emit(:dyn_tag, [expr(args[0])])                      # low 4 bits
      when :__same then emit(:ucmp, [expr(args[0]), expr(args[1])], :eq) # raw word identity, never rewritten
      when :__intern # append a name to the global symbol table, returning its id (the table may move on growth: write it back)
        names = emit(:gget, [:SYMBOL_NAMES]); n = emit(:alen, [names])
        grown = emit(:aset, [names, n, expr(args[0])]); emit(:gset, [:SYMBOL_NAMES, grown]); n
      when :__nil_str_value then (c = emit(:const, [0]); c.ty = :str; c) # the nil word, typed String
      when :__nil_str then emit(:ucmp, [expr(args[0]), (c = emit(:const, [0]); c.ty = :int; c)], :eq) # a String handle that is the nil word
      when :__box_int then emit(:box, [expr(args[0]), :int])
      when :__box_str then emit(:box, [expr(args[0]), :str])
      when :__box_arr then emit(:box, [expr(args[0]), [:arr, :dyn]])
      when :__box_hash then emit(:box, [expr(args[0]), [:hash, :dyn, :dyn]])
      when :__box_float then emit(:box, [expr(args[0]), :float])
      when :__unbox_int then emit(:unbox, [expr(args[0]), :int])
      when :__unbox_str then emit(:unbox, [expr(args[0]), :str])
      when :__unbox_arr then emit(:unbox, [expr(args[0]), [:arr, :dyn]])
      when :__unbox_float then emit(:unbox, [expr(args[0]), :float])
      when :__unbox_bool then emit(:unbox, [expr(args[0]), :bool])
      when :__sym_of_id then (c = emit(:nop, [expr(args[0])]); c.ty = :sym; c) # an integer id as a Symbol
      when :__sym_id then (c = emit(:nop, [expr(args[0])]); c.ty = :int; c)    # a Symbol's integer id
      when :__fld_get_i then (c = emit(:fld_get_i, [expr(args[0]), expr(args[1])]); c.ty = :dyn; c) # field at a run-time index (a reflective class: dyn fields)
      when :__fld_set_i then (v = expr(args[2]); emit(:fld_set_i, [expr(args[0]), expr(args[1]), v]); v)
      when :__unbox_obj_addr then emit(:xor, [emit(:handle, [expr(args[0])]), const(8)]) # an object's tag is 8: the raw word with the tag cleared
      when :__unbox_sym then emit(:unbox, [expr(args[0]), :sym])
      when :__unbox_hash then emit(:unbox, [expr(args[0]), [:hash, :dyn, :dyn]])
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
      # x.then { |v| body } / x.tap { |v| body }: the block inlined with v bound to x
      if %i[then yield_self].include?(n.name) && n.receiver && blk.is_a?(Prism::BlockArgumentNode) && blk.expression.is_a?(Prism::SymbolNode) && args.empty?
        return expr(Prism::CallNode.new(n.send(:source), 0, n.location, 0, n.receiver, nil, blk.expression.unescaped.to_sym, nil, nil, nil, nil, nil, nil)) # x.then(&:m) is x.m
      end
      if %i[then yield_self tap].include?(n.name) && n.receiver && blk.is_a?(Prism::BlockNode) && args.empty?
        v = expr(n.receiver)
        params = blk.parameters&.parameters&.requireds&.map(&:name) || []
        pfx = :"thn#{@f.blocks.size}:"
        @locals[:"#{pfx}#{params[0]}"] = v if params[0]
        @blk_pfx = (@blk_pfx || []) << pfx
        r = (blk.body&.body || []).map { expr(_1) }.last
        @blk_pfx.pop
        @locals.delete_if { |k, _| k.to_s.start_with?(pfx.to_s) }
        return n.name == :tap ? v : (r || v)
      end
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
      if n.name == :catch && n.receiver.nil? && blk.is_a?(Prism::BlockNode) && args.size == 1 # catch(:tag) { }: a begin rescuing the throw of that tag
        tmpl = Prism.parse("tag__ = nil\nbegin\nrescue IndusThrow => thr__\n  raise thr__ unless thr__.tag == tag__\n  thr__.value\nend").value.statements.body[1]
        rc = tmpl.rescue_clause
        @locals[lname(:tag__)] = expr(args[0])
        return begin_expr(nil, stmts: blk.body&.body || [], rescues: [[[:IndusThrow], rc.reference, rc.statements.body]], ensure_body: [])
      end
      if n.name == :loop && n.receiver.nil? && blk.is_a?(Prism::BlockNode) # loop { }: while true, ended by break (or a raise)
        hb, bb, xb = @f.new_block(:head), @f.new_block(:body), @f.new_block(:exit)
        xb.cold = true
        assigned_locals_plain(blk.body&.body || []).uniq.each { |nm| @locals[lname(nm)] ||= nil_const }
        pre = @cur; emit(:br, [hb])
        phis = @locals.to_h { |nm, v| ph = hb.phi; ph.args << [pre, v]; [nm, ph] }
        @locals = phis.dup; @cur = hb
        one = const(1); one.ty = :bool
        emit(:condbr, [one, bb, xb]) # `loop` runs until a break: the exit edge keeps the block reachable for layout
        @cur = bb
        outer, @loop = @loop, { exit: xb, breaks: [], head: hb, nexts: [] }
        (blk.body&.body || []).each { expr(_1) }
        bend = @cur
        emit(:br, [hb]) unless @cur.term
        phis.each { |nm, ph| ph.args << [bend, @locals[nm]] unless bend.term && bend.succs.empty? }
        @loop[:nexts].each { |(b, l)| phis.each { |nm, ph| ph.args << [b, l.fetch(nm)] } }
        breaks = @loop[:breaks]; bvals = @loop[:break_values] || []; @loop = outer
        @cur = xb
        @locals = breaks.empty? ? phis.dup : merge_locals(xb, breaks)
        return break_result(xb, breaks, bvals, nil)
      end
      # s.gsub(/re/) { |m| ... }: the block as a closure value, called per match
      if n.receiver && blk.is_a?(Prism::BlockNode) && %i[gsub sub].include?(n.name) && args.size == 1 && (args[0].is_a?(Prism::RegularExpressionNode) || args[0].is_a?(Prism::StringNode))
        params = blk.parameters&.parameters&.requireds&.map(&:name) || []
        c = closure_value(params, free_locals(blk.body, params).select { |nm| @locals.key?(lname(nm)) }, blk.body&.body || [])
        if args[0].is_a?(Prism::StringNode) # a literal pattern: the same matcher over an escaped regexp
          re = regexp_value(Prism::RegularExpressionNode.new(args[0].send(:source), 0, args[0].location, 0, args[0].location, args[0].location, args[0].location, Regexp.escape(args[0].unescaped)))
          return emit(:call, [demand(n.name == :gsub ? :__str_gsub_blk_re : :__str_sub_blk_re), expr(n.receiver), re, c])
        end
        return emit(:call, [demand(n.name == :gsub ? :__str_gsub_blk_re : :__str_sub_blk_re), expr(n.receiver), expr(args[0]), c])
      end
      # s.each_char { |c| } / s.each_byte / s.each_line: iterate the string's pieces as an array
      if n.receiver && blk.is_a?(Prism::BlockNode) && %i[each_char each_byte each_line].include?(n.name) && !@recv_value && kind_of(n.receiver) != :array
        pieces = { each_char: :chars, each_byte: :bytes, each_line: :lines }[n.name]
        return iterate_array_value(n.copy(name: :each), args, emit(:mcall, [pieces, expr(n.receiver)]))
      end
      # h.fetch(k) { default }: the block runs only on a miss
      if n.receiver && blk.is_a?(Prism::BlockNode) && n.name == :fetch && args.size == 1 && blk.parameters.nil?
        h = expr(n.receiver); k = expr(args[0])
        has = emit(:mcall, [:key?, h, k])
        tb, eb, mb = @f.new_block(:fhit), @f.new_block(:fmiss), @f.new_block(:fmerge)
        emit(:condbr, [has, tb, eb])
        @cur = tb; hit = emit(:idx, [h, k]); tend = @cur; emit(:br, [mb])
        @cur = eb; before = @locals.dup
        miss = run_body(blk.body&.body || [], nil) || nil_const
        mend = @cur
        reaches = !@cur.term
        emit(:br, [mb]) if reaches
        @cur = mb
        arms = [[tend, before]] + (reaches ? [[mend, @locals]] : [])
        @locals = merge_locals(mb, arms)
        ph = mb.phi; ph.args = [[tend, hit]] + (reaches ? [[mend, miss]] : [])
        return ph
      end
      # block methods defined by a map over the receiver plus a prelude pass on the results
      # (a mask of truths, or the mapped values): one lowering each, no new loop kinds
      if n.receiver && blk.is_a?(Prism::BlockNode) && !%i[each map].include?(n.name) && !(kind_of(n.receiver) == :hash && !@recv_value) # hashes: the pair-iteration block below
        mapped = ->(recv_node = n.receiver) { iterate_array_value(n.copy(name: :map), args, @recv_value || expr(recv_node)) }
        case n.name
        when :filter_map then return emit(:call, [demand(:__arr_compact), mapped.()])
        when :take_while, :drop_while, :index, :find_index, :one?
          arr = @recv_value || expr(n.receiver)
          mask = iterate_array_value(n.copy(name: :map), args, arr)
          return emit(:call, [demand(:"__arr_#{n.name.to_s.delete('?')}_mask"), arr, mask])
        when :delete_if
          arr = @recv_value || expr(n.receiver)
          kept = iterate_array_value(n.copy(name: :reject), args, arr)
          return emit(:call, [demand(:__arr_replace), arr, kept])
        when :chunk_while, :slice_when
          arr = @recv_value || expr(n.receiver)
          pairs = emit(:call, [demand(:__arr_each_cons1), arr, const(2)])
          mask = iterate_array_value(n.copy(name: :map), args, pairs)
          return emit(:call, [demand(:"__arr_#{n.name}_mask"), arr, mask])
        when :to_h then return emit(:call, [demand(:__pairs_to_hash), mapped.()]) if kind_of(n.receiver) != :hash
        when :sort # a comparator: the block as a closure value, the prelude merge sort calls it
          params = blk.parameters&.parameters&.requireds&.map(&:name) || []
          c = closure_value(params, free_locals(blk.body, params).select { |nm| @locals.key?(lname(nm)) }, blk.body&.body || [])
          return emit(:call, [demand(:__arr_sort_cmp), @recv_value || expr(n.receiver), c])
        when :with_index, :each_with_index # xs.map.with_index { |x, i| }, xs.each_char.with_index { }, xs.each.with_index { }
          r = n.receiver
          if r.is_a?(Prism::CallNode) && %i[map each each_char each_byte select reject].include?(r.name) && r.block.nil? && r.arguments.nil? && r.receiver
            base = case r.name
                   when :each_char then emit(:mcall, [:chars, expr(r.receiver)])
                   when :each_byte then emit(:mcall, [:bytes, expr(r.receiver)])
                   else expr(r.receiver) end
            pairs = args[0] ? emit(:call, [demand(:__arr_each_with_index_pairs_from), base, expr(args[0])]) : emit(:mcall, [:each_with_index_pairs, base]) # with_index(1)
            return iterate_array_value(n.copy(name: r.name == :map ? :map : r.name == :each || r.name == :each_char || r.name == :each_byte ? :each : r.name), [], pairs)
          end
        end
      end
      # a hash with a |k, v| block: iterate its pairs as an array; what yields a selection of
      # pairs comes back as a hash, what yields a value stays a value
      if n.receiver && !@recv_value && (kind_of(n.receiver) == :hash || %i[each_key each_value each_pair transform_values transform_keys].include?(n.name)) && blk
        case n.name
        when :select, :filter, :reject, :find_all, :filter!, :select!, :reject!, :keep_if, :delete_if
          r = n.copy(name: %i[reject reject! delete_if].include?(n.name) ? :reject : :select)
          res = emit(:call, [demand(:__pairs_to_hash), iterate_array_value(r, args, hash_pairs(expr(n.receiver)))])
          return res unless n.name.to_s.end_with?("!") || %i[keep_if delete_if].include?(n.name)
          return emit(:call, [demand(:__hash_replace), expr(n.receiver), res]) # in place: rebuild the receiver's slots from the result
        when :merge # h.merge(o) { |key, old, new| }: the block decides on a clash
          o = expr(args[0])
          params = blk.parameters&.parameters&.requireds&.map(&:name) || []
          c = closure_value(params, free_locals(blk.body, params).select { |nm| @locals.key?(lname(nm)) }, blk.body&.body || [])
          return emit(:call, [demand(:__hash_merge_blk), expr(n.receiver), o, c])
        when :fetch # h.fetch(k) { |k| default }
          params = blk.parameters&.parameters&.requireds&.map(&:name) || []
          c = closure_value(params, free_locals(blk.body, params).select { |nm| @locals.key?(lname(nm)) }, blk.body&.body || [])
          return emit(:call, [demand(:__hash_fetch_blk), expr(n.receiver), expr(args[0]), c])
        when :each_key then return iterate_array_value(n.copy(name: :each), args, emit(:hkeys, [expr(n.receiver)]))
        when :each_value then return iterate_array_value(n.copy(name: :each), args, emit(:call, [demand(:__hash_values), expr(n.receiver)]))
        when :sum, :count, :find, :detect, :any?, :all?, :none?, :group_by, :min_by, :max_by, :partition, :each_with_object, :flat_map, :each_with_index, :reduce, :inject, :filter_map
          return iterate_array_value(n, args, hash_pairs(expr(n.receiver)))
        when :to_h # h.to_h { |k, v| [k2, v2] }
          return emit(:call, [demand(:__pairs_to_hash), iterate_array_value(n.copy(name: :map), args, hash_pairs(expr(n.receiver)))])
        when :transform_values
          h = expr(n.receiver)
          vals = iterate_array_value(n.copy(name: :map), args, emit(:call, [demand(:__hash_values), h]))
          return emit(:call, [demand(:__hash_rekey), emit(:hkeys, [h]), vals])
        when :transform_keys
          h = expr(n.receiver)
          keys = iterate_array_value(n.copy(name: :map), args, emit(:hkeys, [h]))
          return emit(:call, [demand(:__hash_rekey), keys, emit(:call, [demand(:__hash_values), h])])
        end
      end
      if blk.is_a?(Prism::BlockArgumentNode) # m(&:sym) is m { |e| e.sym }
        sym = blk.expression.unescaped.to_sym
        params = [:__e]
        body = ->(pfx) { call_on_value(sym, @locals.fetch(:"#{pfx}__e")) }
      else
        params = case blk.parameters
                 when Prism::NumberedParametersNode then (1..blk.parameters.maximum).map { :"_#{_1}" }
                 when nil then []
                 else block_param_shapes(blk.parameters.parameters) # |a, (b, c), *rest|: names, nested names, [:rest, name]
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
          fparams, pre = flatten_params(blk.parameters&.parameters) # |a, (b, c)|
          fparams = params if blk.parameters.is_a?(Prism::NumberedParametersNode) || blk.parameters.nil?
          return closure_value(fparams, free_locals(blk.body, fparams).select { |nm| @locals.key?(lname(nm)) }, pre + (body.is_a?(Array) ? body : []))
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
          if ps[1].is_a?(Array) then el = emit(:aget, [arr, i]); ps[1].each_with_index { |pn, k| @locals[:"#{pfx}#{pn}"] = emit(:idx, [el, const(k)]) } # |m, (k, v)|
          elsif ps[1] then @locals[:"#{pfx}#{ps[1]}"] = emit(:aget, [arr, i]) end
          @fold_target = accv
        end
        return @locals.delete(accv)
      when :any?, :all?, :none?, :find, :detect, :find_index, :count_if # one boolean / one element out of a pass
        arr = recv_val(recv)
        resv = :"pred#{@f.blocks.size}:v"
        @locals[resv] = case n.name when :all? then const(1) when :any?, :none? then const(0) when :find, :detect then (c = const(0); c.ty = :nil; c) else const(-1) end
        len = emit(:alen, [arr])
        counted_loop(const(0), len, :lt, params, body) do |i, ps, pfx|
          bind_elem(ps, pfx, emit(:aget, [arr, i]))
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
          bind_elem(ps, pfx, emit(:aget, [arr, i]))
          @group_target = [hv, emit(:aget, [arr, i])]
        end
        return @locals.delete(hv)
      when :partition # [accepted, rejected]
        arr = recv_val(recv)
        yes = :"part#{@f.blocks.size}:y"; no = :"part#{@f.blocks.size}:n"
        @locals[yes] = emit(:anew, [const(0), (c = const(0); c.ty = :nil; c)]); @locals[no] = emit(:anew, [const(0), (c = const(0); c.ty = :nil; c)])
        len = emit(:alen, [arr])
        counted_loop(const(0), len, :lt, params, body) do |i, ps, pfx|
          bind_elem(ps, pfx, emit(:aget, [arr, i]))
          @partition_target = [yes, no, emit(:aget, [arr, i])]
        end
        pair = emit(:anew, [const(2), (c = const(0); c.ty = :nil; c)])
        pair = emit(:aset, [pair, const(0), @locals.delete(yes)]); emit(:aset, [pair, const(1), @locals.delete(no)])
      when :each_with_object # the memo is the block's second argument and the result
        arr = recv_val(recv); memo = expr(args[0])
        if hash_new_with_default?(args[0]) && params[1] # Hash.new(0) as the memo: the default follows the block's name for it
          (@hash_defaults ||= {})[:"#{:"blk#{@f.blocks.size}:"}#{params[1]}"] = args[0].arguments.arguments[0]
          (@hash_defaults ||= {})[params[1]] = args[0].arguments.arguments[0]
        end
        mv = :"ewo#{@f.blocks.size}:m"; @locals[mv] = memo
        len = emit(:alen, [arr])
        counted_loop(const(0), len, :lt, params, body) do |i, ps, pfx|
          bind_elem([ps[0]], pfx, emit(:aget, [arr, i])) # |elem, memo|: only the first is the element
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
          bind_elem(ps, pfx, emit(:aget, [arr, i]))
          @flat_target = outv
        end
        return @locals.delete(outv)
      when :select, :reject, :filter # the elements the body accepts
        arr = recv_val(recv)
        outv = :"sel#{@f.blocks.size}:out"
        @locals[outv] = emit(:anew, [const(0), (c = const(0); c.ty = :nil; c)])
        len = emit(:alen, [arr])
        counted_loop(const(0), len, :lt, params, body) do |i, ps, pfx|
          bind_elem(ps, pfx, emit(:aget, [arr, i]))
          @select_target = [outv, emit(:aget, [arr, i]), n.name == :reject]
        end
        return @locals.delete(outv)
      when :sum, :count # accumulate the block's value / truthiness
        accv = :"acc#{@f.blocks.size}:v"
        @locals[accv] = const(0)
        r = recv.is_a?(Prism::ParenthesesNode) ? recv.body.body.last : recv
        iter = ->(i, ps, pfx) { @locals[:"#{pfx}#{ps[0]}"] = i if ps[0]; @sum_target = [accv, n.name] }
        if r.is_a?(Prism::RangeNode) && !str_range?(r)
          counted_loop(expr(r.left), expr(r.right), r.exclude_end? ? :lt : :le, params, body, &iter)
        else
          arr = recv_val(recv); len = emit(:alen, [arr])
          counted_loop(const(0), len, :lt, params, body) { |i, ps, pfx| bind_elem(ps, pfx, emit(:aget, [arr, i])); @sum_target = [accv, n.name] }
        end
        return @locals.delete(accv)
      when :each, :map, :each_with_index, :each_pair
        r = recv.is_a?(Prism::ParenthesesNode) ? recv.body.body.last : recv
        if @recv_value then return array_loop(@recv_value, n.name == :each_pair ? :each : n.name, params, body) end
        return iterate_array_value(n, args, range_array(r)) if str_range?(r)
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
    def counted_loop(from, to, cond, params, body, step: 1, &each)
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
          found = kind == :find_index ? emit(:cmp, [@locals[resv], const(-1)], :ne) : emit(:cmp, [@locals[resv], (c = const(0); c.ty = :nil; c)], :ne) # nil typed: the sentinel of whatever the result becomes
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
      @locals[ivar] = emit(:add, [@locals[ivar], const(step)])
      emit(:br, [hb])
      phis.each { |nm, ph| ph.args << [lb, @locals.fetch(nm)] }
      breaks = @loop[:breaks]; bvals = @loop[:break_values] || []; @loop = outer
      @cur = xb
      @locals = breaks.empty? ? phis.dup : merge_locals(xb, [[hb, phis.dup], *breaks])
      @locals.delete_if { |k, _| k.to_s.start_with?(pfx.to_s) }
      break_result(xb, breaks, bvals, hb)
    end

    # the value of a loop that `break v` may leave: v from a break site, nil from the normal exit.
    # Without break values: const 0 (callers substitute the construct's own result)
    def break_result(xb, breaks, bvals, normal_pred)
      return const(0) if bvals.empty?
      arms = []
      arms << [normal_pred, nil_const] if normal_pred
      vals = bvals.to_h
      breaks.each { |(b, _)| arms << [b, vals[b] || nil_const] }
      p = xb.phi; p.args = arms; p
    end

    # h.each { |k, v| }: the i-th inserted entry, for i < count (Ruby's insertion order)
    def hash_each(h, params, body, map = false)
      cap = emit(:hcap, [h])
      outv = :"hmap#{@f.blocks.size}:out"
      @locals[outv] = emit(:anew, [cap, (c = const(0); c.ty = :nil; c)]) if map
      counted_loop(const(0), cap, :lt, [], body) do |i, _ps, pfx|
        key = emit(:hkey_at, [h, i]); val = emit(:hval_at, [h, i])
        if params.size == 1 && params[0] # { |pair| }: the [key, value] pair (a fresh two-element array)
          pair = emit(:anew, [const(2), (c = const(0); c.ty = :nil; c)])
          pair = emit(:aset, [pair, const(0), key]); pair = emit(:aset, [pair, const(1), val])
          @locals[:"#{pfx}#{params[0]}"] = pair
        else
          @locals[:"#{pfx}#{params[0]}"] = key if params[0]
          @locals[:"#{pfx}#{params[1]}"] = val if params[1]
        end
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

    # the block's element parameter(s): |x|, or |k, v| destructuring a pair
    # the builtin a node certainly is: by literal shape, or by the pre-typing's kind
    def builtin_kind(node) # by literal shape only: a variable's kind is a guess here, Types decides it
      BUILTIN_CLASS_NODE.each { |k, nodes| return k if nodes.any? { node.is_a?(_1) } }
      nil
    end

    def bind_elem(ps, pfx, el)
      if ps.size == 1 && ps[0].is_a?(Array) # |(a, b)| over an array of pairs: destructure the element
        ps[0].each_with_index { |pn, k| @locals[:"#{pfx}#{pn}"] = emit(:idx, [el, const(k)]) }
        return
      end
      return if ps.empty?
      if ps.size >= 2 # |(a, b), x| : the k-th parameter takes el[k]; a nested list destructures that element; |a, *r| takes the rest
        if (et = kind_of_value(el)) != :array && !(el.ty.nil? && el.op == :aget) && el.ty && el.ty != :dyn # a scalar element with several parameters: the first takes it, the rest are nil
          @locals[:"#{pfx}#{ps[0]}"] = el if ps[0].is_a?(Symbol)
          ps[1..].each { |pn| @locals[:"#{pfx}#{pn.is_a?(Array) ? pn[1] : pn}"] = pn.is_a?(Array) && pn[0] == :rest ? pack_values([]) : nil_const }
          return
        end
        ps.each_with_index do |pn, k|
          if pn.is_a?(Array) && pn[0] == :rest then @locals[:"#{pfx}#{pn[1]}"] = emit(:mcall, [:drop, el, const(k)])
          elsif pn.is_a?(Array) && pn[0] == :opt then @locals[:"#{pfx}#{pn[1]}"] = emit(:idx, [el, const(k)])
          elsif pn.is_a?(Array) then sub = emit(:idx, [el, const(k)]); pn.each_with_index { |nm, j| @locals[:"#{pfx}#{nm}"] = emit(:idx, [sub, const(j)]) }
          else @locals[:"#{pfx}#{pn}"] = (ix = emit(:idx, [el, const(k)]); ix.destructure = true; ix) end
        end
      else @locals[:"#{pfx}#{ps[0].is_a?(Array) ? ps[0][1] : ps[0]}"] = ps[0].is_a?(Array) && ps[0][0] == :rest ? pack_values([el]) : el end
    end

    def array_loop(arr, kind, params, body)
      len = emit(:alen, [arr])
      out = (emit(:anew, [len, (c = const(0); c.ty = :nil; c)])) if kind == :map
      outv = :"map#{@f.blocks.size}:out"
      @locals[outv] = out if out
      counted_loop(const(0), len, :lt, params, body) do |i, ps, pfx|
        el = emit(:aget, [arr, i])
        if kind == :each_with_index
          bind_elem([ps[0]], pfx, el)
          @locals[:"#{pfx}#{ps[1]}"] = i if ps[1]
        else
          bind_elem(ps, pfx, el)
        end
        if kind == :map
          # the body's value is stored at the latch: wrap body so its last value is captured
          @map_target = [outv, i]
        end
      end.then do |r|
        if out
          res = @locals.delete(outv); res
        elsif r.op == :phi then r # a `break v` left the loop with v
        else kind == :each ? arr : r end
      end
    end

    def inline_yielder((klass, d), recv, args, params, body)
      pfx = :"inl#{@f.blocks.size}:"
      me = recv ? expr(recv) : @locals[:self]
      callee_locals = me ? { :"#{pfx}self" => me } : {} # top-level yielders have no self
      (d.parameters&.requireds || []).each_with_index { |p, k| callee_locals[:"#{pfx}#{p.name}"] = expr(args[k]) }
      saved = [@block, @klass, @inl, @ret_exit]
      @block = body == :none ? :none : [params, body]
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
    # a closure's required parameters as flat names; a destructuring |(b, c)| becomes a hidden name plus a
    # `b, c = hidden` statement to run first
    def flatten_params(ps)
      return [[], []] unless ps
      names = []; pre = []
      ps.requireds.each_with_index do |r, k|
        if r.respond_to?(:name) then names << r.name
        else
          hidden = :"__d#{k}_#{@lambda_count || 0}"; names << hidden
          src = r.send(:source); loc = r.location
          pre << Prism::MultiWriteNode.new(src, 0, loc, 0, r.lefts, r.rest, r.rights, nil, nil, loc, Prism::LocalVariableReadNode.new(src, 0, loc, 0, hidden, 0))
        end
      end
      # optionals: a parameter the caller may omit (nil then, by the proc arity rule) -> `b = default if b.nil?`
      ps.optionals.each do |o|
        names << o.name
        src = o.send(:source); loc = o.location
        rd = Prism::LocalVariableReadNode.new(src, 0, loc, 0, o.name, 0)
        isnil = Prism::CallNode.new(src, 0, loc, 0, rd, nil, :nil?, loc, nil, nil, nil, nil, nil)
        asg = Prism::LocalVariableWriteNode.new(src, 0, loc, 0, o.name, 0, loc, o.value, loc)
        pre << Prism::IfNode.new(src, 0, loc, 0, loc, isnil, nil, Prism::StatementsNode.new(src, 0, loc, 0, [asg]), nil, loc)
      end
      # keywords with defaults: bound to the default (a closure value cannot receive keywords yet; its inlined calls can)
      ps.keywords.each do |kp|
        raise "a lambda value with a required keyword #{kp.name}: not supported" unless kp.respond_to?(:value) && kp.value
        src = kp.send(:source); loc = kp.location
        pre << Prism::LocalVariableWriteNode.new(src, 0, loc, 0, kp.name, 0, loc, kp.value, loc)
      end
      names << [:rest, ps.rest.name || :__rest] if ps.rest.is_a?(Prism::RestParameterNode) # extras gathered by the caller (proc arity)
      [names, pre]
    end

    # a block's parameter shapes: a name, [names] for |(a, b)| destructuring, [:rest, name] for |*rest|, [:opt, name, default node]
    def block_param_shapes(ps)
      out = ps.requireds.map { |r| r.respond_to?(:name) ? r.name : r.lefts.map { |l| l.respond_to?(:name) ? l.name : l.lefts.map(&:name) } }
      out += ps.optionals.map { |o| [:opt, o.name, o.value] }
      out << [:rest, ps.rest.name || :__rest] if ps.rest.is_a?(Prism::RestParameterNode)
      out += ps.posts.map(&:name) if ps.respond_to?(:posts) && ps.posts
      out
    end

    # bind a block's parameters to the yielded values (proc semantics: missing -> nil, extras dropped, one array auto-splats)
    def bind_block_params(params, vals, pfx)
      plain = params.reject { _1.is_a?(Array) && _1[0] == :rest }
      if vals.size == 1 && plain.size > 1 && (kind_of_value(vals[0]) == :array) # |a, b| given one array: destructured
        a = vals[0]; vals = plain.each_index.map { |k| emit(:idx, [a, const(k)]) }
      end
      k = 0
      params.each do |p|
        case p
        when Symbol then @locals[:"#{pfx}#{p}"] = vals[k] || nil_const; k += 1
        when Array
          case p[0]
          when :rest
            rest = vals[k..] || []
            @locals[:"#{pfx}#{p[1]}"] = pack_values(rest); k += rest.size
          when :opt then @locals[:"#{pfx}#{p[1]}"] = vals[k] || expr(p[2]); k += 1
          else # nested destructuring: |(b, c)|
            v = vals[k] || nil_const; k += 1
            p.each_with_index { |nm, j| @locals[:"#{pfx}#{nm}"] = emit(:idx, [v, const(j)]) if nm.is_a?(Symbol) }
          end
        end
      end
    end
    def kind_of_value(v) = (v.ty.is_a?(Array) && v.ty[0] == :arr) || v.op == :anew || v.op == :aset ? :array : nil

    def yield_block(arg_nodes)
      params, body = @block
      vals = arg_nodes.map { expr(_1) }           # still in callee naming
      bpfx = :"y#{@f.blocks.size}:"
      saved_pfx, @name_pfx = @name_pfx, nil
      saved_ret, @ret_exit = @ret_exit, nil        # a `return` in the block would return from the caller: unsupported
      bind_block_params(params, vals, bpfx)
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
      tv = (n.statements&.body || []).map { expr(_1) }.last || nil_const # an empty arm is nil
      unnarrow(tfacts, before)
      tend, tlocals = @cur, @locals; emit(:br, [mb]) unless @cur.term

      @cur = eb; @locals = before.dup; narrow(efacts)
      sub = n.is_a?(Prism::UnlessNode) ? n.else_clause : n.subsequent
      ev = case sub
           when Prism::IfNode then if_expr(sub)
           when Prism::ElseNode then sub.statements&.body&.map { expr(_1) }&.last
           end || nil_const # no else: the if is nil when the condition fails
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

    # defined?(x): decided at compile time wherever the answer is static
    def defined_expr(v)
      str = ->(s) { s ? emit(:sconst, [s]) : nil_const }
      case v
      when Prism::LocalVariableReadNode then str.(@locals.key?(lname(v.name)) ? "local-variable" : nil)
      when Prism::InstanceVariableReadNode # set iff assigned (a never-written field reads as its zero: nil / 0 / false all count as unset)
        cur = if (ow = ivar_owner) then emit(:gget, [:"#{ow}#{v.name}"])
              elsif @klass&.ivars&.include?(v.name) then emit(:fld_get, [me_val, @klass.ivar(v.name)])
              else return str.(nil) end
        or_value(and_value(emit(:cmp, [cur, const(0)], :ne)) { emit(:sconst, ["instance-variable"]) }) { nil_const }
      when Prism::GlobalVariableReadNode then str.("global-variable")
      when Prism::ConstantReadNode then str.(@classes[v.name] || @modules.include?(v.name) || @class_const_owners&.key?(v.name) || %i[Integer Float String Array Hash Symbol NilClass Comparable Kernel Object Math].include?(v.name) ? "constant" : nil)
      when Prism::ConstantPathNode then str.("constant")
      when Prism::CallNode
        if v.receiver.nil? && v.arguments.nil?
          known = @funcs.key?(v.name) || @yielders.key?(v.name) || (@klass && (@klass.find_method(v.name) || @klass.find_reader(v.name))) || %i[puts p print require require_relative raise loop lambda proc format sprintf rand gets].include?(v.name)
          str.(known ? "method" : nil)
        elsif v.receiver && (kd = kind_of(v.receiver)).is_a?(Symbol) && @classes[kd]
          k = @classes[kd]; str.(k.find_method(v.name) || k.find_reader(v.name) || k.find_writer(v.name) ? "method" : nil)
        else str.("method") end # a builtin receiver: assume it responds (the compile would otherwise have refused)
      when Prism::YieldNode then @block == :none ? str.(nil) : (@block ? str.("yield") : (@block_param && @locals[@block_param] ? or_value(and_value(emit(:cmp, [@locals[@block_param], nil_const], :ne)) { emit(:sconst, ["yield"]) }) { nil_const } : str.(nil)))
      when Prism::SuperNode, Prism::ForwardingSuperNode then str.("super")
      when Prism::SelfNode then str.("self")
      when Prism::NilNode then str.("expression")
      when Prism::TrueNode, Prism::FalseNode then str.("expression")
      when Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::InstanceVariableWriteNode, Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::IndexOperatorWriteNode, Prism::GlobalVariableWriteNode, Prism::MultiWriteNode then str.("assignment")
      else str.("expression")
      end
    end

    def class_const?(c) = c.is_a?(Prism::ConstantReadNode) && (@classes[c.name] || %i[Integer Float String Array Hash Symbol].include?(c.name))

    # case/in: each arm is a chain of tests that branch to the next arm on failure; bindings happen as
    # the tests pass (a failed arm restores the locals), the guard runs after the bindings
    def case_match_expr(n)
      subj = expr(n.predicate)
      mb = @f.new_block(:pmerge)
      arms = []
      before = @locals.dup
      n.conditions.each do |inn|
        fail_b = @f.new_block(:pnext)
        @locals = before.dup
        pat = inn.pattern
        guard = nil
        if pat.is_a?(Prism::IfNode) then guard = pat.predicate; pat = pat.statements.body[0]
        elsif pat.is_a?(Prism::UnlessNode) then guard = [:not, pat.predicate]; pat = pat.statements.body[0] end
        pattern_match(pat, subj, fail_b, n.predicate)
        if guard
          g = guard.is_a?(Array) ? emit(:cmp, [expr(guard[1]), const(0)], :eq) : expr(guard)
          ok = @f.new_block(:pguard); emit(:condbr, [g, ok, fail_b]); @cur = ok
        end
        v = (inn.statements&.body || []).map { expr(_1) }.last || nil_const
        arms << [@cur, @locals, v] unless @cur.term
        emit(:br, [mb]) unless @cur.term
        @cur = fail_b
      end
      @locals = before.dup
      ev = if n.else_clause then (n.else_clause.statements&.body || []).map { expr(_1) }.last || nil_const
           else emit(:trap, []); nil_const end # NoMatchingPatternError
      arms << [@cur, @locals, ev] unless @cur.term
      emit(:br, [mb]) unless @cur.term
      @cur = mb
      @locals = merge_locals(mb, arms.map { |(b, l, _)| [b, l] })
      ph = mb.phi; ph.args = arms.map { |(b, _, v)| [b, v] }; ph
    end

    # emit the tests for `pat` against value v; on failure branch to fail_b; fall through on success
    def pattern_match(pat, v, fail_b, vnode = nil)
      check = ->(cond) { ok = @f.new_block(:pok); emit(:condbr, [cond, ok, fail_b]); @cur = ok }
      case pat
      when Prism::LocalVariableTargetNode then shared?(pat.name) ? write_shared(pat.name, v) : @locals[lname(pat.name)] = v
      when Prism::CapturePatternNode then pattern_match(pat.value, v, fail_b); @locals[lname(pat.target.name)] = v
      when Prism::ConstantReadNode then check.(emit(:isa, [v, pat.name]))
      when Prism::NilNode then check.(emit(:cmp, [v, nil_const], :eq))
      when Prism::PinnedVariableNode then check.(emit(:cmp, [v, expr(pat.variable)], :eq))
      when Prism::PinnedExpressionNode then check.(emit(:cmp, [v, expr(pat.expression)], :eq))
      when Prism::RangeNode # a range matches numbers (or strings) in it; anything else fails rather than errors
        bound = pat.left || pat.right
        check.(emit(:isa, [v, bound.is_a?(Prism::StringNode) ? :String : :Numeric]))
        lo = pat.left && expr(pat.left); hi = pat.right && expr(pat.right)
        check.(emit(:cmp, [v, lo], :ge)) if lo
        check.(emit(:cmp, [v, hi], pat.exclude_end? ? :lt : :le)) if hi
      when Prism::AlternationPatternNode # a | b: a passes, or b does (no bindings inside)
        ok = @f.new_block(:palt); try_b = @f.new_block(:palt2)
        pattern_match(pat.left, v, try_b); emit(:br, [ok])
        @cur = try_b; pattern_match(pat.right, v, fail_b); emit(:br, [ok])
        @cur = ok
      when Prism::ArrayPatternNode
        check.(emit(:isa, [v, pat.constant.name])) if pat.constant
        check.(emit(:isa, [v, :Array]))
        n = pat.requireds.size + pat.posts.size
        check.(emit(:cmp, [emit(:alen, [v]), const(n)], pat.rest ? :ge : :eq))
        pat.requireds.each_with_index { |e, k| pattern_match(e, emit(:idx, [v, const(k)]), fail_b) }
        if pat.rest.is_a?(Prism::SplatNode) && pat.rest.expression
          @locals[lname(pat.rest.expression.name)] = emit(:mcall, [:slice_range, v, const(pat.requireds.size), const(-1 - pat.posts.size), const(0)])
        end
        pat.posts.each_with_index { |e, k| pattern_match(e, emit(:idx, [v, emit(:sub, [emit(:alen, [v]), const(pat.posts.size - k)])]), fail_b) }
      when Prism::HashPatternNode
        check.(emit(:isa, [v, pat.constant.name])) if pat.constant
        # an object with readers (a Struct / Data): deconstruct_keys is its readers
        vkind = vnode ? kind_of(vnode) : nil
        vk = vkind.is_a?(Symbol) && @classes[vkind] ? @classes[vkind] : (pat.constant && @classes[pat.constant.name])
        if vk
          pat.elements.each do |el|
            kname = el.key.unescaped.to_sym
            iv = vk.find_reader(kname) or (emit(:br, [fail_b]); @cur = @f.new_block(:dead); next)
            got = emit(:fld_get, [v, vk.ivar(iv)])
            if el.value.nil? || el.value.is_a?(Prism::ImplicitNode) then @locals[lname(kname)] = got
            else pattern_match(el.value, got, fail_b) end
          end
          return
        end
        check.(emit(:isa, [v, :Hash]))
        pat.elements.each do |el|
          key = el.key; kname = key.unescaped.to_sym
          kc = const(sym_id(kname.to_s)); kc.ty = :sym
          check.(emit(:hkey, [v, kc]))
          got = emit(:idx, [v, kc])
          if el.value.nil? || el.value.is_a?(Prism::ImplicitNode) then @locals[lname(kname)] = got # { name: } binds name
          else pattern_match(el.value, got, fail_b) end
        end
      when Prism::FindPatternNode then raise "find pattern [*, x, *]: not supported"
      else check.(emit(:cmp, [v, expr(pat)], :eq)) # a literal value
      end
    end

    def when_test(subj, c)
      return ->() { expr(c) } unless subj
      return ->() { emit(:isa, [subj, c.name]) } if class_const?(c) # `when Klass` is Klass === subj
      return ->() { emit(:cmp, [emit(:call, [demand(:__str_index_re), subj, expr(c)]), nil_const], :ne) } if c.is_a?(Prism::RegularExpressionNode) # `when /re/` is re === subj, and sets $1..
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
      ps = n.parameters&.parameters
      @pending_arity = { required: ps&.requireds&.size || 0, optional: ps&.optionals&.size || 0 }
      params, pre = flatten_params(n.parameters&.parameters)
      captured = free_locals(n.body, params).select { |nm| @locals.key?(lname(nm)) }
      c = closure_value(params, captured, pre + (n.body&.body || []))
      @deferred_lambdas.last[1].strict_arity = true if @deferred_lambdas.last[0].equal?(c.args[0]) # ->(){} checks its argument count
      c
    end

    def closure_value(params, captured, stmts, ie_self: nil)
      rest_name = params.last.is_a?(Array) && params.last[0] == :rest ? params.last[1] : nil
      params = params[0...-1] + [rest_name] if rest_name
      @lambda_count = (@lambda_count || 0) + 1
      k = @classes[:"__lambda#{@lambda_count}"] = Klass.new(:"__lambda#{@lambda_count}")
      k.id = @classes.size; k.closure = true
      if ie_self # the block will be instance_eval'd: its self is an object of that class, stored into field 0 at the instance_eval site
        k.outer = ie_self; k.ivar(:@__self); k.ie_self = true
      end
      captured.each { k.ivar(:"@#{_1}") }
      outer_self = @klass && !@klass.closure ? @klass : (@klass&.closure ? @klass.outer : nil)
      outer_self = nil if @owner # module singleton methods have no instance
      if !ie_self && outer_self && @locals.key?(lname(:self)) && refers_to_self_plain?(stmts) # the enclosing object rides along as a capture
        k.outer = outer_self; k.ivar(:@__self)
      end
      f = Func.new(:"#{k.name}#call", 1 + params.size); f.cls = k; k.methods[:call] = f
      f.rest = true if rest_name # the last parameter gathers the extra arguments (Types packs them at the call)
      k.arity_info = @pending_arity if @pending_arity; @pending_arity = nil
      (@deferred_lambdas ||= []) << [k, f, params, captured, stmts, captured.select { shared?(_1) }]
      o = emit(:onew, [k])
      captured.each { |nm| emit(:fld_set, [o, k.ivar(:"@#{nm}"), @locals.fetch(lname(nm))]) } # a shared capture stores its cell
      emit(:fld_set, [o, k.ivar(:@__self), me_val]) if k.outer && !k.ie_self
      o
    end

    # the class whose objects a method's &blk is instance_eval'd on: `x.instance_eval(&blk)` in the body, x of the owner's class
    def ie_target(f)
      d = @defs_by_func[f] or return nil
      bp = d.parameters&.block&.name or return nil
      found = nil
      walk = lambda do |node|
        next unless node.is_a?(Prism::Node)
        if node.is_a?(Prism::CallNode) && %i[instance_eval instance_exec].include?(node.name) && node.block.is_a?(Prism::BlockArgumentNode) && node.block.expression.is_a?(Prism::LocalVariableReadNode) && node.block.expression.name == bp
          found = node # receiverless: self
        end
        node.compact_child_nodes.each { walk.(_1) }
      end
      walk.(d.body)
      return nil unless found
      return f.cls if f.cls
      return @classes[f.name.to_s.split(".")[0].to_sym] if f.name.to_s.include?(".")
      r = found.receiver # a top-level method: the receiver must name its class (`World.new.instance_eval(&b)`)
      r = r.receiver while r.is_a?(Prism::CallNode) && r.name == :new && r.receiver
      r.is_a?(Prism::ConstantReadNode) ? @classes[r.name] : nil
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
    def all_call_names(node, out = [])
      return out unless node.is_a?(Prism::Node)
      out << node.name if node.is_a?(Prism::CallNode)
      node.compact_child_nodes.each { all_call_names(_1, out) }
      out.uniq
    end

    def install_symbol_names(main)
      @syms ||= {}
      saved = [@f, @locals, @cur, @klass, @ct, @owner, @shared]
      @f, @cur, @locals, @klass, @ct, @owner, @shared = main, main.entry, {}, nil, {}, nil, []
      head = main.entry.insts.dup; main.entry.insts.clear
      arr = emit(:anew, [const(@syms.size + 1), emit(:sconst, [""])])
      @syms.each { |name, id| arr = emit(:aset, [arr, const(id), emit(:sconst, [name.to_s])]) }
      emit(:gset, [:SYMBOL_NAMES, arr])
      (@reflective_tabs || {}).each_key do |cn| # a reflective class's ivar table: [sym_id, index, ...]
        k = @classes[cn]; statics = k.ivars.each_with_index.reject { |(iv, _)| iv.to_s.start_with?("@__spare") }
        pairs = [statics.size, 0] + statics.flat_map { |iv, ix| [sym_id(iv.to_s), ix] } # header [static pairs, spares used], the pairs, room for the spares
        pairs += [0] * (2 * Klass::SPARES)
        t = emit(:anew, [const(pairs.size), const(0)])
        pairs.each_with_index { |v, j| t = emit(:aset, [t, const(j), const(v)]) }
        emit(:gset, [:"__IVTAB_#{cn}", t])
      end
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
    def str_range?(r) = r.is_a?(Prism::RangeNode) && (r.left.is_a?(Prism::StringNode) || kind_of(r.left) == :str)

    def range_array(r)
      if str_range?(r) # ("a".."e"): successors up to the end
        return emit(:call, [demand(:__str_range), expr(r.left), expr(r.right), const(r.exclude_end? ? 1 : 0)])
      end
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

    def hash_new_with_default?(v) = v.is_a?(Prism::CallNode) && v.name == :new && v.receiver.is_a?(Prism::ConstantReadNode) && v.receiver.name == :Hash && (v.arguments&.arguments&.size == 1 || v.block.is_a?(Prism::BlockNode) && v.arguments.nil?)
    def hash_default_node(v) # the default value node, or the block as a closure value, remembered as [:closure, obj]
      return v.arguments.arguments[0] if v.arguments
      blk = v.block
      params = blk.parameters&.parameters&.requireds&.map(&:name) || []
      c = closure_value(params, free_locals(blk.body, params).select { |nm| @locals.key?(lname(nm)) }, blk.body&.body || [])
      @hash_default_blocks ||= {}; @hash_default_blocks[@deferred_lambdas.last[1]] = params[0] # this closure's hash parameter misses into itself
      [:closure, c]
    end

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
      @cur = eb
      dn = hash_default_of(recv_node)
      dflt = if dn.is_a?(Array) && dn[0] == :closure then emit(:mcall, [:call, dn[1], h, k]) # Hash.new { |h, k| }: the block, called on a miss
             elsif dn == :closure_self then emit(:mcall, [:call, @locals.fetch(:self), h, k]) # inside that block: its own hash misses back into it
             else expr(dn) end
      eend = @cur; emit(:br, [mb])
      @cur = mb
      ph = mb.phi; ph.args = [[tb, got], [eend, dflt]]; ph
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
        assigned_in = assigned_locals_plain(body) + grown_locals_plain(body) # `out << x` / out.push(x) inside: the handle may move, so the outer sees it through a cell
        free.each { |nm| shared << nm if assigned_in.include?(nm) || all_assigned.count(nm) > 1 }
      end
      # a local assigned inside a rescued body is read by the handler as it was at the raise:
      # a cell, not a value, since the raise can come from anywhere in the body
      rescued_bodies(stmts).each { |body| shared.concat(assigned_locals_plain(body).select { all_assigned.count(_1) > 0 }) }
      # a local that aliases another local (x = y, or x = c ? y : z) and is then grown in place: both names
      # must see the growth, which the value representation cannot give. Refuse rather than diverge (notes/31).
      check_alias_growth(stmts) unless @f.name.to_s.start_with?("__") # the prelude knows its own aliases
      shared.uniq
    end

    # events in source order: [:assign, x, [sources]], [:grow, x], [:read, x]. A grow of x while an alias
    # partner y (x = y or y = x, not since reassigned) is still read afterwards would diverge: refuse.
    def check_alias_growth(stmts)
      ev = []; alias_events(stmts, ev)
      partners = Hash.new { |h, k| h[k] = {} } # name -> {partner => true}
      ev.each_with_index do |(kind, x, srcs), at|
        case kind
        when :assign
          partners[x].each_key { |y| partners[y].delete(x) }; partners[x] = {} # a fresh binding breaks the old aliases
          srcs.each { |y| next if y == x; partners[x][y] = true; partners[y][x] = true }
        when :grow
          partners[x].each_key do |y|
            later = ev[(at + 1)..].take_while { |(k2, x2, _)| !(k2 == :assign && x2 == y) }
            if later.any? { |(k2, x2, _)| k2 == :read && x2 == y }
              raise "#{@f.name}: #{x} aliases #{y} and is grown in place (<<, push, ...) while #{y} is still used; the other name would not see the growth; not supported"
            end
          end
        end
      end
    end
    def alias_events(node, ev)
      return node.each { alias_events(_1, ev) } if node.is_a?(Array)
      return unless node.is_a?(Prism::Node)
      case node
      when Prism::LocalVariableWriteNode then alias_events(node.value, ev); ev << [:assign, node.name, local_sources(node.value)]; return
      when Prism::LocalVariableReadNode then ev << [:read, node.name]; return
      when Prism::CallNode
        if %i[<< push insert concat unshift].include?(node.name) && node.receiver.is_a?(Prism::LocalVariableReadNode)
          node.compact_child_nodes.each { alias_events(_1, ev) unless _1.equal?(node.receiver) }
          ev << [:grow, node.receiver.name]; return
        end
      when Prism::BlockNode, Prism::LambdaNode then return # another scope: its own check when lowered (closures share through cells)
      end
      node.compact_child_nodes.each { alias_events(_1, ev) }
    end

    def real_growers(node, out = []) # locals grown through a handle-moving method (a []= store in range moves nothing)
      return (node.each { real_growers(_1, out) }; out) if node.is_a?(Array)
      return out unless node.is_a?(Prism::Node)
      out << node.receiver.name if node.is_a?(Prism::CallNode) && %i[<< push insert concat unshift].include?(node.name) && node.receiver.is_a?(Prism::LocalVariableReadNode)
      node.compact_child_nodes.each { real_growers(_1, out) }
      out
    end

    # [x, y] for every `x = y` / `x = cond ? y : z` where y, z are locals
    def alias_pairs(node, out = [])
      return (node.each { alias_pairs(_1, out) }; out) if node.is_a?(Array)
      return out unless node.is_a?(Prism::Node)
      if node.is_a?(Prism::LocalVariableWriteNode)
        srcs = local_sources(node.value)
        srcs.each { |s| out << [node.name, s] unless s == node.name }
      end
      node.compact_child_nodes.each { alias_pairs(_1, out) }
      out
    end
    SELF_RETURNING = %i[concat << push append prepend insert unshift replace clear fill map! select! reject! sort! reverse! uniq! compact! flatten! shuffle! rotate! upcase! downcase! capitalize! swapcase! strip! chomp! chop! squeeze! gsub! sub! tr! delete! force_encoding freeze tap itself].freeze
    def local_sources(v)
      case v
      when Prism::LocalVariableReadNode then [v.name]
      when Prism::CallNode # r = s.concat(x) / s.tap {} : r is s; r = m(s) where m returns a parameter: r may be s
        if SELF_RETURNING.include?(v.name) && v.receiver then local_sources(v.receiver)
        elsif v.receiver.nil? && (d = @defs_by_func[@funcs[v.name]] || @yielders&.[](v.name)&.[](1)) && (ps = d.parameters&.requireds) && (args = v.arguments&.arguments)
          returned = returned_param_indexes(d, ps.map(&:name))
          returned.flat_map { |ix| args[ix] ? local_sources(args[ix]) : [] }
        else [] end
      when Prism::IfNode then (v.statements&.body&.last ? local_sources(v.statements.body.last) : []) + (v.subsequent.is_a?(Prism::ElseNode) && v.subsequent.statements&.body&.last ? local_sources(v.subsequent.statements.body.last) : [])
      when Prism::OrNode then local_sources(v.left) + local_sources(v.right)
      when Prism::ParenthesesNode then v.body&.body&.last ? local_sources(v.body.body.last) : []
      else [] end
    end

    # which of a def's required parameters its body may return as-is (the last expression, through parens/if/begin)
    def returned_param_indexes(d, names)
      out = []
      tails = lambda do |n, acc|
        case n
        when nil then acc
        when Prism::LocalVariableReadNode then acc << n.name
        when Prism::ParenthesesNode, Prism::BeginNode then tails.(n.respond_to?(:body) ? n.body&.body&.last : n.statements&.body&.last, acc)
        when Prism::StatementsNode then tails.(n.body.last, acc)
        when Prism::IfNode, Prism::UnlessNode then tails.(n.statements&.body&.last, acc); tails.(n.subsequent.is_a?(Prism::ElseNode) ? n.subsequent.statements&.body&.last : n.subsequent, acc)
        when Prism::ReturnNode then tails.(n.arguments&.arguments&.first, acc)
        end
        acc
      end
      acc = tails.(d.body&.body&.last, [])
      explicit = []
      walk = ->(n) { next unless n.is_a?(Prism::Node); explicit << n.arguments.arguments.first if n.is_a?(Prism::ReturnNode) && n.arguments&.arguments&.size == 1; n.compact_child_nodes.each { walk.(_1) } }
      walk.(d.body)
      explicit.each { tails.(_1, acc) }
      acc.uniq.each { |nm| (ix = names.index(nm)) && out << ix }
      out
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
        if n.is_a?(Prism::LambdaNode) then out << [(n.parameters&.parameters&.requireds || []).flat_map { |r| r.respond_to?(:name) ? [r.name] : r.lefts.map { |l| l.respond_to?(:name) ? l.name : nil }.compact }, n.body]
        elsif closure_block?(n) then out << [(n.block.parameters&.parameters&.requireds || []).flat_map { |r| r.respond_to?(:name) ? [r.name] : r.lefts.map { |l| l.respond_to?(:name) ? l.name : nil }.compact }, n.block.body]
        end
        collect_closures(n.compact_child_nodes, out)
      end
    end

    # a block that becomes a value: lambda {}, proc {}, Proc.new {}, m { } where m takes &blk
    def closure_block?(n)
      return false unless n.is_a?(Prism::CallNode) && n.block.is_a?(Prism::BlockNode)
      return true if n.receiver.nil? && %i[lambda proc].include?(n.name)
      return true if n.name == :new && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Proc
      return true if n.receiver.nil? && (f = @funcs[n.name]) && (d = @defs_by_func[f]) && d.parameters&.block
      # a method with &blk on self, or on an object whose class the pre-typing knows
      k = n.receiver.nil? ? @klass : ((kd = kind_of(n.receiver)).is_a?(Symbol) ? @classes[kd] : nil)
      k && (mf = k.find_method(n.name)) && (d = @defs_by_func[mf]) && d.parameters&.block ? true : false
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
    def has_global?(node, name)
      return false unless node.is_a?(Prism::Node)
      return true if node.is_a?(Prism::GlobalVariableReadNode) && node.name == name
      node.compact_child_nodes.any? { has_global?(_1, name) }
    end

    # locals that are grown in place (<<, push, insert, concat, []= with a new key): their handle may change
    def grown_locals_plain(node, out = [])
      return (node.each { grown_locals_plain(_1, out) }; out) if node.is_a?(Array)
      return out unless node.is_a?(Prism::Node)
      if node.is_a?(Prism::CallNode) && %i[<< push insert concat unshift []= store].include?(node.name) && node.receiver.is_a?(Prism::LocalVariableReadNode)
        out << node.receiver.name
      end
      node.compact_child_nodes.each { grown_locals_plain(_1, out) }
      out
    end

    def assigned_locals_plain(node, out = [])
      return (node.each { assigned_locals_plain(_1, out) }; out) if node.is_a?(Array)
      return out unless node.is_a?(Prism::Node)
      out << node.name if node.is_a?(Prism::LocalVariableWriteNode) || node.is_a?(Prism::LocalVariableOperatorWriteNode) || node.is_a?(Prism::LocalVariableOrWriteNode)
      node.compact_child_nodes.each { assigned_locals_plain(_1, out) }
      out
    end

    # self, an @ivar, or a bare method call (which may be the enclosing class's): needs the enclosing object
    def refers_to_self_plain?(node)
      return node.any? { refers_to_self_plain?(_1) } if node.is_a?(Array)
      return false unless node.is_a?(Prism::Node)
      return true if node.is_a?(Prism::SelfNode) || node.is_a?(Prism::InstanceVariableReadNode) || node.is_a?(Prism::InstanceVariableWriteNode) || node.is_a?(Prism::InstanceVariableOperatorWriteNode)
      return true if node.is_a?(Prism::CallNode) && node.receiver.nil? && !node.name.to_s.start_with?("__") && !%i[puts p print raise lambda proc format sprintf printf rand require].include?(node.name) && !@funcs[node.name]
      node.compact_child_nodes.any? { refers_to_self_plain?(_1) }
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
      if n.receiver.is_a?(Prism::ConstantReadNode) && (sf = @funcs[:"#{n.receiver.name}.#{n.name}"]) && (d = @defs_by_func[sf]) && d.parameters&.block # Owner.m(&b)
        return emit(:call, [sf, *call_args(sf, args), bv])
      end
      # obj.m(&pr) where m yields (inlined only): inline it with a block whose body calls the proc value with the yielded arguments
      if n.receiver && (y = @yielders[n.name]) && y[0] && (kd = kind_of(n.receiver)).is_a?(Symbol) && (kd == y[0].name || @classes[kd] && (c = @classes[kd]; c = c.superclass while c && !c.equal?(y[0]); c))
        yargs = yield_arities(y[1]).max || 0
        params = (0...yargs).map { :"__ya#{_1}" }
        hidden = :"__blkv#{@f.blocks.size}"
        @locals[lname(hidden)] = bv
        src = n.send(:source); loc = n.location
        call = Prism::CallNode.new(src, 0, loc, 0, Prism::LocalVariableReadNode.new(src, 0, loc, 0, hidden, 0), nil, :call, loc, nil, params.empty? ? nil : Prism::ArgumentsNode.new(src, 0, loc, 0, params.map { Prism::LocalVariableReadNode.new(src, 0, loc, 0, _1, 0) }), nil, nil, nil)
        return inline_yielder(y, n.receiver, args, params, [call])
      end
      # a method of the current class (bare) or of a known receiver class that takes &block: the block value is its last argument
      k = n.receiver.nil? ? @klass : ((kd = kind_of(n.receiver)).is_a?(Symbol) ? @classes[kd] : nil)
      if k && (mf = k.find_method(n.name)) && (d = @defs_by_func[mf]) && d.parameters&.block
        rv = n.receiver ? expr(n.receiver) : me_val
        return emit(:mcall, [n.name, rv, *method_args(mf, args, rv), bv])
      end
      raise "block argument to #{n.name}: not supported"
    end

    # the argument counts of the yields in a def body
    def yield_arities(node, out = [])
      return out unless node.is_a?(Prism::Node)
      out << (node.arguments&.arguments&.size || 0) if node.is_a?(Prism::YieldNode)
      node.compact_child_nodes.each { yield_arities(_1, out) } unless node.is_a?(Prism::DefNode) && !node.equal?(node)
      out
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
          hp = @hash_default_blocks&.[](f)
          lower_body(f, [:self, *params], stmts, k, {}, captured, shared, hp)
        elsif (job = @deferred_variants&.shift)
          f, names, stmts = job
          lower_body(f, names, stmts)
        else break end
      end
    end

    def inline_lambda(lam, args)
      ps = lam.parameters&.parameters
      params = ps&.requireds&.map(&:name) || []
      raise "a lambda taking #{params.size} argument#{"s" if params.size != 1} called with #{args.size} (ArgumentError in Ruby)" if params.size != args.size && !ps&.optionals&.any? && !ps&.rest
      pfx = :"lam#{@f.blocks.size}:"
      args = args.dup; kw = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
      params.each_with_index { |p, k| @locals[:"#{pfx}#{p}"] = expr(args[k]) }
      (ps&.optionals || []).each_with_index { |o, k| @locals[:"#{pfx}#{o.name}"] = args[params.size + k] ? expr(args[params.size + k]) : expr(o.value) } # a default, evaluated here
      if ps&.rest.is_a?(Prism::RestParameterNode) && ps.rest.name
        extra = args[(params.size + (ps.optionals || []).size)..] || []
        @locals[:"#{pfx}#{ps.rest.name}"] = pack_values(extra.map { expr(_1) })
      end
      if kw || (ps&.keywords&.any?)
        given = (kw&.elements || []).to_h { |el| [el.key.unescaped.to_sym, el.value] }
        (ps&.keywords || []).each { |kp| @locals[:"#{pfx}#{kp.name}"] = given.key?(kp.name) ? expr(given[kp.name]) : (kp.respond_to?(:value) && kp.value ? expr(kp.value) : raise("missing keyword #{kp.name}")) }
      end
      @blk_pfx = (@blk_pfx || []) << pfx
      last = nil
      (lam.body&.body || []).each { last = expr(_1) }
      @blk_pfx.pop
      @locals.delete_if { |k, _| k.to_s.start_with?(pfx.to_s) }
      last || const(0)
    end

    MATH_CONSTS = { PI: Math::PI, E: Math::E }.freeze
    FLOAT_CONSTS = { INFINITY: Float::INFINITY, NAN: Float::NAN, MAX: Float::MAX, MIN: Float::MIN, EPSILON: Float::EPSILON }.freeze
    FLOAT_INT_CONSTS = { DIG: Float::DIG, MAX_EXP: Float::MAX_EXP, MIN_EXP: Float::MIN_EXP, MANT_DIG: Float::MANT_DIG }.freeze
    # the class whose constant a bare name means here: the current class (or class-method owner), then its ancestors
    # X.instance_method(:m).bind(obj) -> [X, :m, obj node]; X.instance_method(:m) with obj given (bind_call) likewise
    def unbound_method_of(node, obj)
      if node.name == :bind && node.receiver.is_a?(Prism::CallNode) && node.arguments&.arguments&.size == 1
        inner = unbound_method_of(node.receiver, node.arguments.arguments[0]) and return inner
      end
      return nil unless node.name == :instance_method && node.receiver.is_a?(Prism::ConstantReadNode) && @classes[node.receiver.name] && node.arguments&.arguments&.first.is_a?(Prism::SymbolNode) && obj
      [node.receiver.name, node.arguments.arguments.first.unescaped.to_sym, obj]
    end

    PRELUDE_CLASSES = %i[Exception StandardError RuntimeError ArgumentError TypeError NameError NoMethodError ZeroDivisionError IndexError KeyError StopIteration RangeError FloatDomainError IOError FrozenError NotImplementedError ScriptError NoMemoryError IndusThrow Set Regexp MatchData Struct Comparable Enumerable].freeze
    def prelude_class?(k) = PRELUDE_CLASSES.include?(k.name) || k.name.to_s.start_with?("__")

    def has_const?(name) # Klass::X or a top-level X
      cn, x = name.to_s.split("::", 2)
      x ? @class_const_owners[x.to_sym].include?(cn.to_sym) : @top_consts&.include?(name.to_sym)
    end
    def const_names = @class_const_owners.flat_map { |x, owners| owners.map { |o| :"#{o}::#{x}" } }

    def const_owner(name)
      return nil unless @class_const_owners && !@class_const_owners[name].empty?
      k = @owner ? @classes[@owner] : @klass
      k = k.outer if k&.closure && k.outer
      while k
        return k.name if @class_const_owners[name].include?(k.name)
        k = k.superclass && @classes[k.superclass]
      end
      nil
    end

    def expr_const_path(n)
      # Mod::NAME -> the constant; Mod::Klass handled by callers (Klass.new)
      if n.parent.is_a?(Prism::ConstantReadNode) && @classes[n.parent.name] && @class_const_owners && !@class_const_owners[n.name].empty? # Base::PREFIX: through the ancestors
        k = @classes[n.parent.name]
        while k
          return emit(:gget, [:"#{k.name}::#{n.name}"]) if @class_const_owners[n.name].include?(k.name)
          k = k.superclass && @classes[k.superclass]
        end
      end
      if n.parent.is_a?(Prism::CallNode) && n.parent.name == :class && n.parent.arguments.nil? && n.parent.receiver && @class_const_owners && !@class_const_owners[n.name].empty?
        return emit(:mcall, [:"__const_#{n.name}", expr(n.parent.receiver)]) # self.class::X: the receiver's class decides at run time (a synthesized reader per class)
      end
      return fconst(MATH_CONSTS.fetch(n.name)) if n.parent.is_a?(Prism::ConstantReadNode) && n.parent.name == :Math
      if n.parent.is_a?(Prism::ConstantReadNode) && n.parent.name == :Float
        return fconst(FLOAT_CONSTS[n.name]) if FLOAT_CONSTS.key?(n.name)
        return const(FLOAT_INT_CONSTS[n.name]) if FLOAT_INT_CONSTS.key?(n.name)
      end
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
    # an expression whose value is a class (printed as its bare name): x.class, (e rescue $!.class), Klass
    def class_valued?(a)
      a = a.body.body.last while a.is_a?(Prism::ParenthesesNode) && a.body&.body&.size == 1
      if a.is_a?(Prism::RescueModifierNode) # (x rescue $!.class): puts and p agree for the numeric/boolean/nil arm, so the class arm decides
        return class_valued?(a.rescue_expression) && ![:str, :sym].include?(kind_of(a.expression)) && !kind_of(a.expression).is_a?(Array) && !a.expression.is_a?(Prism::StringNode) && !a.expression.is_a?(Prism::SymbolNode) && !a.expression.is_a?(Prism::ArrayNode) && !a.expression.is_a?(Prism::HashNode)
      end
      return true if a.is_a?(Prism::ConstantReadNode) && (@classes[a.name] || %i[Integer Float String Array Hash Symbol NilClass].include?(a.name))
      return true if a.is_a?(Prism::CallNode) && %i[owner superclass].include?(a.name) && a.arguments.nil? && a.receiver # Method#owner, Class#superclass: a class
      a.is_a?(Prism::CallNode) && a.name == :class && a.arguments.nil? && a.receiver
    end

    # an array expression whose inspect can be built inline: not a user method's result (nil on some path is possible there; Types' by-type inspect checks)
    def inline_inspect?(a) = kind_of(a) == :array && !(a.is_a?(Prism::CallNode) && a.receiver.nil? && !a.block && @funcs[a.name] && !prelude?(a.name))
    def prelude?(name) = name.to_s.start_with?("__")

    def p_one(a)
      if inline_inspect?(a) then emit(:puts_str, [inspect_str(a)])
      elsif class_valued?(a) then emit(:puts_v, [expr(a)]) # p x.class: the class name, unquoted (classes are names at run time)
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
      saved, @recv_value = @recv_value, nil # the receiver value belongs to the iterator, not to calls inside its body
      return body.call(pfx) if body.is_a?(Proc)
      last = nil; body.each { last = expr(_1) }; last
    ensure
      @recv_value = saved
    end

    def or_written_ivars(node, out = []) # @x ||= v / @x &&= v: read before any sure write
      return out unless node.is_a?(Prism::Node)
      out << node.name if (node.is_a?(Prism::InstanceVariableOrWriteNode) || node.is_a?(Prism::InstanceVariableAndWriteNode)) && !out.include?(node.name)
      node.compact_child_nodes.each { or_written_ivars(_1, out) }
      out
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
      breaks = @loop[:breaks]; bvals = @loop[:break_values] || []; @loop = outer
      @cur = xb
      # exit sees the header's values, or a break site's
      @locals = breaks.empty? ? phis.dup : merge_locals(xb, [[hb, phis.dup], *breaks])
      break_result(xb, breaks, bvals, hb)
    end
  end
end
