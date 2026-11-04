# Type inference, to a fixpoint across functions, then conversions.
#   :int :float :nil  a class name (Symbol)  [:arr, elem]
# Params from call sites, returns from ret sites, ivars from writes, array
# elements from fills and stores, constants from their writes. Method calls
# on objects (:mcall) are bound to a function or a field once the receiver's
# class is known.
module Indus
  module Types
    INT_NIL = -(1 << 63) # the nil of a nullable integer (:int?)
    def self.nullable(t) = t == :int ? :int? : t   # a read that may miss
    def self.narrow(t) = t == :int? ? :int : t     # used as a number: nil would have raised
    def self.join(a, b)
      return b if a.nil?
      return a if b.nil? || a == b
      return :int? if (a == :int && b == :nil) || (a == :nil && b == :int) || [a, b].sort_by(&:to_s) == %i[int int?]
      return b if a == :nil
      return a if b == :nil
      return :float if (a == :int && b == :float) || (a == :float && b == :int)
      intish = ->(t) { t == :int || t == :int? || t.nil? }
      return BIG if (big?(a) && (intish.(b) || arr(b) && intish.(b[1]))) || (big?(b) && (intish.(a) || arr(a) && intish.(a[1])))
      return :int? if (a == :int? && b == :nil) || (a == :nil && b == :int?)
      return :strbuf if (a == :str && b == :strbuf) || (a == :strbuf && b == :str) # a string that grew a stable handle
      return [:arr, join_elem(a[1], b[1])] if arr(a) && arr(b)
      return [:hash, join_elem(a[1], b[1]), join_elem(a[2], b[2])] if hsh(a) && hsh(b)
      # two classes meet: a closed poly set (whole program, so it is finite)
      ca, cb = classes_of(a), classes_of(b)
      return [:poly, (ca | cb).sort] if ca && cb
      # anything else meeting: a tagged scalar (see notes/29_tagged_scalars_design.md)
      return :dyn if a == :dyn || b == :dyn || dynable?(a) && dynable?(b)
      raise "type clash: #{a.inspect} vs #{b.inspect}"
    end
    # container elements keep their identity: an Integer stored next to a Float stays an Integer
    def self.join_elem(a, b)
      return :dyn if (a == :int && b == :float) || (a == :float && b == :int)
      join(a, b)
    end
    def self.dynable?(t) = %i[int int? float str bool sym nil lambda].include?(t) || arr(t) || hsh(t) || poly?(t) || (t.is_a?(Symbol) && @classes&.[](t))
    def self.classes_of(t)
      return t[1] if poly?(t)
      [t] if t.is_a?(Symbol) && @classes[t]
    end
    def self.poly?(t) = t.is_a?(Array) && t[0] == :poly
    def self.of(f, v) = v.op == :param ? f.ptypes[f.params.index(v)] : v.ty
    def self.arr(t) = t.is_a?(Array) && t[0] == :arr
    # Bignum: an int array ([sign, limbs...], lib/indus/rt/big.rb) marked so that operators
    # and printing go to __big_*. Array-shaped for everything the prelude does to it.
    BIG = [:arr, :int, :big].freeze
    def self.big?(t) = t == BIG
    # does a value of this type hold a heap pointer the collector must follow?
    def self.heap_pointer?(t)
      return true if t == :str || t == :dyn || t == :strbuf
      return true if t.is_a?(Array) && %i[arr hash poly].include?(t[0])
      t.is_a?(Symbol) && !!@classes&.[](t)
    end
    def self.hsh(t) = t.is_a?(Array) && t[0] == :hash

    def self.reset! = (@ivars = nil; @consts = nil; @instances = nil)
    # a prelude function by name: lowered on first use, typed in the current fixpoint
    def self.fn(name)
      f = @lower.demand(name)
      @lower.lowered_late!.each { |g| g.ptypes ||= Array.new(g.params.size); Passes.trivial_phis(g); @funcs_live << g unless @funcs_live.include?(g) }
      f
    end
    def self.fnq(name) = @lower.funcs.key?(name) ? fn(name) : nil
    # a snapshot of the program-wide tables, to detect a seam widening a type
    # that compiled code already relies on
    def self.snapshot = Marshal.load(Marshal.dump([@ivars.to_h { |k, v| [k, v.dup] }, @consts.dup]))
    def self.run(funcs, classes, lower = nil)
      @classes = classes; @lower = lower || @lower
      # program-wide state; the resident compiler re-runs inference for one
      # function against the tables the whole program built
      @ivars ||= Hash.new { |h, k| h[k] = {} } # class name -> ivar index -> type
      @consts ||= {}
      @funcs_live = funcs
      funcs.each { |f| next if f.ptypes; f.ptypes = Array.new(f.params.size); f.rtype = nil; f.ptypes[0] = f.cls.name if f.cls }
      @seams = funcs.any? { |f| f.all.any? { _1.op == :seam } }
      loop do
        changed = false
        mark_unused_results(funcs) if funcs.any? { _1.name == :main } # a whole-program fact; the resident compiler sees one function
        set = ->(cur, nt, &w) { (w.call(join(cur, nt)); changed = true) if nt && join(cur, nt) != cur }
        funcs.each do |f|
          f.all.each do |i|
            # a value entering a slot whose type is wider than its own: two representation
            # changes happen at the value's *origin*, so a slot never mixes representations
            # int -> Bignum coercions are inserted here, inside the fixpoint: the call names a
            # prelude function that must be lowered and typed before the fixpoint ends
            if @settled # once the operators have settled: an int operand of an add may still become a __big_add result
              each_slot(f, i) { |v, dest, set| (set.(coerce(f, i.block, i, v, dest)); changed = true) if big?(dest) && v.is_a?(Inst) && %i[int int?].include?(of(f, v)) }
              if i.op == :phi && big?(i.ty)
                i.args.map! { |(pred, v)| %i[int int?].include?(of(f, v)) ? (changed = true; [pred, coerce(f, pred, pred.term, v, BIG)]) : [pred, v] }
              end
            end
            each_flow(f, i) do |v, dest|
              next unless v.is_a?(Inst)
              if @settled && dest == :int? && v.op == :const && v.ty == :nil then v.args[0] = INT_NIL; v.ty = :int; changed = true end # nil in a nullable int slot is the sentinel (settled: the slot might still widen to a pointer type)
              changed = true if (dest == :dyn || arr(dest) && dest[1] == :dyn || hsh(dest) && dest[2] == :dyn) && widen_elements_to_dyn(f, v, dest)
              changed = true if dest == :strbuf && of(f, v) == :str && make_cell(f, v, i)
            end
            bind(f, i) if i.op == :mcall
            if i.op == :call && generic?(i.args[0]) && clashes?(i.args[0], i.args[1..].map { of(f, _1) })
              # another caller already shaped this prelude generic: this call gets its own copy
              # (before infer, so the call's type never sees the other instance's result)
              i.args[0] = instance_for(i.args[0], i.args[1..].map { of(f, _1) }, funcs); changed = true
            end
            # `s << v` where s is a parameter (or loop-carried from one): the caller must see the
            # growth, so the value becomes a stable handle (:strbuf, notes/32). The cell is one
            # word holding the current string; appends write through it, reads load through it.
            if i.op == :lshift_or_append && of(f, i.args[0]) == :str && (ao = alias_origin(i.args[0]))
              make_cell(f, ao, i); changed = true
            end
            if i.op == :lshift_or_append && of(f, i.args[0]) == :strbuf then i.op = :bufappend; i.ty = :strbuf; bufferize(f, i); changed = true end
            if i.op == :call # an argument flowing into a :strbuf parameter is made a stable handle at its origin
              callee = i.args[0]
              i.args[1..].each_with_index do |v, k|
                next unless callee.ptypes[k] == :strbuf && of(f, v) == :str
                make_cell(f, v, i); changed = true
              end
            end
            if i.op == :lshift_or_append && arr(of(f, i.args[0])) # a << v on an array is push: aset at the length
              raise "#{f.name}: `<<` on parameter #{i.args[0]} would not be seen by the caller after growth; not supported yet" if i.args[0].op == :param
              len = Inst.new(:alen, [i.args[0]]); len.ty = :int; len.block = i.block
              i.block.insts.insert(i.block.insts.index(i), len)
              i.op = :aset; i.args = [i.args[0], len, i.args[1]]; changed = true
            end
            dsend(f, i) if i.op == :dsend
            float_print(f, i) if %i[puts_v p_v print_v].include?(i.op) && of(f, i.args[0]) == :float
            if %i[puts_v p_v print_v to_s].include?(i.op) && big?(of(f, i.args[0])) # Bignum prints through the prelude
              c = Inst.new(:call, [fn(:__big_to_s), i.args[0]]); c.ty = :str; c.block = i.block
              i.block.insts.insert(i.block.insts.index(i), c)
              if i.op == :to_s then i.op = :nop; i.args = [c]; i.ty = :str else i.args = [c] end
              changed = true
            end
            if i.op == :eputs_v && (t = of(f, i.args[0])) # $stderr.puts: make it a string, then write to fd 2
              c = case t
                  when :str then i.args[0]
                  when :float then Inst.new(:call, [fn(:__float_to_s), i.args[0]])
                  when :int, :int? then Inst.new(:itos, [i.args[0]])
                  when :dyn then Inst.new(:call, [fn(:__dyn_to_s), i.args[0]])
                  else raise "$stderr.puts of #{t.inspect}"
                  end
              unless c.equal?(i.args[0]) then c.ty = :str; c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c) end
              i.op = :eputs_str; i.args = [c]
            end
            # printing/inspecting by type is irreversible, so it waits for the types to settle (below)
            if i.op == :cmp && arr(of(f, i.args[0])) && arr(of(f, i.args[1])) && %i[eq ne].include?(i.cond) # Array#== is elementwise
              l, r = i.args; fn = fn(:__arr_eq)
              c = Inst.new(:call, [fn, l, r]); c.ty = :bool; c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c)
              z = Inst.new(:const, [0]); z.ty = :int; z.block = i.block; i.block.insts.insert(i.block.insts.index(i), z)
              i.args = [c, z]; i.cond = i.cond == :eq ? :ne : :eq; changed = true # (a == b) is (eq_result != 0)
            end
            if %i[add sub mul div mod cmp].include?(i.op) && (big?(of(f, i.args[0])) || big?(of(f, i.args[1]))) && !@no_big_rewrite
              big_op(f, i); changed = true
            end
            if i.op == :mul && of(f, i.args[0]) == :str # "ab" * n
              fn = fn(:__str_times); i.op = :call; i.args = [fn, *i.args]; i.ty = :str; changed = true
            end
            if @settled
              if i.op == :alen && of(f, i.args[0]) == :dyn # length of a tagged value: by tag
                i.op = :call; i.args = [fn(:__dyn_length), i.args[0]]; i.ty = :int; changed = true
              end
              if i.op == :to_s && (t = of(f, i.args[0])) # to_s by type; a prelude call must be made here, so it gets typed
                case t
                when :str then i.op = :nop; changed = true
                when :float then i.op = :call; i.args = [fn(:__float_to_s), i.args[0]]; i.ty = :str; changed = true
                when :bool then i.op = :bool_to_s; changed = true
                when :dyn then i.op = :call; i.args = [fn(:__dyn_to_s), i.args[0]]; i.ty = :str; changed = true
                end
              end
              if %i[sappend scat bufappend lshift_or_append].include?(i.op) && of(f, i.args[1]) == :dyn # must be a String at run time
                c = Inst.new(:call, [fn(:__dyn_str), i.args[1]]); c.ty = :str; c.block = i.block
                i.block.insts.insert(i.block.insts.index(i), c); i.args[1] = c; changed = true
              end
              dyn_op(f, i) if %i[add sub mul div cmp].include?(i.op) && (of(f, i.args[0]) == :dyn || of(f, i.args[1]) == :dyn)
              dyn_print(f, i) if %i[puts_v p_v print_v inspect_v].include?(i.op) && of(f, i.args[0]) == :dyn
              inspect_v(f, i) if i.op == :inspect_v && of(f, i.args[0])
            end
            index(f, i) if i.op == :idx || i.op == :idx_set
            t = infer(f, i)
            was = i.ty
            set.(i.ty, t) { i.ty = _1 }
            bufferize(f, i) if i.ty == :strbuf && was != :strbuf # the cell now flows through this value (phi, call result, ...)
            case i.op
            when :call
              callee = i.args[0]
              if generic?(callee) && clashes?(callee, i.args[1..].map { of(f, _1) }) # a call rewritten into a generic this very visit
                callee = i.args[0] = instance_for(callee, i.args[1..].map { of(f, _1) }, funcs); changed = true
              end
              i.args[1..].each_with_index { |a, k| set.(callee.ptypes[k], of(f, a)) { callee.ptypes[k] = _1 } }
            when :pcall
              arms, recv, *args = i.args
              arms.each do |klass, kind, payload|
                case kind
                when :call
                  payload.ptypes[0] = klass.name
                  args.each_with_index { |a, k| set.(payload.ptypes[k + 1], of(f, a)) { payload.ptypes[k + 1] = _1 } }
                when :fld_set then set.(@ivars[klass.name][payload], of(f, args[0])) { @ivars[klass.name][payload] = _1 }
                end
              end
            when :sendsw
              arms, _, recv, *args = i.args
              arms.each do |_, kind, payload|
                case kind
                when :call
                  args.each_with_index { |a, k| set.(payload.ptypes[k + 1], of(f, a)) { payload.ptypes[k + 1] = _1 } }
                when :fld_set then k = of(f, recv); set.(@ivars[k][payload], of(f, args[0])) { @ivars[k][payload] = _1 } if k
                end
              end
            when :ret then set.(f.rtype, of(f, i.args[0])) { f.rtype = _1 } unless f.result_unused
            when :aset
              a, _, v = i.args
              nt = [:arr, of(f, v)]
              cur = of(f, a)
              if of(f, v) && (cur.nil? || (arr(cur) && join(cur, nt) != cur))
                a = a.args[0] while a.op == :aset # widen the container at its origin, so earlier stores see it too
                a.op == :param ? f.ptypes[f.params.index(a)] = join(cur, nt) : a.ty = join(cur, nt); changed = true
              end
            when :hset
              h, k, v = i.args
              kt, vt = of(f, k), of(f, v)
              if kt && vt && vt != :nil
                nt = [:hash, kt, vt]; cur = of(f, h)
                if cur.nil? || join(cur, nt) != cur
                  h = h.args[0] while h.op == :hset
                  h.op == :param ? f.ptypes[f.params.index(h)] = join(cur, nt) : h.ty = join(cur, nt); changed = true
                end
              end
            when :fld_set
              o, ix, v = i.args; k = of(f, o)
              set.(@ivars[k][ix], of(f, v)) { @ivars[k][ix] = _1 } if k
            when :gset then set.(@consts[i.args[0]], of(f, i.args[1])) { @consts[i.args[0]] = _1 }
            end
          end
        end
        unless changed
          if !@settled && !@promoted && promote_geometric(funcs) then @promoted = true; changed = true; next end
          break if @settled # second convergence: prints resolved and types stable
          @settled = true; changed = true # one more round with the by-type rewrites enabled
        end
      end
      @settled = false; @promoted = false
      funcs.each { |f| f.all.each { |i| raise "uninitialized constant #{i.args[0]}" if i.op == :gget && !@consts.key?(i.args[0]) } }
      # classes that appear in any poly type carry a tag word
      tag = ->(t) { classes_of(t)&.each { @classes[_1].tagged = true } if poly?(t) || arr(t) && poly?(t[1]) }
      funcs.each { |f| f.all.each { tag.(_1.ty) }; f.ptypes.each { tag.(_1) }; tag.(f.rtype) }
      @ivars.each_value { |h| h.each_value { tag.(_1) } }
      funcs.each { convert(_1) }
      # a user object boxed into a :dyn carries its class id in word 0 and is listed in the DYN
      # descriptor: decided after convert, which is where the boxes are inserted
      funcs.each do |f|
        f.all.each do |i|
          next unless i.op == :box
          (classes_of(i.args[1]) || []).each { |cn| k = @classes[cn]; k.tagged = true; k.boxed = true } # a class or a poly set of classes
        end
      end
      funcs.each { strings(_1) }
    end

    # generic ops whose operands turned out to be strings
    def self.strings(f)
      f.all.each { |i| (i.op = :sconst; i.args = [""]) if i.op == :inspect_v } # unreached: empty array, no element type
      f.all.each do |i| # is_a?: decided here; a poly receiver needs its tag at run time
        next unless i.op == :isa
        v, cname = i.args; t = of(f, v)
        want = { Integer: :int, Float: :float, String: :str, Array: :arr, Hash: :hash }[cname]
        if t == :dyn
          i.op = :isa_dyn; i.args = [v, cname] # tag test, or class id for user classes
        elsif poly?(t) && @classes[cname]
          i.op = :isa_tag; i.args = [v, @classes[cname].id] # compare the class id in word 0
        else
          yes = want ? (want == :arr || want == :hash ? (t.is_a?(Array) && t[0] == want) : t == want || (want == :int && t == :int?)) : (t == cname || (t.is_a?(Symbol) && @classes[t] && ancestor?(@classes[t], cname)))
          i.op = :const; i.args = [yes ? 1 : 0]; i.ty = :bool
        end
      end
      f.blocks.each do |b| # truthiness of a nullable int: not the sentinel
        t = b.term
        next unless t&.op == :condbr && of(f, t.args[0]) == :int?
        sent = Inst.new(:const, [INT_NIL]); sent.ty = :int; sent.block = b
        c = Inst.new(:cmp, [t.args[0], sent], :ne); c.ty = :bool; c.block = b
        b.insts.insert(b.insts.index(t), sent, c); t.args[0] = c
      end
      f.all.each do |i|
        case i.op
        when :add then i.op = :scat if of(f, i.args[0]) == :str
        when :cmp
          l, r = i.args
          if of(f, l) == :str && of(f, r) == :str # nil stays a pointer compare
            case i.cond
            when :eq then i.op = :seq; i.cond = nil
            when :ne then i.op = :sne; i.cond = nil
            else i.op = :scmp # ordering: rt_str_cmp then compare the sign with cond
            end
          end
          if of(f, l) == :int? && of(f, r) == :nil then r.args[0] = INT_NIL; r.ty = :int
          elsif of(f, r) == :int? && of(f, l) == :nil then l.args[0] = INT_NIL; l.ty = :int end
        when :to_s # (by type, resolved in the fixpoint's settled round; anything left is an int)
          i.op = :itos
        when :to_i then i.op = :stoi if of(f, i.args[0]) == :str
        when :puts_v, :p_v, :print_v
          t = of(f, i.args[0])
          i.op = case i.op
                 when :puts_v then { str: :puts_str, bool: :puts_bool, int?: :puts_opt, nil: :puts_nil }.fetch(t, :puts_i)
                 when :p_v then { str: :p_str, bool: :puts_bool, int?: :puts_opt, nil: :puts_nil_word }.fetch(t, :puts_i)
                 else { str: :print_str }.fetch(t, :print_i)
                 end
        when :lshift_or_append
          t = of(f, i.args[0])
          if t == :int then i.op = :shl
          elsif t
            if i.args[0].op == :param || (i.args[0].op == :phi && i.args[0].args.any? { |(_, v)| v.op == :param })
              # the callee's home is rebound, the caller's is not: once the buffer grows they diverge.
              # Needs stable handles for aliased-and-appended values (notes/31). Refuse rather than diverge.
              raise "#{f.name}: `<<` on parameter #{i.args[0]} would not be seen by the caller after growth; not supported yet"
            end
            i.op = :sappend
          end
        end
      end
    end

    # puts/p/print of a Float: format with the prelude's __float_to_s (a call,
    # typed by this same fixpoint), then print the string
    def self.float_print(f, i)
      fts = fn(:__float_to_s)
      c = Inst.new(:call, [fts, i.args[0]]); c.block = i.block
      i.block.insts.insert(i.block.insts.index(i), c)
      i.args = [c]
      i.op = :print_v if i.op == :print_v
      i.op = :puts_v if i.op == :p_v # p of a float is unquoted
    end

    FRESH_ORIGINS = %i[sconst scat itos ssub sdup call param phi aget hget fld_get gget].freeze
    # a value whose home cannot be rebound by the appending code: a parameter, or a value loaded
    # from a slot (ivar, element, global) -- possibly loop-carried (phi) or through appends
    def self.alias_origin(v, seen = {})
      return nil if seen[v]; seen[v] = true
      case v.op
      when :param, :fld_get, :aget, :hget, :gget then v
      when :phi then v.args.each { |(_, a)| (r = alias_origin(a, seen)) and return r }; nil
      when :lshift_or_append, :sappend, :bufappend then alias_origin(v.args[0], seen)
      end
    end

    # A method whose result no caller reads (`parse(text)` as a statement) has a return
    # value in Ruby -- its last expression -- but nothing observes it, so its type must not
    # flow anywhere: a trailing `if` without else would otherwise join (array, nil) into :dyn
    # and widen the array at its origin. Direct calls only; a method reachable through a
    # dispatch (pcall/sendsw/dsend/seam) is assumed read.
    def self.mark_unused_results(funcs)
      read = {}; read_name = {}
      funcs.each do |f|
        f.all.each do |i|
          case i.op
          when :pcall, :sendsw then i.args[0].each { |(_, kind, payload)| read[payload] = true if kind == :call }
          when :dsend then i.args.each { read[_1] = true if _1.is_a?(Func) }
          end
          (i.op == :phi ? i.args.map(&:last) : i.args).each do |a|
            next unless a.is_a?(Inst)
            read[a.args[0]] = true if a.op == :call
            read_name[a.args[0]] = true if a.op == :mcall # target not bound yet: every method of that name
          end
        end
      end
      funcs.each do |f|
        base = f.name.to_s.split("#").last.to_sym
        unused = !read[f] && !read_name[base] && f.name != :main && !f.patchable && !f.name.to_s.start_with?("__")
        f.result_unused = unused
        # Once the types have settled (mcalls bound), a dead result is made to return a
        # constant, so the value -- and any phi only it kept alive -- stops existing instead of
        # shaping the types of what it was built from. Irreversible, so not before @settled,
        # and never in a seam program: code compiled later may read what nobody reads now.
        next unless unused && @settled && !@seams
        f.all.each do |i|
          next unless i.op == :ret && i.args[0].is_a?(Inst) && i.args[0].op != :const
          c = Inst.new(:const, [0]); c.ty = :nil; c.block = i.block
          i.block.insts.insert(i.block.insts.index(i), c); i.args = [c]
        end
        Passes.trivial_phis(f)
      end
    end

    # prelude generics: top-level functions named __arr_* / __merge_*; one instance per
    # distinct container type they are called with
    def self.generic?(f) = f.name.to_s.start_with?("__arr_", "__merge_") && !f.cls
    def self.clashes?(f, ts)
      f.ptypes.zip(ts).any? { |cur, t| cur && t && cur != t && (arr(cur) || arr(t)) && join(cur, t) != cur && join(cur, t) != t || (cur && t && cur != t && join(cur, t) == :dyn) }
    end
    def self.instance_for(f, ts, funcs)
      base = f.name.to_s.sub(/\$\d+$/, "")
      @instances ||= {}
      key = [base, ts.map { arr(_1) || hsh(_1) ? _1 : :_ }]
      @instances[key] ||= begin
        g = @lower.instantiate(f)
        g.ptypes = Array.new(g.params.size); g.rtype = nil
        Passes.trivial_phis(g); funcs << g; g
      end
    end

    # every (value, slot type) pair where i stores a value into a typed slot:
    # container elements, ivars, globals, call parameters, the return slot, phis
    def self.each_flow(f, i)
      case i.op
      when :aset
        t = of(f, i.args[0]); yield i.args[2], t[1] if arr(t)
      when :hset
        t = of(f, i.args[0]); (yield i.args[1], t[1]; yield i.args[2], t[2]) if hsh(t)
      when :fld_set then yield i.args[2], ivar_type(of(f, i.args[0]), i.args[1])
      when :gset then yield i.args[1], @consts[i.args[0]]
      when :call then i.args[1..].each_with_index { |v, k| yield v, i.args[0].ptypes[k] }
      when :ret then yield i.args[0], f.rtype unless f.result_unused
      when :phi then i.args.each { |(_, v)| yield v, i.ty } unless f.result_unused && f.all.all? { |u| !(u.op == :phi ? u.args.map(&:last) : u.args).include?(i) || u.op == :ret }
      end
    end

    # a container flowing into a :dyn slot must hold :dyn elements itself, or whoever
    # unboxes it later finds raw words. Widened at the container's origin. True if changed.
    def self.widen_elements_to_dyn(f, v, dest = :dyn)
      t = of(f, v)
      nt = if dest == :dyn then arr(t) ? [:arr, :dyn] : hsh(t) ? [:hash, :dyn, :dyn] : nil
           else (arr(t) && arr(dest) || hsh(t) && hsh(dest)) ? join(t, dest) : nil end # the slot's own shape
      return false if nt.nil? || t == nt
      v = v.args[0] while %i[aset hset].include?(v.op)
      v.op == :param ? f.ptypes[f.params.index(v)] = nt : v.ty = nt
      true
    end

    # replace v by w in one instruction's operands (phi operands are [pred, value] pairs)
    def self.swap_operand(i, v, w)
      i.op == :phi ? i.args.map! { |(bb, x)| [bb, x == v ? w : x] } : i.args.map! { |a| a == v ? w : a }
    end

    # wrap the string v in a cell at its origin; every use of the origin now sees the cell.
    # `use` is the instruction that wanted the cell. Returns the cell.
    def self.make_cell(f, v, use)
      if v.op == :bufderef # already a cell: hand the cell itself to this use
        swap_operand(use, v, v.args[0])
        return v.args[0]
      end
      o = v; o = o.args[0] while %i[sappend scat lshift_or_append].include?(o.op) && o.args[0].ty == :str && !FRESH_ORIGINS.include?(o.op)
      return o if o.ty == :strbuf
      if o.op == :param then f.ptypes[f.params.index(o)] = :strbuf; bufferize(f, o); return o end
      # a load: the slot it came from becomes the cell (every store into it is wrapped by cellflow)
      case o.op
      when :fld_get
        k = of(f, o.args[0]); @ivars[k][o.args[1]] = :strbuf if k
        o.ty = :strbuf; bufferize(f, o); return o
      when :aget, :hget, :apop
        a = o.args[0]; a = a.args[0] while %i[aset hset].include?(a.op)
        t = of(f, a); nt = arr(t) ? [:arr, :strbuf] : [:hash, t[1], :strbuf]
        a.op == :param ? f.ptypes[f.params.index(a)] = nt : a.ty = nt
        o.ty = :strbuf; bufferize(f, o); return o
      when :gget
        @consts[o.args[0]] = :strbuf; o.ty = :strbuf; bufferize(f, o); return o
      end
      mk = Inst.new(:mkbuf, [o]); mk.ty = :strbuf; mk.block = o.block
      at = o.op == :phi ? 0 : o.block.insts.index(o) + 1
      o.block.insts.insert(at, mk)
      f.replace_uses(o, mk); mk.args = [o]
      bufferize(f, mk); mk
    end

    STRBUF_CONSUMERS = %i[bufappend mkbuf bufderef].freeze
    # v now holds a :strbuf. Every use that wants the string gets a load through the cell;
    # appends go through the cell; calls into :strbuf parameters, returns of a :strbuf
    # function and phis pass the cell itself (phis become :strbuf and are fixed in turn).
    def self.bufferize(f, v, seen = {})
      return if seen[v]; seen[v] = true
      f.all.each do |u|
        next unless u.args.any? { |a| a == v || (a.is_a?(Array) && a[1] == v) }
        case u.op
        when *STRBUF_CONSUMERS then next
        when :lshift_or_append then u.op = :bufappend; u.ty = :strbuf; bufferize(f, u, seen); next
        when :phi then u.ty = :strbuf; bufferize(f, u, seen); next
        when :call then next if u.args[0].ptypes[u.args.index(v) - 1] == :strbuf
        when :ret then (f.rtype = :strbuf; next) if f.rtype.nil? || f.rtype == :str || f.rtype == :strbuf
        when :aset, :fld_set then next if u.args[2] == v # stored as the cell: the slot type widens to :strbuf
        when :hset then next if u.args[2] == v && u.args[1] != v
        when :gset then next
        end
        d = Inst.new(:bufderef, [v]); d.ty = :str; d.block = u.block
        u.block.insts.insert(u.block.insts.index(u), d)
        swap_operand(u, v, d)
      end
    end

    # an operator with a Bignum operand: the other operand is lifted (coerce, int -> big) and
    # the op becomes a prelude call. Compares go through __big_cmp and test its sign.
    BIG_OPS = { add: :__big_add, sub: :__big_sub, mul: :__big_mul, div: :__big_div, mod: :__big_mod }.freeze
    def self.big_op(f, i)
      l, r = i.args.map { |v| big?(of(f, v)) ? v : coerce(f, i.block, i, v, BIG) } # lift the int operand now, so the callee is typed BIG from the start
      if i.op == :cmp
        c = Inst.new(:call, [fn(:__big_cmp), l, r]); c.ty = :int; c.block = i.block
        i.block.insts.insert(i.block.insts.index(i), c)
        z = Inst.new(:const, [0]); z.ty = :int; z.block = i.block; i.block.insts.insert(i.block.insts.index(i), z)
        i.args = [c, z] # cond unchanged: (a < b) is (cmp(a, b) < 0)
      else
        fn = fn(BIG_OPS.fetch(i.op))
        i.op = :call; i.args = [fn, l, r]; i.ty = BIG
      end
    end

    # Loop-carried integers that grow geometrically cannot be 64-bit honestly: a phi whose
    # back-edge value adds two things that both depend on it (fib), or multiplies something
    # that depends on it by anything but a constant 0/1 (q = q * k), becomes a Bignum. Counters
    # (i + 1) and sums of independent data (sum + a[i]) stay ints and keep their overflow trap.
    def self.promote_geometric(funcs)
      promoted = false
      funcs.each do |f|
        next if f.name.to_s.start_with?("__") # the preludes are written to fit
        f.blocks.each do |h|
          next unless h.name.to_s.start_with?("head")
          phis = h.phis.select { _1.ty == :int }
          next if phis.empty?
          back = ->(p) { p.args.reject { |(pred, _)| f.blocks.index(pred) < f.blocks.index(h) }.map(&:last) }
          # reach[p]: the header phis p's value depends on, through the loop body and other phis' back edges
          reach = phis.to_h { [_1, {}] }
          deps = ->(v, seen = {}) {
            next {} if !v.is_a?(Inst) || v.op == :const || v.op == :param || seen[v]
            seen[v] = true
            next({ v => true }.merge(reach[v])) if reach.key?(v)
            next {} if v.op == :phi
            v.args.map { |a| deps.(a.is_a?(Array) ? a[1] : a, seen) }.reduce({}) { _1.merge(_2) }
          }
          loop do
            grew = false
            phis.each do |p|
              d = back.(p).map { deps.(_1) }.reduce({}) { _1.merge(_2) }
              (grew = true; reach[p] = reach[p].merge(d)) if (d.keys - reach[p].keys).any?
            end
            break unless grew
          end
          # a phi the loop condition bounds (`while width < n`, n independent of it) stays an int
          bounded = ->(p) {
            c = h.term; cmp = c && c.op == :condbr && c.args[0].is_a?(Inst) && c.args[0].op == :cmp ? c.args[0] : nil
            next false unless cmp && %i[lt le gt ge].include?(cmp.cond)
            l, r = cmp.args
            (deps.(l)[p] && !deps.(r)[p]) || (deps.(r)[p] && !deps.(l)[p])
          }
          phis.each do |p|
            next if bounded.(p)
            back.(p).each do |v|
              next unless v.is_a?(Inst) && %i[add mul].include?(v.op)
              x, y = v.args
              hits = ->(o) { deps.(o)[p] }
              trivial = ->(o) { o.is_a?(Inst) && o.op == :const && [0, 1].include?(o.args[0]) }
              geometric = v.op == :add ? (hits.(x) && hits.(y)) : ((hits.(x) || hits.(y)) && !trivial.(x) && !trivial.(y))
              (p.ty = BIG; promoted = true) if geometric
            end
          end
        end
      end
      promoted
    end

    # an operator on a tagged scalar: the prelude dispatches on the tags.
    # cmp.eq/ne give a bool; the ordering compares and arithmetic give a :dyn
    # (Integer + Integer may be Float + ..., String + String is a String).
    DYN_OPS = { add: :__dyn_add, sub: :__dyn_sub, mul: :__dyn_mul, div: :__dyn_div,
                eq: :__dyn_eq, ne: :__dyn_ne, lt: :__dyn_lt, le: :__dyn_le, gt: :__dyn_gt, ge: :__dyn_ge }.freeze
    def self.dyn_op(f, i)
      name = i.op == :cmp ? DYN_OPS.fetch(i.cond) : DYN_OPS.fetch(i.op)
      fn = fn(name)
      fn.ptypes[0] = fn.ptypes[1] = :dyn
      i.op = :call; i.args = [fn, *i.args]; i.cond = nil
      i.ty = fn.rtype
    end

    # puts/p/inspect of a tagged scalar: the prelude dispatches on the tag
    def self.dyn_print(f, i)
      name = i.op == :inspect_v || i.op == :p_v ? :__dyn_inspect : :__dyn_to_s
      fn = fn(name)
      if i.op == :inspect_v # the value itself becomes the call
        i.op = :call; i.args = [fn, i.args[0]]; i.ty = :str
      else
        c = Inst.new(:call, [fn, i.args[0]]); c.block = i.block; c.ty = :str
        i.block.insts.insert(i.block.insts.index(i), c)
        i.args = [c]; i.op = i.op == :print_v ? :print_str : :puts_str
      end
    end

    # inspect of one value, by type: int -> to_s, float -> __float_to_s, str -> __quote
    def self.inspect_v(f, i)
      t = of(f, i.args[0])
      case t
      when :str then i.op = :call; i.args = [fn(:__quote), i.args[0]]
      when :float then i.op = :call; i.args = [fn(:__float_to_s), i.args[0]]
      when :int, :int? then i.op = :itos
      when :bool then i.op = :bool_to_s
      else
        if arr(t) then i.op = :call; i.args = [fn(:__arr_inspect), i.args[0]]
        else raise "inspect of #{t.inspect} not supported" end
      end
    end

    # :mcall name, recv, args -> :call Func / :fld_get / :fld_set
    def self.bind(f, i)
      name, recv, *args = i.args
      t = of(f, recv)
      if poly?(t) # one arm per class: [klass, kind, payload]; a class without the method traps if reached
        arms = t[1].map { |c| [@classes[c], *resolve(@classes[c], name, args.size, trap_missing: true)] }
        raise "no method #{name} on any of #{t[1].join(', ')}" if arms.all? { |(_, kind, _)| kind == :trap }
        i.op = :pcall; i.args = [arms, recv, *args]
        return
      end
      if name == :value && args.empty? && !(t.is_a?(Symbol) && @classes[t]) && !poly?(t) && t
        i.op = :nop; i.args = [recv]; i.ty = t; return # a finished Thread is its value (threads run at Thread.new)
      end
      if t == :int && (fn = fnq(:"__fd_#{name}")) # a file descriptor is an Integer: fd.puts, fd.write, fd.close
        i.op = :call; i.args = [fn, recv, *args]; return
      end
      if t == :int && %i[succ pred].include?(name) && args.empty? # Integer#succ / #pred
        c = Inst.new(:const, [1]); c.ty = :int; c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c)
        i.op = name == :succ ? :add : :sub; i.args = [recv, c]; return
      end
      if t == :str && (fn = fnq(:"__str_#{name.to_s.sub('?', '_p')}")) # String methods written in the prelude
        i.op = :call; i.args = [fn, recv, *args]; return
      end
      if arr(t) && (fn = fnq(:"__arr_#{name.to_s.sub('?', '_p')}") || fnq(:"__arr_#{name}"))
        i.op = :call; i.args = [fn, recv, *args]; return
      end
      return unless t.is_a?(Symbol) && (klass = @classes[t])
      kind, payload = resolve(klass, name, args.size, allow_missing: true)
      case kind
      when :fld_get then i.op = :fld_get; i.args = [recv, payload]
      when :fld_set then i.op = :fld_set; i.args = [recv, payload, args[0]]
      when :call then i.op = :call; i.args = [payload, recv, *args]
      when :missing # method_missing(name, *args): the name is a compile-time symbol, args packed
        i.op = :call; i.args = [payload, recv, sym_const(i, name), pack_args(i, args)]
      end
    end

    def self.sym_const(at, name)
      c = Inst.new(:const, [@lower.sym_id(name)]); c.ty = :sym; c.block = at.block
      at.block.insts.insert(at.block.insts.index(at), c); c
    end

    # *args as a fresh array built just before the call
    def self.pack_args(at, args)
      ins = ->(op, a, ty) { x = Inst.new(op, a); x.ty = ty; x.block = at.block; at.block.insts.insert(at.block.insts.index(at), x); x }
      n = ins.(:const, [args.size], :int)
      nilc = ins.(:const, [0], :nil)
      arr = ins.(:anew, [n, nilc], [:arr, nil])
      args.each_with_index { |a, k| arr = ins.(:aset, [arr, ins.(:const, [k], :int), a], nil) }
      arr
    end

    # send with a computed symbol: one arm per method of the class (and attrs)
    # whose arity matches; dispatch compares symbol ids
    def self.dsend(f, i)
      name_v, recv, *args = i.args
      t = of(f, recv)
      return unless t.is_a?(Symbol) && (klass = @classes[t])
      arms = []
      each_method(klass) do |mname, kind, payload, arity|
        next unless arity == args.size
        arms << [@lower.sym_id(mname), kind, payload]
      end
      i.op = :sendsw; i.args = [arms, name_v, recv, *args]
    end

    def self.each_method(klass, &b)
      seen = {}
      k = klass
      while k
        k.readers.each { |n, iv| next if seen[n]; seen[n] = true; b.(n, :fld_get, klass.ivar(iv), 0) }
        k.writers.each { |n, iv| next if seen[n]; seen[n] = true; b.(n, :fld_set, klass.ivar(iv), 1) }
        k.methods.each { |n, m| next if seen[n] || n == :initialize || n == :method_missing; seen[n] = true; b.(n, :call, m, m.params.size - 1) }
        k = k.superclass
      end
    end

    # [] / []= once the receiver's type is known
    def self.index(f, i)
      r = i.args[0]
      t = of(f, r)
      t ||= { hnew: [:hash, nil, nil], anew: [:arr, nil] }[r.op] if r.is_a?(Inst) # empty literal, nothing stored yet
      return unless t
      if arr(t) then i.op = i.op == :idx ? :aget : :aset
      elsif hsh(t) then i.op = i.op == :idx ? :hget : :hset
      elsif t == :str && i.op == :idx then i.op = :ssub; i.args << (c = Inst.new(:const, [1]); c.ty = :int; c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c); c) if i.args.size == 2
      else raise "[] on #{t.inspect}" end
    end

    def self.ancestor?(klass, cname)
      k = klass
      while k
        return true if k.name == cname
        k = k.superclass
      end
      false
    end

    def self.resolve(klass, name, nargs, allow_missing: false, trap_missing: false)
      if (iv = klass.find_reader(name)) && nargs == 0 then [:fld_get, klass.ivar(iv)]
      elsif (iv = klass.find_writer(name)) && nargs == 1 then [:fld_set, klass.ivar(iv)]
      elsif (m = klass.find_method(name)) then [:call, m]
      elsif allow_missing && (mm = klass.find_method(:method_missing)) then [:missing, mm]
      elsif trap_missing then [:trap, nil] # Ruby's NoMethodError, if this arm ever runs
      else raise "no method #{name} on #{klass.name}"
      end
    end

    def self.sw_arm_type(f, i, kind, payload)
      case kind
      when :fld_get then @ivars[of(f, i.args[2])][payload]
      when :fld_set then of(f, i.args[3])
      when :call then payload.rtype
      end
    end

    # what a pcall arm answers
    def self.arm_type(f, i, arm)
      klass, kind, payload = arm
      case kind
      when :fld_get then @ivars[klass.name][payload]
      when :fld_set then of(f, i.args[2])
      when :call then payload.rtype
      end
    end

    def self.infer(f, i)
      a = i.args
      case i.op
      when :const then %i[nil sym bool lambda].include?(i.ty) ? i.ty : :int
      when :fconst then :float
      when :sconst, :scat, :sappend, :itos, :bool_to_s, :chr, :sdup, :salloc then :str
      when :rawld8 then :int
      when :mkbuf, :bufappend then :strbuf
      when :bufderef then :str
      when :apop then (t = of(f, a[0])) && arr(t) ? t[1] : nil
      when :hcap, :gcepoch, :hsave, :sys then :int
      when :hkey_at then (t = of(f, a[0])) && hsh(t) ? t[1] : nil
      when :hval_at then (t = of(f, a[0])) && hsh(t) ? t[2] : nil
      when :seq, :sne, :scmp then :bool
      when :puts_i, :puts_str, :puts_bool, :puts_opt, :puts_nil, :print_i, :print_str, :p_str then :int
      when :p_v, :print_v then of(f, a[0]) && :int
      when :inspect_v then of(f, a[0]) && :str
      when :idx, :idx_set, :dsend, :mcall then nil
      when :lshift_or_append then (t = of(f, a[0])) && (t == :int ? :int : t)
      when :to_s then (t = of(f, a[0])) && (t == :str ? :str : narrow(t) == :int ? :str : nil)
      when :puts_v then of(f, a[0]) && :int
      when :add, :sub, :mul, :div
        l, r = of(f, a[0]), of(f, a[1])
        l && r ? join(narrow(l), narrow(r)) : nil # both sides known, or no guess: a str * n is not an int
      when :and, :or then (of(f, a[0]) == :bool && of(f, a[1]) == :bool) ? :bool : :int
      when :xor, :shl, :shr, :mod, :to_i, :alen, :ipow, :rawld, :rawld32, :gbase, :adrlbl, :rawst, :rawmmap, :trap, :fbits, :lsr, :clz, :umulh, :wmul, :wadd, :wsub then :int
      when :cmp, :ucmp, :isa, :isa_dyn then :bool
      when :box then :dyn
      when :unbox then a[1]
      when :dyn_tag then :int
      when :pcall then a[0].map { arm_type(f, i, _1) }.reduce(nil) { join(_1, _2) }
      when :sendsw then a[0].map { |(_, kind, payload)| sw_arm_type(f, i, kind, payload) }.reduce(nil) { join(_1, _2) }
      when :dsend then nil
      when :to_f, :fsqrt, :libm, :clock then :float
      when :eputs_v, :eputs_str then :int
      when :pow then join(narrow(of(f, a[0])), narrow(of(f, a[1]))) == :float ? :float : :int
      when :seq_char then :bool
      when :anew then (t = of(f, a[1])) && t != :nil ? [:arr, t] : [:arr, nil] # partial until a store
      when :hnew then [:hash, nil, nil]
      when :hget then (t = of(f, a[0])) && hsh(t) ? nullable(t[2]) : nil
      when :hset then of(f, a[0])
      when :hkey then :bool
      when :hkeys then (t = of(f, a[0])) && hsh(t) ? [:arr, t[1]] : nil
      when :ssub then :str
      when :aget then (t = of(f, a[0])) && arr(t) ? nullable(t[1]) : nil
      when :aset then of(f, a[0])
      when :phi then a.map { of(f, _2) }.reduce(nil) { join(_1, _2) }
      when :call then a[0].rtype
      when :itof then :float
      when :onew then a[0].name
      when :fld_get then (k = of(f, a[0])) && ivar_type(k, a[1])
      when :fld_set then of(f, a[2])
      when :gget then @consts[a[0]]
      when :gset then of(f, a[1])
      end
    end

    # an ivar's type: joined over the class and its subclasses (same offset)
    def self.ivar_type(k, ix)
      klass = @classes[k] or raise "ivar_type: receiver typed #{k.inspect}"
      [klass, *@classes.values.select { |c| c.superclass == klass }].map { @ivars[_1.name][ix] }.reduce(nil) { join(_1, _2) }
    end

    # insert itof where an int flows into a float position, and box where a
    # typed value flows into a :dyn position
    # Representation changes where a value meets a slot of a wider type: int -> float
    # (itof), typed -> :dyn (box), int -> Bignum (__big_from_int). One walk over every
    # slot position; each coercion is a rule from (value type, slot type) to an instruction.
    def self.convert(f)
      f.blocks.each do |b|
        b.insts.dup.each do |i|
          # operators: a float or Bignum operand lifts the other
          case i.op
          when :add, :sub, :mul, :div, :cmp
            if i.args.any? { of(f, _1) == :float }
              i.args.map! { |v| of(f, v) == :int ? coerce(f, b, i, v, :float) : v }
              i.cond = :"f#{i.cond}" if i.op == :cmp
            end
          when :fsqrt then i.args[0] = coerce(f, b, i, i.args[0], :float)
          when :libm then i.args[1] = coerce(f, b, i, i.args[1], :float)
          when :pow
            if i.ty == :float then i.args.map! { |v| coerce(f, b, i, v, :float) }; i.op = :fpow
            else i.op = :ipow end
          end
          each_slot(f, i) { |v, dest, set| set.(coerce(f, b, i, v, dest)) }
        end
        b.phis.each do |p|
          p.args.map! { |(pred, v)| [pred, coerce(f, pred, pred.term, v, p.ty)] }
        end
      end
    end

    # like each_flow, with a setter for the operand position
    def self.each_slot(f, i)
      case i.op
      when :aset
        t = of(f, i.args[0]); yield i.args[2], t[1], ->(w) { i.args[2] = w } if arr(t)
      when :hset
        t = of(f, i.args[0])
        if hsh(t) then yield i.args[1], t[1], ->(w) { i.args[1] = w }; yield i.args[2], t[2], ->(w) { i.args[2] = w } end
      when :fld_set then yield i.args[2], ivar_type(of(f, i.args[0]), i.args[1]), ->(w) { i.args[2] = w }
      when :gset then yield i.args[1], @consts[i.args[0]], ->(w) { i.args[1] = w }
      when :call then i.args[1..].each_with_index { |v, k| yield v, i.args[0].ptypes[k], ->(w) { i.args[k + 1] = w } }
      when :ret then yield i.args[0], f.rtype, ->(w) { i.args[0] = w }
      end
    end

    # the value v as the slot type dest, or v itself when no change of representation is needed
    def self.coerce(f, blk, before, v, dest)
      t = of(f, v)
      return v if t.nil? || dest.nil? || t == dest
      c = case
          when dest == :float && t == :int then Inst.new(:itof, [v]).tap { _1.ty = :float }
          when dest == :dyn && t != :dyn then Inst.new(:box, [v, t]).tap { _1.ty = :dyn }
          when big?(dest) && %i[int int?].include?(t) then Inst.new(:call, [fn(:__big_from_int), v]).tap { _1.ty = BIG }
          else return v
          end
      c.block = blk
      blk.insts.insert(blk.insts.index(before), c)
      c
    end
  end
end
