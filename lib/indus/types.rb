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
      return :dyn if (a == :nil && (b == :float || b == :bool || b == :sym)) || (b == :nil && (a == :float || a == :bool || a == :sym)) # no spare bit pattern in these: tag
      return b if a == :nil
      return a if b == :nil
      return :float if (a == :int && b == :float) || (a == :float && b == :int)
      intish = ->(t) { t == :int || t == :int? || t.nil? }
      return BIG if (big?(a) && (intish.(b) || arr(b) && intish.(b[1]))) || (big?(b) && (intish.(a) || arr(a) && intish.(a[1])))
      return :int? if (a == :int? && b == :nil) || (a == :nil && b == :int?)
      return :strbuf if (a == :str && b == :strbuf) || (a == :strbuf && b == :str) # a string that grew a stable handle
      return [:arr, join_elem(a[1], b[1])] if arr(a) && arr(b)
      return [:cell, join(a[1], b[1])] if cell?(a) && cell?(b)
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
    def self.prelude?(f) = f.name.to_s.start_with?("__") && !f.name.to_s.start_with?("__lambda") # the runtime's functions (not a user's closure)
    def self.of(f, v) = v.op == :param ? f.ptypes[f.params.index(v)] : v.ty
    def self.arr(t) = t.is_a?(Array) && t[0] == :arr
    # Bignum: an int array ([sign, limbs...], lib/indus/rt/big.rb) marked so that operators
    # and printing go to __big_*. Array-shaped for everything the prelude does to it.
    BIG = [:arr, :int, :big].freeze
    def self.big?(t) = t == BIG
    # does a value of this type hold a heap pointer the collector must follow?
    def self.heap_pointer?(t)
      return true if t == :str || t == :dyn || t == :strbuf
      return true if t.is_a?(Array) && %i[arr hash poly cell].include?(t[0])
      t.is_a?(Symbol) && !!@classes&.[](t)
    end
    def self.hsh(t) = t.is_a?(Array) && t[0] == :hash
    def self.cell?(t) = t.is_a?(Array) && t[0] == :cell # a shared local: one word on the heap

    def self.reset! = (@ivars = nil; @consts = nil; @instances = nil; @instancings = nil)
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
    class << self; attr_accessor :standalone; end # no libc: Math goes to the Ruby libm (rt/libm.rb)

    def self.run(funcs, classes, lower = nil)
      @classes = classes; @lower = lower || @lower
      # program-wide state; the resident compiler re-runs inference for one
      # function against the tables the whole program built
      @ivars ||= Hash.new { |h, k| h[k] = {} } # class name -> ivar index -> type
      classes.each_value { |k| (k.nullable_ivars || []).each { |iv| ix = k.ivars.index(iv); @ivars[k.name][ix] = join(@ivars[k.name][ix], :nil) if ix } } # @x ||= v: nil until then
      @consts ||= {}
      @funcs_live = funcs
      funcs.each { |f| next if f.ptypes; f.ptypes = Array.new(f.params.size); f.rtype = nil; f.ptypes[0] = self_type(f.cls) if f.cls }
      @exc_type = nil # the type of a rescued value: whatever any raise in the program raises
      @no_defer = false
      @seams = funcs.any? { |f| f.all.any? { _1.op == :seam } }
      rounds = 0
      loop do
        changed = false
        raise "type inference does not converge (#{rounds} rounds): a rewrite keeps undoing another's work; refusing rather than looping" if (rounds += 1) > 400
        mark_unused_results(funcs) if funcs.any? { _1.name == :main } # a whole-program fact; the resident compiler sees one function
        funcs.each do |pr| # method versions behind one slot: one signature for all
          next unless pr.versions
          group = [pr, *pr.versions]
          pr.params.each_index { |k| t = group.map { _1.ptypes[k] }.reduce { |a, b| join(a, b) }; group.each { |g| (g.ptypes[k] = t; changed = true) if t && g.ptypes[k] != t } }
          rt = group.map(&:rtype).reduce { |a, b| join(a, b) }
          group.each { |g| (g.rtype = rt; changed = true) if rt && g.rtype != rt }
        end
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
            # a container cell used where the container itself is wanted (a use created after the
            # parameter became a cell): load through the cell right here
            unless %i[cell_get cell_set cell_new phi call pcall ret mcall fld_set aset hset gset].include?(i.op)
              i.args.each_with_index do |a, k|
                next unless a.is_a?(Inst) && (ct = of(f, a)) && cell?(ct) && (arr(ct[1]) || hsh(ct[1]))
                g = Inst.new(:cell_get, [a]); g.ty = ct[1]; g.block = i.block; i.block.insts.insert(i.block.insts.index(i), g)
                i.args[k] = g; changed = true
              end
            end
            if i.op == :mcall && (ct = of(f, i.args[1])) && cell?(ct) && (arr(ct[1]) || hsh(ct[1])) # a method on the container inside a cell
              g = Inst.new(:cell_get, [i.args[1]]); g.ty = ct[1]; g.block = i.block; i.block.insts.insert(i.block.insts.index(i), g)
              i.args[1] = g; changed = true
            end
            if i.op == :todyn && (vt = of(f, i.args[0])) # tag by what the operand turned out to be
              if vt == :dyn then i.op = :nop else i.op = :box; i.args = [i.args[0], vt] end
              i.ty = :dyn; changed = true
            end
            each_flow(f, i) do |v, dest|
              next unless v.is_a?(Inst)
              if @settled && dest == :int? && v.op == :const && v.ty == :nil then v.args[0] = INT_NIL; v.ty = :int; changed = true end # nil in a nullable int slot is the sentinel (settled: the slot might still widen to a pointer type)
              changed = true if (dest == :dyn || arr(dest) && dest[1] == :dyn || hsh(dest) && dest[2] == :dyn) && widen_elements_to_dyn(f, v, dest)
              # a typed container entering a tagged slot it does not own (an element read out of
              # another container): the tag promises tagged elements, so a copy that has them goes
              # instead. Inserted here, during typing, so the copier is typed like any other call.
              if dest == :dyn && (vt = of(f, v)).is_a?(Array) && %i[hval_at hkey_at aget hget apop].include?(v.op) &&
                 (arr(vt) && vt[1] && vt[1] != :dyn || hsh(vt) && vt[1] && (vt[1] != :dyn || vt[2] != :dyn))
                cp = Inst.new(:call, [fn(arr(vt) ? :__box_elems_arr : :__box_elems_hash), v])
                cp.ty = arr(vt) ? [:arr, :dyn] : [:hash, :dyn, :dyn]
                cp.block = i.block; i.block.insts.insert(i.block.insts.index(i), cp)
                swap_operand(i, v, cp); changed = true
              end
              changed = true if dest == :strbuf && of(f, v) == :str && make_cell(f, v, i)
            end
            if i.op == :raise && (t = of(f, i.args[0])) && join(@exc_type, t) != @exc_type then @exc_type = join(@exc_type, t); changed = true end
            bind(f, i) if i.op == :mcall
            if i.op == :call && (c = i.args[0]).cls && poly?(pt = of(f, i.args[1])) && !c.name.to_s.end_with?("#initialize")
              # bound to one class while the receiver was that class; it has since widened to a set --
              # unless every class in the set resolves to this very function (then the call stands)
              mn = c.name.to_s.split("#").last.sub(/'+\z/, "").to_sym
              same = pt[1].all? { |cn| @classes[cn] && (kind, payload = resolve(@classes[cn], mn, i.args.size - 2, allow_missing: true); kind == :call && payload.equal?(c)) }
              unless same then i.op = :mcall; i.args = [mn, *i.args[1..]]; bind(f, i); changed = true end
            end
            if i.op == :call && i.args[0].name == :__arr_inspect && of(f, i.args[1]) == :dyn # the array became a tagged value: inspect by tag
              i.args[0] = fn(:__dyn_inspect); changed = true
            end
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
            # growth of an array through a parameter (push, insert at the end) must be seen by the
            # caller: the parameter becomes a cell holding the array (notes/53), the caller wraps
            # its array in a cell at the origin, and both sides read and write through it
            if (i.op == :aset && arr(of(f, i.args[0])) && i.args[1].op == :alen || i.op == :lshift_or_append && arr(of(f, i.args[0])) || i.op == :hset && hsh(of(f, i.args[0]))) && !prelude?(f) && (p = param_origin(f, i.args[0]))
              arr_cell_param(f, p); changed = true # a hash store may rehash into a new handle: the same treatment
            end
            if i.op == :call && !generic?(i.args[0]) # an argument flowing into an array-cell parameter is made a cell at its origin
              callee = i.args[0]
              i.args[1..].each_with_index do |v, k|
                next unless (pt = callee.ptypes[k]) && cell?(pt) && (arr(pt[1]) || hsh(pt[1]))
                if arr(of(f, v)) || hsh(of(f, v)) then make_arr_cell(f, v, i); changed = true
                elsif (vt = of(f, v)) && cell?(vt) && join(vt, pt) != vt # what the callee stores comes back to the caller's cell
                  nt = join(vt, pt)
                  v.op == :param ? f.ptypes[f.params.index(v)] = nt : v.ty = nt
                  changed = true
                end
              end
            end
            if %i[add sub mul div mod].include?(i.op) && classes_of(of(f, i.args[0])) # obj + v: the class's own operator (the lowering guessed arithmetic)
              nm = { add: :+, sub: :-, mul: :*, div: :/, mod: :% }.fetch(i.op)
              i.op = :mcall; i.args = [nm, *i.args]; i.ty = nil; bind(f, i); changed = true
            end
            if i.op == :lshift_or_append && classes_of(of(f, i.args[0])) # obj << v: the class's own <<
              i.op = :mcall; i.args = [:<<, *i.args]; i.ty = nil; bind(f, i); changed = true
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
            if i.op == :cmp && (t0 = of(f, i.args[0])) && (t0.is_a?(Symbol) && @classes[t0] || poly?(t0))
              # comparing objects: an ordering is the class's own operator (Comparable from the prelude,
              # or user-defined); == / != too when the class defines ==, else identity
              has_eq = (classes_of(t0) || []).any? { @classes[_1].find_method(:==) }
              has_eq = false if i.args[1].op == :const && i.args[1].ty == :nil # x == nil / x.nil?: identity against nil, never the class's ==
              if %i[lt le gt ge].include?(i.cond) || has_eq && %i[eq ne].include?(i.cond)
                neg = i.cond == :ne
                i.op = :mcall; i.args = [{ lt: :<, le: :<=, gt: :>, ge: :>=, eq: :==, ne: :== }.fetch(i.cond), *i.args]; i.cond = nil; bind(f, i); changed = true
                if neg # a != b is !(a == b)
                  c = Inst.new(i.op, i.args.dup); c.ty = :bool; c.block = i.block; c.cond = i.cond; i.block.insts.insert(i.block.insts.index(i), c)
                  z = Inst.new(:const, [0]); z.ty = :int; z.block = i.block; i.block.insts.insert(i.block.insts.index(i), z)
                  i.op = :cmp; i.args = [c, z]; i.cond = :eq
                end
              end
            end
            if i.op == :cmp && arr(of(f, i.args[0])) && arr(of(f, i.args[1])) && %i[lt le gt ge].include?(i.cond) # arrays order lexicographically
              c = Inst.new(:call, [fn(:__arr_cmp), *i.args]); c.ty = :int; c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c)
              z = Inst.new(:const, [0]); z.ty = :int; z.block = i.block; i.block.insts.insert(i.block.insts.index(i), z)
              i.args = [c, z]; changed = true
            end
            if i.op == :cmp && arr(of(f, i.args[0])) && arr(of(f, i.args[1])) && %i[eq ne].include?(i.cond) # Array#== is elementwise
              l, r = i.args; fn = fn(:__arr_eq)
              c = Inst.new(:call, [fn, l, r]); c.ty = :bool; c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c)
              z = Inst.new(:const, [0]); z.ty = :int; z.block = i.block; i.block.insts.insert(i.block.insts.index(i), z)
              i.args = [c, z]; i.cond = i.cond == :eq ? :ne : :eq; changed = true # (a == b) is (eq_result != 0)
            end
            if %i[add sub mul div mod cmp].include?(i.op) && (big?(of(f, i.args[0])) || big?(of(f, i.args[1]))) && !@no_big_rewrite
              big_op(f, i); changed = true
            end
            if %i[add sub and or mul].include?(i.op) && arr(of(f, i.args[0])) # a + b, a - b, a & b, a | b, a * n on arrays
              fnm = { add: :__arr_plus, sub: :__arr_minus, and: :__arr_and, or: :__arr_or, mul: :__arr_times }.fetch(i.op)
              fn = fn(fnm); i.op = :call; i.args = [fn, *i.args]; i.ty = nil; changed = true
            end
            if @settled && i.op == :is_sym && ((t = of(f, i.args[0])) || true) then i.op = :const; i.args = [t == :sym ? 1 : 0]; i.ty = :bool; changed = true end
            # is_dyn folds early for kinds that cannot still widen into :dyn (strings, containers, objects,
            # dyn itself); an integer-ish operand may yet become tagged, so it waits for the settled round
            # is_dyn folds to true as soon as the operand is :dyn (a type that never narrows); false only once
            # settled. A branch on the folded test is cut right away, so the dead arm's calls shape nothing.
            if i.op == :is_arr && (t = of(f, i.args[0]))
              i.op = :const; i.args = [arr(t) ? 1 : 0]; i.ty = :bool; changed = true
              fold_branches_on(f, i); next
            end
            if i.op == :is_dyn && ((t = of(f, i.args[0])) == :dyn || @settled)
              i.op = :const; i.args = [t == :dyn ? 1 : 0]; i.ty = :bool; changed = true
              fold_branches_on(f, i); next
            end
            if false then i.op = :const; i.args = [t == :dyn ? 1 : 0]; i.ty = :bool; changed = true end
            if i.op == :to_f && of(f, i.args[0]) == :str then i.op = :call; i.args = [fn(:__str_to_f), i.args[0]]; i.ty = :float; changed = true end # "3.5".to_f
            if i.op == :mul && of(f, i.args[0]) == :str # "ab" * n
              fn = fn(:__str_times); i.op = :call; i.args = [fn, *i.args]; i.ty = :str; changed = true
            end
            if true # by-type rewrites: the dyn-driven ones run as soon as a :dyn appears (dyn never narrows); the scalar-driven ones wait for @settled
              if @settled && %i[alen apop].include?(i.op) && classes_of(of(f, i.args[0])) # length/pop guessed builtin at lowering on what is an object: the class's method
                nm = i.op == :alen ? :length : :pop
                nm = :size if nm == :length && !classes_of(of(f, i.args[0])).any? { @classes[_1].find_method(:length) || @classes[_1].find_reader(:length) }
                i.op = :mcall; i.args = [nm, i.args[0]]; i.ty = nil; bind(f, i); changed = true
              end
              if i.op == :alen && of(f, i.args[0]) == :dyn # length of a tagged value: by tag
                i.op = :call; i.args = [fn(:__dyn_length), i.args[0]]; i.ty = :int; changed = true
              end
              if @settled && %i[puts_v p_v print_v].include?(i.op) && (t = of(f, i.args[0])) && (arr(t) || hsh(t)) # p arr -> inspect; puts arr -> one element per line
                name = i.op == :puts_v && arr(t) ? :__arr_lines : arr(t) ? :__arr_inspect : t[1] == :sym ? :__hash_inspect_sym : t[1] == :dyn ? :__hash_inspect_dyn : :__hash_inspect
                c = Inst.new(:call, [fn(name), i.args[0]]); c.ty = :str; c.block = i.block
                i.block.insts.insert(i.block.insts.index(i), c); i.args = [c]; i.op = i.op == :print_v ? :print_str : :puts_str; changed = true
              end
              if @settled && i.op == :p_v && of(f, i.args[0]) == :str # p "s": String#inspect, escapes included
                c = Inst.new(:call, [fn(:__quote), i.args[0]]); c.ty = :str; c.block = i.block
                i.block.insts.insert(i.block.insts.index(i), c); i.args = [c]; i.op = :puts_str; changed = true
              end
              if @settled && %i[puts_v p_v print_v].include?(i.op) && (t = of(f, i.args[0])) && (classes_of(t)) # puts obj: its to_s (or "#<Klass>")
                cs = classes_of(t)
                want = i.op == :p_v && cs.any? { @classes[_1].find_method(:inspect) } ? :inspect : :to_s # p obj: its inspect when it has one
                if cs.any? { @classes[_1].find_method(want) }
                  c = Inst.new(:mcall, [want, i.args[0]]); c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c); bind(f, c)
                else
                  c = Inst.new(:sconst, ["#<#{cs.first}>"]); c.ty = :str; c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c)
                end
                i.args = [c]; i.op = i.op == :print_v ? :print_str : :puts_str; changed = true
              end
              if i.op == :respond_to_q && (t = of(f, i.args[0])) && @settled
                nm = i.args[1]
                has = ->(cn) { k = @classes[cn]; k && (k.find_method(nm) || k.find_reader(nm) || k.find_writer(nm)) && !k.hidden&.[](nm) }
                builtin = ->(fam) { prelude_method(fam, nm, 0) || prelude_method(fam, nm, 1) || %i[to_s inspect class nil? == != hash size length].include?(nm) }
                if (cs = classes_of(t))
                  yes = cs.select { has.(_1) }
                  if yes.empty? then i.op = :const; i.args = [0]; i.ty = :bool
                  elsif yes.size == cs.size then i.op = :const; i.args = [1]; i.ty = :bool
                  else i.op = :isa_tags; i.args = [i.args[0], yes.map { @classes[_1].id }]; i.ty = :bool end
                elsif t == :dyn # by tag: a user object answers by class id, a builtin by its family's helpers
                  ids = @classes.values.select { |k| k.tagged && has.(k.name) }.map(&:id)
                  fams = { 2 => "str", 4 => "arr", 6 => "hash" }.select { |_, fm| builtin.(fm) }.keys
                  fams << 1 if builtin.("num")
                  c1 = Inst.new(:const, [0]); c1.ty = :int; c1.block = i.block; i.block.insts.insert(i.block.insts.index(i), c1) # placeholder kept simple: refuse on mixed answers
                  raise "respond_to?(:#{nm}) on a tagged value: not supported" if !ids.empty? || !fams.empty? && fams.size != 4
                  i.op = :const; i.args = [fams.empty? ? 0 : 1]; i.ty = :bool
                else
                  fm = t == :str ? "str" : arr(t) ? "arr" : hsh(t) ? "hash" : %i[int float].include?(t) ? "num" : nil
                  i.op = :const; i.args = [fm && builtin.(fm) ? 1 : 0]; i.ty = :bool
                end
                changed = true
              end
              if i.op == :raise_any && (t = of(f, i.args[0])) && (t == :str || classes_of(t) || t == :dyn)
                raise "#{f.name}: raise of a value that may be a String or an exception object (tagged): not supported" if t == :dyn
                if t == :str # raise "message": a RuntimeError around it
                  k = @classes[:RuntimeError]; o = Inst.new(:onew, [k]); o.ty = :RuntimeError; o.block = i.block; i.block.insts.insert(i.block.insts.index(i), o)
                  c = Inst.new(:call, [k.find_method(:initialize), o, i.args[0]]); c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c)
                  old = i.args[0]; i.args = [o]
                  i.block.insts.each { |u| u.args[1] = o if u.op == :call && u.args[0].name == :__uncaught && u.args[1].equal?(old) } # the fall-through report takes the object too
                end
                i.op = :raise; changed = true
              end
              if @settled && %i[add sub mul div mod].include?(i.op) && coerce_error(f, i) then changed = true end # 1.5 + "s": TypeError at run time
              if @settled && %i[puts_v p_v print_v].include?(i.op) && of(f, i.args[0]) == :sym # puts :a -> "a"; p :a -> ":a"
                c = Inst.new(:call, [fn(i.op == :p_v ? :__sym_inspect : :__sym_name), i.args[0]]); c.ty = :str; c.block = i.block
                i.block.insts.insert(i.block.insts.index(i), c); i.args = [c]; i.op = i.op == :print_v ? :print_str : :puts_str; changed = true
              end
              if @settled && i.op == :to_s && (t = of(f, i.args[0])) # to_s by type; a prelude call must be made here, so it gets typed
                case t
                when :sym then i.op = :call; i.args = [fn(:__sym_name), i.args[0]]; i.ty = :str; changed = true
                when :str then i.op = :str_or_empty; i.ty = :str; changed = true # a nil in a String slot (the 0 word) has to_s ""
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
              if %i[idx idx_set].include?(i.op) && of(f, i.args[0]) == :dyn && of(f, i.args[1]) # v[k] / v[k] = x on a tagged value: by tag at run time (string, array or hash)
                kt = of(f, i.args[1])
                if kt != :int && kt != :int? && kt != :dyn # a non-integer key: a hash (a tagged key is decided at run time)
                  c = Inst.new(:call, [fn(:__dyn_hash), i.args[0]]); c.ty = [:hash, :dyn, :dyn]; c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c)
                  i.args[0] = c
                else
                  nm = i.op == :idx ? (kt == :dyn ? :__dyn_idx_dyn : :__dyn_idx) : (kt == :dyn ? :__dyn_idx_set_dyn : :__dyn_idx_set)
                  g = fn(nm)
                  g.ptypes[0] = :dyn; g.ptypes[1] = :dyn if kt == :dyn
                  g.ptypes[2] = :dyn if i.op == :idx_set # the stored value is tagged for the by-tag store
                  i.op = :call; i.args = [g, *i.args]; i.ty = :dyn
                end
                changed = true
              end
              if %i[aget aset alen apop].include?(i.op) && of(f, i.args[0]) == :dyn # a tagged value used as an array: unbox (trapping on another tag)
                c = Inst.new(:call, [fn(:__dyn_arr), i.args[0]]); c.ty = [:arr, :dyn]; c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c)
                i.args[0] = c; changed = true
              end
              if i.op == :alen && hsh(of(f, i.args[0])) then i.op = :hcap; changed = true end # h.size guessed as an array length (hcap: the entry count)
              if %i[aget alen].include?(i.op) && hsh(of(f, i.args[0])) # a hash iterated as an array (the lowering could not tell): its pairs
                h = i.args[0]
                pairs = (@pairs_of ||= {})[h] ||= begin
                  c = Inst.new(:call, [fn(:__hash_to_a), h]); c.ty = [:arr, [:arr, :dyn]]; c.block = h.op == :param ? f.entry : h.block
                  at = h.op == :param || h.op == :phi ? 0 : h.block.insts.index(h) + 1
                  c.block.insts.insert(at, c); c
                end
                i.args[0] = pairs; changed = true
              end
              if %i[hget hset hkey hkeys hcap hkey_at hval_at].include?(i.op) && of(f, i.args[0]) == :dyn
                c = Inst.new(:call, [fn(:__dyn_hash), i.args[0]]); c.ty = [:hash, :dyn, :dyn]; c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c)
                i.args[0] = c; changed = true
              end
              if %i[and or xor shl shr mod].include?(i.op) && i.args.any? { of(f, _1) == :dyn } # integer-only operators: a tagged operand is unboxed (trapping on a non-integer)
                if i.op == :mod then dyn_op(f, i)
                else
                  i.args = i.args.map { |a| of(f, a) == :dyn ? (c = Inst.new(:call, [fn(:__dyn_int), a]); c.ty = :int; c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c); c) : a }
                end
                changed = true
              end
              # integer positions of the raw and container ops: a tagged index is unboxed
              int_slots = { aget: [1], aset: [1], ssub: [1, 2], rawst8: [1, 2], rawld8: [1], seq_char: [1] }[i.op]
              int_slots&.each do |k|
                next unless (a = i.args[k]).is_a?(Inst) && of(f, a) == :dyn
                c = Inst.new(:call, [fn(:__dyn_int), a]); c.ty = :int; c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c)
                i.args[k] = c; changed = true
              end
              dyn_print(f, i) if %i[puts_v p_v print_v inspect_v].include?(i.op) && of(f, i.args[0]) == :dyn
              # irreversible: a scalar may still widen to :dyn (a string element becoming tagged), so scalars wait for
              # the settled round; containers and objects go as soon as their type is known
              if @settled && i.op == :call && i.args[0].name.to_s.start_with?("__arr_flatten") && !i.args[0].name.to_s.include?("nested") &&
                 (at = of(f, i.args[1])) && arr(at) && at[1] && at[1] != :dyn # the elements are known: no tag test, no recursion
                i.args[0] = fn(arr(at[1]) ? :__arr_flatten_nested : :__arr_dup); i.ty = nil; i.bound_to = nil
                f.all.each { |u| u.ty = nil if (u.op == :phi ? u.args.map(&:last) : u.args).include?(i) } # what the old result shaped re-derives
                changed = true
              end
              inspect_v(f, i) if i.op == :inspect_v && (t = of(f, i.args[0])) && (@settled || ((classes_of(t) || t == :dyn) && t != :nil))
            end
            index(f, i) if i.op == :idx || i.op == :idx_set
            if standalone && (i.op == :libm || i.op == :pow && i.args.any? { of(f, _1) == :float }) # no libc: the Ruby libm
              name = i.op == :libm ? :"__libm_#{i.args[0]}" : :__libm_pow
              args = i.op == :libm ? i.args[1..] : i.args
              args = args.map { |v| coerce(f, i.block, i, v, :float) }
              i.op = :call; i.args = [fn(name), *args]; changed = true
            end
            t = infer(f, i)
            was = i.ty
            if i.op == :call && generic?(i.args[0]) && i.bound_to && !i.bound_to.equal?(i.args[0])
              i.ty = t; i.bound_to = i.args[0]; changed = true # re-instanced: the new instance's result replaces the old one's (exact, not joined)
            else
              i.bound_to = i.args[0] if i.op == :call && generic?(i.args[0])
              set.(i.ty, t) { i.ty = _1 }
            end
            bufferize(f, i) if i.ty == :strbuf && was != :strbuf # the cell now flows through this value (phi, call result, ...)
            case i.op
            when :call
              callee = i.args[0]
              if generic?(callee) && clashes?(callee, i.args[1..].map { of(f, _1) }) # a call rewritten into a generic this very visit
                callee = i.args[0] = instance_for(callee, i.args[1..].map { of(f, _1) }, funcs); changed = true
                # the old callee's result shaped this value and (inside a generic) this function's result; both re-derive
                i.ty = nil
                if generic?(f) then f.rtype = nil; funcs.each { |g| g.all.each { |u| u.ty = nil if u.op == :call && u.args[0].equal?(f) } } end
              end
              # a builtin family method bound while the receiver's type was provisional: if the receiver is now
              # another kind (a tagged value, a string where an array was guessed), undo the binding and rebind
              if !ENV["NOREBIND"] && !@settled && callee.name == :__str_set_at && of(f, i.args[1]) == :dyn && !prelude?(f) # s[i] = v bound as a string store while s was provisionally a string
                i.op = :idx_set; i.args = i.args[1..]; i.ty = nil; i.bound_to = nil; changed = true
                forget_params(callee, funcs); next
              end
              if !@settled && i.routed && %i[sort min max].include?(i.routed) && callee.name.to_s =~ /\A__arr_(sort|min|max)(\$\d+)?\z/ && (rt = of(f, i.args[1])) && arr(rt) && rt[1] == :sym
                i.args[0] = fn(:"__arr_#{i.routed}_sym"); i.ty = nil; i.bound_to = nil; changed = true; next # symbols order by name, bound while the element type was unknown
              end
              if !@settled && i.routed && (fm = callee.name.to_s[/\A__(str|arr|hash|num)_/, 1]) && (rt = of(f, i.args[1])) && !prelude?(f)
                kind_now = rt == :str ? "str" : arr(rt) ? "arr" : hsh(rt) ? "hash" : %i[int int? float].include?(rt) ? "num" : nil
                if kind_now != fm && (rt == :dyn || kind_now)
                  mn = i.routed
                  i.op = :mcall; i.args = [mn, *i.args[1..]]; i.ty = nil; i.bound_to = nil; i.routed = nil; bind(f, i); changed = true
                  forget_params(callee, funcs); next
                end
              end
              i.args[1..].each_with_index { |a, k| (make_arr_cell(f, a, i); changed = true) if (pt = callee.ptypes[k]) && cell?(pt) && (arr(pt[1]) && arr(of(f, a)) || hsh(pt[1]) && hsh(of(f, a))) } # the callee grows this container: pass a cell
              unless generic?(callee) && deferred_generic?(callee, i.args[1..].map { of(f, _1) })
                i.args[1..].each_with_index { |a, k| set.(callee.ptypes[k], of(f, a)) { callee.ptypes[k] = _1 } unless k == 0 && callee.cls } # self is the defining class, whatever subclass arrives
              end
            when :pcall
              arms, recv, *args = i.args
              # the receiver's class set may have grown since this dispatch was built: add the new classes' arms
              if (rt = of(f, recv)) && (cs = classes_of(rt)) && (missing = cs - arms.map { |(k, _, _)| k.name }).any?
                mname = arms.find { |(_, kd, pl)| kd == :call }&.then { |(_, _, pl)| pl.name.to_s.split("#").last.delete("'").to_sym }
                mname ||= (i.respond_to?(:mname) && i.mname)
                if mname
                  missing.each { |c| arms << [@classes[c], *resolve(@classes[c], mname, args.size, trap_missing: true)] }
                  changed = true
                end
              end
              # an arm that grows a container argument wants a cell: every call arm takes the cell, and the argument is wrapped once
              args.each_with_index do |a, k|
                pt = arms.map { |_, kd, pl| kd == :call ? pl.ptypes[k + 1] : nil }.find { |t| t && cell?(t) }
                next unless pt && (arr(pt[1]) && arr(of(f, a)) || hsh(pt[1]) && hsh(of(f, a)) || a.op == :cell_get)
                make_arr_cell(f, a, i); changed = true
                arms.each { |_, kd, pl| (pl.ptypes[k + 1] ||= pt[1]; arr_cell_param(pl, pl.params[k + 1])) if kd == :call && !cell?(pl.ptypes[k + 1]) }
              end
              args = i.args[2..]
              args.each_with_index do |a, k| # what the arms store into a cell comes back to the caller's cell
                next unless (at = of(f, a)) && cell?(at)
                arms.each do |_, kd, pl|
                  next unless kd == :call && (pt = pl.ptypes[k + 1]) && cell?(pt) && join(at, pt) != at
                  at = join(at, pt); a.op == :param ? f.ptypes[f.params.index(a)] = at : a.ty = at; changed = true
                end
              end
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
            when :cell_set
              c, v = i.args
              if (vt = of(f, v)) && (ct = of(f, c)) && cell?(ct) && join(ct[1], vt) != ct[1]
                nt = [:cell, join(ct[1], vt)]
                (c.op == :param ? f.ptypes[f.params.index(c)] = nt : c.ty = nt); changed = true
                if c.op == :fld_get && (k = of(f, c.args[0])) then @ivars[k][c.args[1]] = join(@ivars[k][c.args[1]], nt) end # the field holds the cell: it widens too
                @consts[c.args[0]] = join(@consts[c.args[0]], nt) if c.op == :gget
              end
            when :cell_new # the allocation inside the cell is what the GC scans: it takes the cell's inner type
              if (ct = i.ty) && cell?(ct) && ct[1].is_a?(Array) && (a = i.args[0]).op != :param && a.ty != ct[1] && (a.ty.nil? || join(a.ty, ct[1]) == ct[1])
                a.ty = ct[1]; changed = true
              end
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
              k = k[1][0] if poly?(k) # self as a set {class, descendants}: the field is recorded on the class whose method writes it (ivar_type joins the hierarchy)
              set.(@ivars[k][ix], of(f, v)) { @ivars[k][ix] = _1 } if k
              # a cell stored into a field: what the field's other writers put in it comes back to the cell (shared growth)
              if k && (vt = of(f, v)) && cell?(vt) && (it = @ivars[k][ix]) && cell?(it) && join(vt, it) != vt
                nt = join(vt, it); v.op == :param ? f.ptypes[f.params.index(v)] = nt : v.ty = nt; changed = true
              end
            when :gset then set.(@consts[i.args[0]], of(f, i.args[1])) { @consts[i.args[0]] = _1 }
            end
          end
        end
        unless changed
          if !@no_defer then @no_defer = true; changed = true; next end # a round with deferrals released (a container typed only through a deferred call)
          if !@settled && !@promoted && promote_geometric(funcs) then @promoted = true; changed = true; next end
          break if @settled # second convergence: prints resolved and types stable
          @settled = true; changed = true # one more round with the by-type rewrites enabled
          zero_checks(funcs)
        end
      end
      @settled = false; @promoted = false; @no_defer = false
      funcs.each do |f|
        f.all.each do |i|
          next unless i.op == :gget && !@consts.key?(i.args[0])
          # a $global or an object's @ivar never assigned reads as nil; a bare constant is an error
          if i.args[0].to_s =~ /[$@]/ then i.op = :const; i.args = [0]; i.ty = :nil
          else raise "uninitialized constant #{i.args[0]}" end
        end
      end
      # classes that appear in any poly type carry a tag word
      # the layout (class id word, field base) is a property of the whole hierarchy: a
      # superclass's methods write fields through `self` typed as the superclass
      tag_class = ->(c) { related(c).each { _1.tagged = true } }
      tag = ->(t) { classes_of(t)&.each { tag_class.(@classes[_1]) } if poly?(t) || arr(t) && poly?(t[1]) }
      funcs.each { |f| f.all.each { tag.(_1.ty) }; f.ptypes.each { tag.(_1) }; tag.(f.rtype) }
      @ivars.each_value { |h| h.each_value { tag.(_1) } }
      # every irreversible by-type rewrite recorded what it assumed; a type that moved afterwards is a
      # compiler bug surfacing as a refusal, not as a wrong answer
      funcs.each do |f|
        f.all.each do |i|
          next unless (a = i.assumed)
          v, kind = a; t = of(f, v)
          t = t[1] if cell?(t) # the operand became a cell holding the container (reads go through cell_get now)
          cur = i.args[0]; ct = cur.is_a?(Inst) ? of(f, cur) : nil # the receiver as it is now: an unbox may have been inserted since
          ok = case kind when :arr then arr(t) || arr(ct) when :hash then hsh(t) || hsh(ct) when :str then t == :str || ct == :str else true end
          raise "type moved after the by-type rewrite of #{i.op} in #{f.name}: assumed #{kind}, now #{t.inspect} (compiler bug: a rewrite fired on a provisional type)" unless ok
        end
      end
      funcs.each { drop_dead_phis(_1) } # a statement-valued merge nobody reads: boxing its arms would keep dead values alive
      funcs.each { convert(_1) }
      funcs.each { |f| f.all.each { |i| i.op = :hset if i.op == :hset_raw } }
      # a user object boxed into a :dyn carries its class id in word 0 and is listed in the DYN
      # descriptor: decided after convert, which is where the boxes are inserted
      funcs.each do |f|
        f.all.each do |i|
          next unless i.op == :box
          (classes_of(i.args[1]) || []).each { |cn| related(@classes[cn]).each { |k| k.tagged = true; k.boxed = true } } # a class or a poly set of classes, with its hierarchy
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
        want = { Integer: :int, Float: :float, String: :str, Array: :arr, Hash: :hash, Symbol: :sym, NilClass: :nil, TrueClass: :bool, FalseClass: :bool }[cname]
        if cname == :Numeric && !t.nil? && t != :dyn && !poly?(t) then i.op = :const; i.args = [%i[int int? float].include?(t) ? 1 : 0]; i.ty = :bool; next end
        if cname == :Comparable && !t.nil? && t != :dyn && !poly?(t) then i.op = :const; i.args = [%i[int int? float str].include?(t) || (t.is_a?(Symbol) && @classes[t] && @classes[t].mixins.include?(:Comparable)) ? 1 : 0]; i.ty = :bool; next end
        if cname == :Object && !t.nil? && t != :dyn then i.op = :const; i.args = [1]; i.ty = :bool; next end
        if t == :dyn
          i.op = :isa_dyn; i.args = [v, cname] # tag test, or class id for user classes
        elsif poly?(t) && (@classes[cname] || @lower.modules.include?(cname))
          # which members of the set descend from cname? none -> false; all -> true; some -> compare ids
          hits = t[1].select { |c| ancestor?(@classes[c], cname) }
          if hits.empty? then i.op = :const; i.args = [0]; i.ty = :bool
          elsif hits.size == t[1].size then i.op = :const; i.args = [1]; i.ty = :bool
          elsif hits.size == 1 then i.op = :isa_tag; i.args = [v, @classes[hits[0]].id] # compare the class id in word 0
          else i.op = :isa_tags; i.args = [v, hits.map { @classes[_1].id }] end
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
        when :add, :sub, :mul, :div, :mod
          i.op = :scat if i.op == :add && of(f, i.args[0]) == :str
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
          elsif of(f, r) == :int? && of(f, l) == :nil then l.args[0] = INT_NIL; l.ty = :int
          elsif %i[eq ne].include?(i.cond) && [of(f, l), of(f, r)].map(&:to_s).sort == %w[bool nil] && [l, r].any? { |v| v.op == :const && v.ty == :nil }
            # nil == false: both are the word 0, but they are different objects. A literal nil against a bool is never equal.
            i.op = :const; i.args = [i.cond == :eq ? 0 : 1]; i.ty = :bool; i.cond = nil
          end
        when :to_s # (by type, resolved in the fixpoint's settled round; anything left is an int)
          t = of(f, i.args[0])
          if t == :int? then i.op = :call; i.args = [fn(:__opt_to_s), i.args[0]]
          elsif t == :nil then i.op = :sconst; i.args = [""] # nil.to_s: "" (after the fixpoint a nil is final)
          elsif t == :bool then i.op = :bool_to_s
          elsif t == :float then i.op = :call; i.args = [fn(:__float_to_s), i.args[0]]
          elsif (cs = classes_of(t)) # an object in a string: its to_s, or #<Klass>
            if cs.any? { @classes[_1].find_method(:to_s) } then i.op = :mcall; i.args = [:to_s, i.args[0]]; bind(f, i); i.ty = :str; changed = true
            else i.op = :sconst; i.args = ["#<#{cs.first}>"] end
          elsif t == :str then i.op = :str_or_empty
          else i.op = :itos end
        when :to_i
          if of(f, i.args[0]) == :str then i.op = :stoi
          elsif of(f, i.args[0]) == :dyn then i.op = :call; i.args = [fn(:__dyn_to_i), i.args[0]]; i.ty = :int
          elsif of(f, i.args[0]) == :nil && i.args[0].op == :const then i.op = :const; i.args = [0]; i.ty = :int end # nil.to_i
        when :to_f
          if of(f, i.args[0]) == :float then i.op = :nop; i.ty = :float # already a Float
          elsif of(f, i.args[0]) == :dyn then i.op = :call; i.args = [fn(:__dyn_to_f), i.args[0]]; i.ty = :float
          elsif of(f, i.args[0]) == :str then i.op = :call; i.args = [fn(:__str_to_f), i.args[0]]; i.ty = :float end
        when :alen
          if of(f, i.args[0]) == :int then i.op = :const; i.args = [8]; i.ty = :int # Integer#size: 8 bytes (the lowering guessed an array)
          elsif of(f, i.args[0]) == :sym then nm = Inst.new(:call, [fn(:__sym_name), i.args[0]]); nm.ty = :str; nm.block = i.block; i.block.insts.insert(i.block.insts.index(i), nm); i.args = [nm] end

        when :puts_v, :p_v, :print_v
          t = of(f, i.args[0])
          i.op = case i.op
                 when :puts_v then { str: :puts_str, bool: :puts_bool, int?: :puts_opt, nil: :puts_nil }.fetch(t, :puts_i)
                 when :p_v then { str: :p_str, bool: :puts_bool, int?: :p_opt, nil: :puts_nil_word }.fetch(t, :puts_i)
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
    # an integer division by a divisor not known to be nonzero raises ZeroDivisionError:
    # a zcheck before it (cbnz + a call to the raiser; nothing on the happy path but the branch)
    def self.zero_checks(funcs)
      funcs.each do |f|
        f.blocks.each do |b|
          b.insts.dup.each do |i|
            next unless %i[div mod].include?(i.op) && of(f, i) == :int && !i.float?
            d = i.args[1]
            next if d.op == :const && d.args[0] != 0
            next if d.op == :zcheck
            z = Inst.new(:zcheck, [fn(:__raise_zero_div), d]); z.ty = :int; z.block = b
            b.insts.insert(b.insts.index(i), z)
          end
        end
      end
    end

    def self.mark_unused_results(funcs)
      read = {}; read_name = {}
      funcs.each do |f|
        f.all.each do |i|
          case i.op
          when :pcall, :sendsw then i.args[0].each { |(_, kind, payload)| read[payload] = true if kind == :call }
          when :dsend then i.args.each { read[_1] = true if _1.is_a?(Func) }
          when :to_s, :puts_v, :p_v, :print_v, :inspect_v then read_name[:to_s] = read_name[:inspect] = true # printing an object calls its to_s / inspect once the types say so
          when :alen then read_name[:length] = read_name[:size] = true # a length guessed builtin may turn out to be an object's method
          when :apop then read_name[:pop] = true
          when :add, :sub, :mul, :div, :mod, :lshift_or_append then %i[+ - * / % <<].each { read_name[_1] = true } # operators an object may define
          end
          (i.op == :phi ? i.args.map(&:last) : i.args).each do |a|
            next unless a.is_a?(Inst)
            read[a.args[0]] = true if a.op == :call
            read_name[a.args[0]] = true if a.op == :mcall # target not bound yet: every method of that name
          end
        end
      end
      funcs.each do |f|
        base = f.name.to_s.split("#").last.sub(/@v\d+\z/, "").to_sym
        unused = !read[f] && !read_name[base] && f.name != :main && !f.patchable && !f.primary && !prelude?(f) # a version is reached through its primary's slot
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
    def self.generic?(f) = f.name.to_s.start_with?("__arr_", "__merge_", "__hash_", "__fd_lines_of", "__num_") && !f.cls
    def self.clashes?(f, ts)
      # containers: one instance per exact element type (a narrower array passed where a wider one
      # was seen would need its elements re-represented, not just a wider parameter)
      f.ptypes.zip(ts).any? { |cur, t| cur && t && cur != t && ((arr(cur) || arr(t) || hsh(cur) || hsh(t)) && !(arr(cur) && arr(t) && cur[1].nil?) && !(arr(cur) && arr(t) && t[1].nil?) || join(cur, t) == :dyn || int_float?(cur, t)) }
    end
    # an Integer and a Float caller of the same prelude function get separate instances: joining
    # to Float would turn 10.clamp(1, 5) into 5.0
    def self.int_float?(a, b) = (%i[int int?].include?(a) && b == :float) || (a == :float && %i[int int?].include?(b))

    # a generic already shaped by another caller, called with a container whose elements are
    # not known yet: neither join nor instance -- wait for the elements
    # a condbr on a constant becomes a br; the arm that can no longer run is dropped from the
    # function (with the phi edges from it), so nothing in it is typed any more
    def self.fold_branches_on(f, c)
      f.blocks.each do |b|
        t = b.term
        next unless t && t.op == :condbr && t.args[0].equal?(c)
        taken, dropped = c.args[0] == 1 ? [t.args[1], t.args[2]] : [t.args[2], t.args[1]]
        t.op = :br; t.args = [taken]
        dropped.phis.each { |p| p.args.reject! { |(pred, _)| pred == b } }
      end
      # unreachable blocks go, and their phi edges with them
      seen = {}; work = [f.entry]
      until work.empty?
        b = work.shift; next if seen[b]
        seen[b] = true; work.concat(b.succs)
      end
      f.blocks.select! { seen[_1] }
      f.blocks.each { |b| b.phis.each { |p| p.args.select! { |(pred, _)| seen[pred] } } }
    end

    # a caller left this prelude function: its parameter types came partly from that caller and
    # re-derive from the ones that remain (every live call re-joins its arguments each round).
    # Only functions no user code can see directly (prelude), and not their class methods.
    def self.forget_params(callee, funcs, seen = {})
      return if callee.cls || !callee.name.to_s.start_with?("__") || seen[callee]
      seen[callee] = true
      callee.ptypes = Array.new(callee.params.size)
      callee.rtype = nil
      funcs.each { |g| g.all.each { |u| u.ty = nil if u.op == :call && u.args[0].equal?(callee) } }
      callee.all.each { |u| forget_params(u.args[0], funcs, seen) if u.op == :call && u.args[0].is_a?(Func) } # what it calls was typed from its parameters
    end

    def self.literal_origin?(v, seen = {})
      loop do
        return false if seen[v]; seen[v] = true
        if %i[aset hset].include?(v.op) && v.args[0].is_a?(Inst) then v = v.args[0]
        elsif v.op == :phi then return v.args.any? { |(_, a)| a.is_a?(Inst) && literal_origin?(a, seen) } # a loop-carried handle: its entry value
        elsif v.op == :cell_get then v = v.args[0]
        elsif v.op == :cell_new then v = v.args[0]
        else return %i[anew hnew].include?(v.op) end
      end
    end

    # a container type with an element still unknown
    def self.partial?(t) = t.is_a?(Array) && (t[0] == :arr && (t[1].nil? || partial?(t[1])) || t[0] == :hash && (t[1].nil? || t[2].nil?) || t[0] == :cell && partial?(t[1]))

    def self.deferred_generic?(f, ts)
      return false if @no_defer # nothing else can move: let the call shape itself from what is known
      f.ptypes.zip(ts).any? { |cur, t| cur && t && cur != t && (arr(t) && t[1].nil? && arr(cur) || hsh(t) && t[1].nil? && hsh(cur)) }
    end

    def self.instance_for(f, ts, funcs)
      base = f.name.to_s.sub(/\$\d+$/, "")
      @instances ||= {}
      # a call that keeps asking for a new instance of the same generic is a type that never settles
      # (a hash where the helper wants an array): refuse rather than loop
      @instancings ||= Hash.new(0)
      raise "#{base}: instancing does not converge for argument types #{ts.inspect}" if (@instancings[[base, f.object_id]] += 1) > 200
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
      when :cell_set then (t = of(f, i.args[0])) && cell?(t) && (yield i.args[1], t[1])
      when :gset then yield i.args[1], @consts[i.args[0]]
      when :call # a generic prelude function takes an instance per container type: no widening of the argument towards another caller's shape
        gen = generic?(i.args[0])
        i.args[1..].each_with_index { |v, k| d = i.args[0].ptypes[k]; yield v, (gen && d.is_a?(Array) && (t = of(f, v)).is_a?(Array) && t != d ? nil : d) }
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
      case v.op
      when :param then f.ptypes[f.params.index(v)] = nt
      when :call then v.args[0].rtype = nt # the callee's returned container: its stores box, through its own ret flow
      when :hval_at, :hkey_at
        return false # a value read out of a hash's own storage: relabelling it would promise tagged
                     # elements the hash does not hold. The flow inserts a converting copy instead.
      else v.ty = nt
      end
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
        case a.op # the container's home learns the element type too, else another load of it keeps the old one
        when :param then f.ptypes[f.params.index(a)] = nt
        when :fld_get
          k = of(f, a.args[0]); k = k[1][0] if poly?(k)
          @ivars[k][a.args[1]] = nt if k && @ivars[k]
          a.ty = nt
        when :gget then @consts[a.args[0]] = nt; a.ty = nt
        else a.ty = nt end
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

    # ---- arrays grown through parameters: a cell holding the handle (the array analogue of :strbuf)

    # the parameter p of f (an array) becomes [:cell, arr]: every use loads through the cell,
    # every aset that may grow writes the new handle back
    # the parameter an array handle descends from through aset chains and loop phis, if any
    def self.param_origin(f, v, seen = {})
      return nil if seen[v]; seen[v] = true
      case v.op
      when :param then v
      when :aset, :hset then param_origin(f, v.args[0], seen)
      when :phi then v.args.map { |(_, a)| param_origin(f, a, seen) }.compact.first
      end
    end

    def self.arr_cell_param(f, p)
      k = f.params.index(p)
      at = f.ptypes[k]
      f.ptypes[k] = [:cell, at]
      cellify_uses(f, p)
    end

    # wrap the array v in a cell at its origin (the allocation, a load, a parameter), so the
    # callee's growth is visible here: later uses load through the cell, later stores write back
    def self.make_arr_cell(f, v, use)
      if v.op == :cell_get # already a cell: hand the cell itself to this use
        swap_operand(use, v, v.args[0]); return v.args[0]
      end
      o = v
      loop do # the handle chain back to the allocation: through stores, and through loop phis to their entry value
        if %i[aset hset].include?(o.op) && o.args[0].ty.is_a?(Array) then o = o.args[0]
        elsif o.op == :phi && (entry = o.args.find { |(bb, a)| f.blocks.index(bb) < f.blocks.index(o.block) }) then o = entry[1]
        else break end
      end
      if o.op == :param then arr_cell_param(f, o); return o end
      if o.op == :cell_get then swap_operand(use, v, o.args[0]); return o.args[0] end # the chain already lives in a cell: pass that cell
      c = Inst.new(:cell_new, [o]); c.ty = [:cell, of(f, o)]; c.block = o.block
      at = o.op == :phi ? 0 : o.block.insts.index(o) + 1
      o.block.insts.insert(at, c)
      f.replace_uses(o, c); c.args = [o]
      cellify_uses(f, c)
      c
    end

    # c holds a cell with an array; its uses (other than cell consumers) get a load, and an
    # aset on the loaded handle writes the (possibly new) handle back into the cell. Phis and
    # calls into cell parameters pass the cell itself.
    def self.cellify_uses(f, c)
      f.all.dup.each do |u|
        next unless u.args.any? { |a| a == c || (a.is_a?(Array) && a[1] == c) }
        case u.op
        when :cell_get, :cell_set, :cell_new then next
        when :phi # a loop-carried handle becomes the cell on every edge (growth lives in the cell now): the phi is trivial
          u.args = u.args.map { |(bb, _)| [bb, c] }; u.ty = of(f, c)
          f.replace_uses(u, c); next
        when :call then next if (pt = u.args[0].ptypes[u.args.index(c) - 1]) && cell?(pt)
        when :pcall then next if u.args[0].any? { |_, kd, pl| kd == :call && (pt = pl.ptypes[u.args.index(c) - 1]) && cell?(pt) }
        end
        # every use loads afresh right before it: a call or a store in between may have replaced the handle
        g = Inst.new(:cell_get, [c]); g.ty = of(f, c)[1]; g.block = u.block
        u.block.insts.insert(u.block.insts.index(u), g)
        swap_operand(u, c, g)
        if u.op == :lshift_or_append && u.args[0] == g
          len = Inst.new(:alen, [g]); len.ty = :int; len.block = u.block
          u.block.insts.insert(u.block.insts.index(u), len)
          u.op = :aset; u.args = [g, len, u.args[1]]
        end
        if (u.op == :aset || u.op == :hset) && u.args[0] == g # a store may grow: the new handle goes back into the cell, and later code reads the cell
          st = Inst.new(:cell_set, [c, u]); st.ty = :int; st.block = u.block
          u.block.insts.insert(u.block.insts.index(u) + 1, st)
          f.replace_uses(u, c); st.args = [c, u]
          cellify_uses(f, c) # the uses just redirected to c need their own loads
          return
        end
      end
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
        next if prelude?(f) # the preludes are written to fit
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
              next unless [x, y].all? { |o| of(f, o) == :int || o.equal?(p) } # a tagged or unknown operand: no big arithmetic to promote into
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
    DYN_OPS = { add: :__dyn_add, sub: :__dyn_sub, mul: :__dyn_mul, div: :__dyn_div, mod: :__dyn_mod,
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
      when :int then i.op = :itos
      when :int? then i.op = :call; i.args = [fn(:__opt_inspect), i.args[0]]
      when :bool then i.op = :bool_to_s
      when :nil
        # :nil as a joined type can still widen (an arm whose type has not arrived yet joins as
        # nil); only a literal nil is certainly nil
        return unless i.args[0].op == :const || i.args[0].op == :phi && i.args[0].args.all? { |(_, v)| v.op == :const && v.ty == :nil }
        i.op = :sconst; i.args = ["nil"]
      when :sym then i.op = :call; i.args = [fn(:__sym_inspect), i.args[0]]
      else
        if arr(t) then i.op = :call; i.args = [fn(:__arr_inspect), i.args[0]]
        elsif hsh(t) then i.op = :call; i.args = [fn(t[1] == :sym ? :__hash_inspect_sym : t[1] == :dyn ? :__hash_inspect_dyn : :__hash_inspect), i.args[0]]
        else raise "inspect of #{t.inspect} not supported" end
      end
    end

    # :mcall name, recv, args -> :call Func / :fld_get / :fld_set
    def self.bind(f, i)
      name, recv, *args = i.args
      t = of(f, recv)
      if name == :class && args.empty? && t == :dyn then i.op = :call; i.args = [fn(:__dyn_class_name), recv]; i.ty = :str; return end
      # an operator guessed to be an object's method (the pre-typing misjudged the receiver): the builtin operation
      if args.size == 1 && (ar = { :+ => :add, :- => :sub, :* => :mul, :/ => :div, :% => :mod }[name]) && %i[int int? float].include?(t)
        i.op = ar; i.args = [recv, args[0]]; i.ty = nil; return
      end
      if name == :+ && args.size == 1 && t == :str then i.op = :scat; i.args = [recv, args[0]]; i.ty = :str; return end
      if name == :class && args.empty? && (cn = { int: "Integer", float: "Float", str: "String", sym: "Symbol", bool: "TrueClass", nil: "NilClass" }[t] || (arr(t) && "Array") || (hsh(t) && "Hash"))
        return if t == :bool || t == :nil && recv.op != :const # true/false share a type; a joined nil may still widen
        i.op = :sconst; i.args = [cn]; i.ty = :str; return
      end
      if t == :dyn && args.empty? && %i[to_s inspect].include?(name) then i.op = :call; i.args = [fn(name == :to_s ? :__dyn_to_s : :__dyn_inspect), recv]; i.ty = :str; return end
      if t == :dyn && args.empty? && name == :to_sym then i.op = :call; i.args = [fn(:__dyn_sym), recv]; i.ty = :sym; return end
      if t == :dyn && args.empty? && name == :to_i then i.op = :call; i.args = [fn(:__dyn_to_i), recv]; i.ty = :int; return end
      if t == :dyn && args.empty? && name == :to_f then i.op = :call; i.args = [fn(:__dyn_to_f), recv]; i.ty = :float; return end
      if name == :class && args.empty? && classes_of(t) && classes_of(t).none? { @classes[_1].find_method(:class) } # the class's name, as a String (no class objects at run time)
        return unless @settled # the set may still widen (an exception value joins every raise in the program)
        if classes_of(t).size == 1 then i.op = :sconst; i.args = [classes_of(t)[0].to_s]; i.ty = :str; return end # one class: no header to read
        cid = Inst.new(:class_id, [recv]); cid.ty = :int; cid.block = i.block; i.block.insts.insert(i.block.insts.index(i), cid)
        i.op = :call; i.args = [fn(:__class_name), cid]; i.ty = :str; return
      end
      if poly?(t) # one arm per class: [klass, kind, payload]; a class without the method traps if reached
        arms = t[1].map { |c| [@classes[c], *resolve(@classes[c], name, args.size, trap_missing: true)] }
        raise "no method #{name} on any of #{t[1].join(', ')}" if arms.all? { |(_, kind, _)| kind == :trap }
        if arms.all? { |(_, kind, payload)| kind == :call && payload.equal?(arms[0][2]) } # one function for the whole set: no dispatch needed
          i.op = :call; i.args = [arms[0][2], recv, *args]; return
        end
        if arms.all? { |(_, kind, payload)| kind == :fld_get && payload == arms[0][2] } then i.op = :fld_get; i.args = [recv, arms[0][2]]; return end # one layout for the field
        i.op = :pcall; i.args = [arms, recv, *args]
        return
      end
      if name == :value && args.empty? && !(t.is_a?(Symbol) && @classes[t]) && !poly?(t) && t
        i.op = :nop; i.args = [recv]; i.ty = t; return # a finished Thread is its value (threads run at Thread.new)
      end
      if t == :int && (fn = fnq(:"__fd_#{name}")) # a file descriptor is an Integer: fd.puts, fd.write, fd.close
        i.op = :call; i.args = [fn, recv, *args]; return
      end
      if name == :<=> && (t == :int || t == :str || t == :float)
        i.op = :call; i.args = [fn(t == :str ? :__str_spaceship : :__num_spaceship), recv, *args]; return
      end
      t = :int if t == :int? # a nullable int used as a receiver: nil would have raised
      if name == :frozen? && args.empty? && t # no frozen bit: scalars are frozen, everything else reports false (freeze is accepted and does nothing)
        i.op = :const; i.args = [%i[int int? float sym nil bool].include?(t) ? 1 : 0]; i.ty = :bool; return
      end
      if %i[freeze dup clone itself].include?(name) && args.empty? && t && !(classes_of(t) && classes_of(t).any? { @classes[_1].find_method(name) })
        # freeze: accepted, no effect (no frozen bit); dup/clone of a scalar or object: the same value (copying an object is not supported); itself
        raise "dup/clone of an object: not supported (every object is shared)" if %i[dup clone].include?(name) && classes_of(t)
        if %i[dup clone].include?(name) && t == :dyn then i.op = :call; i.args = [fn(:__dyn_dup), recv]; i.ty = :dyn; return end
        if %i[dup clone].include?(name) && (arr(t) || hsh(t) || t == :str) # the prelude copies
          fm = t == :str ? "str" : arr(t) ? "arr" : "hash"
          i.op = :call; i.args = [prelude_method(fm, :dup, 0) || fn(:"__#{fm}_dup"), recv]; i.routed = name; return
        end
        i.op = :nop; i.args = [recv]; i.ty = t; return
      end
      # builtin methods that are ops when the receiver's kind was known at lowering; here by type
      if args.empty?
        case [t, name]
        in [:str | [:arr, *], :length | :size | :bytesize] then i.op = :alen; i.args = [recv]; return
        in [:int, :to_i] then i.op = :nop; i.args = [recv]; i.ty = :int; return
        in [:sym, :to_s] then i.op = :call; i.args = [fn(:__sym_name), recv]; i.ty = :str; return
        in [:str, :to_sym] then i.op = :call; i.args = [fn(:__str_to_sym), recv]; i.ty = :sym; return
        in [:sym, :to_sym] then i.op = :nop; i.args = [recv]; i.ty = :sym; return
        in [:sym, :inspect] then i.op = :call; i.args = [fn(:__sym_inspect), recv]; i.ty = :str; return
        in [:sym, :length | :size | :upcase | :downcase | :capitalize | :succ | :next | :empty?] # Symbol methods through the name
          nm = Inst.new(:call, [fn(:__sym_name), recv]); nm.ty = :str; nm.block = i.block; i.block.insts.insert(i.block.insts.index(i), nm)
          if %i[length size].include?(name) then i.op = :alen; i.args = [nm]; i.ty = :int; return end
          if name == :empty? then i.op = :call; i.args = [fn(:__str_empty_p), nm]; i.ty = :bool; return end
          r = Inst.new(:call, [fn(:"__str_#{name == :next ? :succ : name}"), nm]); r.ty = :str; r.block = i.block; i.block.insts.insert(i.block.insts.index(i), r)
          i.op = :call; i.args = [fn(:__str_to_sym), r]; i.ty = :sym; return
        in [:nil, :to_a] then i.op = :anew; i.args = [(z = Inst.new(:const, [0]); z.ty = :int; z.block = i.block; i.block.insts.insert(i.block.insts.index(i), z); z), z]; i.ty = [:arr, :dyn]; return
        in [:nil, :to_i] then i.op = :const; i.args = [0]; i.ty = :int; return
        in [:nil, :to_f] then i.op = :fconst; i.args = [0.0]; i.ty = :float; return
        in [:nil, :to_s | :inspect] if recv.op == :const then i.op = :sconst; i.args = [name == :to_s ? "" : "nil"]; i.ty = :str; return # a literal nil only: a parameter's nil may still widen
        in [:int, :to_f] then i.op = :itof; i.args = [recv]; i.ty = :float; return
        in [:float, :to_i] then i.op = :to_i; i.args = [recv]; i.ty = :int; return
        in [:float, :to_f] then i.op = :nop; i.args = [recv]; i.ty = :float; return
        in [:str, :to_i] then i.op = :stoi; i.args = [recv]; i.ty = :int; return
        in [:str, :to_s] then i.op = :str_or_empty; i.args = [recv]; i.ty = :str; return # a nil in a String slot is the 0 word: its to_s is ""
        in [:float, :to_s] then i.op = :call; i.args = [fn(:__float_to_s), recv]; i.ty = :str; return
        in [:int, :chr] then i.op = :chr; i.args = [recv]; i.ty = :str; return
        in [[:arr, *], :pop] then i.op = :apop; i.args = [recv]; return
        else nil
        end
      end
      if t == :int && name == :to_s && args.empty? then i.op = :itos; i.args = [recv]; return end
      if t == :dyn && (cands = @classes.values.select { |k| k.closure ? name == :call : (k.find_method(name) || k.find_reader(name) || k.find_writer(name)) }).any? && !%i[str arr hash num].any? { |fm| prelude_method(fm, name, args.size) }
        # a method of user classes on a tagged value: the object (tag 8, class id in word 0), dispatched over the classes defining it
        cs = cands.map(&:name).sort
        un = Inst.new(:unbox, [recv, cs.size == 1 ? cs[0] : [:poly, cs]]); un.ty = cs.size == 1 ? cs[0] : [:poly, cs]; un.block = i.block
        i.block.insts.insert(i.block.insts.index(i), un)
        cands.each { |k| related(k).each { _1.tagged = true; _1.boxed = true } }
        i.args[1] = un; return bind(f, i)
      end
      if t == :dyn && name == :slice_range && args.size == 3 then i.op = :call; i.args = [fn(:__dyn_slice_range), recv, *args]; return end
      if t == :dyn && args.size == 1 && %i[include? join first last].include?(name) && (dh = fnq(:"__dyn_#{name.to_s.sub('?', '_p')}#{%i[first last].include?(name) ? 1 : ''}"))
        i.op = :call; i.args = [dh, recv, args[0]]; return # the tag picks the family at run time
      end
      if t == :dyn && %i[sum min max sort uniq join length size first last reverse flatten compact each map select reject include? empty? count keys values].include?(name)
        # a container method on a tagged value: the container families both define it, so the
        # tag decides at run time (array or hash) and the typed method runs on what comes out
        fams = %w[arr hash].select { |fm| prelude_method(fm, name, args.size) }
        if fams.size >= 1 && args.empty?
          c = Inst.new(:call, [fn(:__dyn_arr), recv]); c.ty = [:arr, :dyn]; c.block = i.block
          i.block.insts.insert(i.block.insts.index(i), c)
          i.op = :call; i.args = [prelude_method("arr", name, 0) || fn(:"__arr_#{name}"), c]; return
        end
      end
      if t == :dyn # a method on a tagged value: if exactly one builtin family defines it, unbox (trapping on a wrong tag) and call
        fams = %w[str arr hash num].select { |fm| prelude_method(fm, name, args.size) }
        fams = ["str"] if fams.empty? && %i[length size upcase downcase].include?(name)
        if fams.size == 1
          fm = fams[0]
          un = Inst.new(:call, [fn(:"__dyn_#{fm == 'num' ? 'int' : fm}"), recv]); un.ty = { "str" => :str, "arr" => [:arr, :dyn], "hash" => [:hash, :dyn, :dyn], "num" => :int }[fm]; un.block = i.block
          i.block.insts.insert(i.block.insts.index(i), un)
          pm = prelude_method(fm, name, args.size); i.op = :call; i.args = [pm, un, *args, *default_args(pm, i, args.size)]; return
        end
      end
      # prelude methods by family and name (__hash_x, __num_x, __str_x, __arr_x); an arity-suffixed
      # sibling (__arr_last1) serves a call with that many arguments, since defaults cannot be typed here
      if arr(t) && t[1] == :sym && args.empty? && %i[sort min max].include?(name) # symbols order by name
        i.op = :call; i.args = [fn(:"__arr_#{name}_sym"), recv]; return
      end
      if t == :sym && args.size == 1 && %i[<=> start_with? end_with? [] ==].include?(name) && name != :==
        nm = Inst.new(:call, [fn(:__sym_name), recv]); nm.ty = :str; nm.block = i.block; i.block.insts.insert(i.block.insts.index(i), nm)
        a0 = args[0]
        if of(f, a0) == :sym then a0 = Inst.new(:call, [fn(:__sym_name), a0]); a0.ty = :str; a0.block = i.block; i.block.insts.insert(i.block.insts.index(i), a0) end
        i.op = :mcall; i.args = [name, nm, a0]; i.ty = nil; return bind(f, i)
      end
      if t == :float && args.empty? && %i[round floor ceil truncate to_i].include?(name)
        i.op = :call; i.args = [fn(name == :round ? :__float_round0 : name == :floor ? :__num_floor : name == :ceil ? :__num_ceil : :__num_truncate), recv]; i.ty = :int; return
      end
      if t == :float && args.size == 1 && name == :fdiv then i.op = :div; i.args = [recv, args[0]]; i.ty = :float; return end
      if t == :float && args.size == 1 && name == :divmod then i.op = :call; i.args = [fn(:__float_divmod), recv, args[0]]; return end
      if t == :int && args.size == 1 && name == :divmod && of(f, args[0]) == :float then i.op = :call; i.args = [fn(:__float_divmod), recv, args[0]]; return end
      fam = hsh(t) ? "hash" : (t == :int || t == :float) ? "num" : t == :str ? "str" : arr(t) ? "arr" : nil
      if fam && (fn = prelude_method(fam, name, args.size))
        if fam == "str" && args.any? { |a| a.op == :const && a.ty == :nil } # "s".index(nil): TypeError, not a null read
          w = Inst.new(:sconst, ["String"]); w.ty = :str; w.block = i.block; i.block.insts.insert(i.block.insts.index(i), w)
          i.op = :call; i.args = [fn(:__raise_no_conversion), w]; i.ty = :int?; return
        end
        i.op = :call; i.args = [fn, recv, *args, *default_args(fn, i, args.size)]; i.routed = name; return # routed by the receiver's family: rebindable if the receiver changes kind
      end
      if t == :int && %i[succ pred].include?(name) && args.empty? # Integer#succ / #pred
        c = Inst.new(:const, [1]); c.ty = :int; c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c)
        i.op = name == :succ ? :add : :sub; i.args = [recv, c]; return
      end
      # prelude methods take no optional parameters: an arity-suffixed name (__str_rjust1) serves the shorter call
      if arr(t) && name == :to_a && args.empty? then i.op = :nop; i.args = [recv]; i.ty = t; return end
      return unless t.is_a?(Symbol) && (klass = @classes[t])
      # a class without the method while the receiver's set may still widen (an element of a mixed array
      # seen one class at a time): wait; settled, it is Ruby's NoMethodError at run time (a trap)
      unless klass.find_reader(name) && args.empty? || klass.find_writer(name) && args.size == 1 || klass.find_method(name) || klass.find_method(:method_missing)
        return unless @settled
        tr = Inst.new(:trap, []); tr.ty = :int; tr.block = i.block; i.block.insts.insert(i.block.insts.index(i), tr) # NoMethodError at run time
        i.op = :const; i.args = [0]; i.ty = :nil; return # the value after a trap: never read
      end
      kind, payload = resolve(klass, name, args.size, allow_missing: true)
      case kind
      when :fld_get then i.op = :fld_get; i.args = [recv, payload]
      when :fld_set then i.op = :fld_set; i.args = [recv, payload, args[0]]
      when :call then i.op = :call; i.args = [payload, recv, *args]
      when :missing # method_missing(name, *args): the name is a compile-time symbol, args packed
        i.op = :call; i.args = [payload, recv, sym_const(i, name), pack_args(i, args)]
      end
    end

    # the arity-suffixed helper first; the plain name only if it takes receiver + argc parameters
    # (falling back regardless of arity silently dropped arguments: [1, 2, 2].count(2) was 3)
    def self.prelude_method(fam, name, argc)
      base = name.to_s.sub("?", "_p").sub("!", "_bang")
      f = fnq(:"__#{fam}_#{base}#{argc}")
      return f if f
      f = fnq(:"__#{fam}_#{base}") or return nil
      return f if f.rest || f.params.size == argc + 1
      # fewer arguments than parameters: fine when the missing ones are optionals with literal defaults
      @lower.required_count(f) <= argc + 1 && argc + 1 <= f.params.size && @lower.optional_defaults(f).none? { _1 == :unsupported } ? f : nil
    end

    # the constants that complete a routed call to a prelude function with optional parameters
    def self.default_args(f, at, argc)
      missing = f.params.size - (argc + 1)
      return [] if missing <= 0
      @lower.optional_defaults(f).last(missing).map do |v|
        c = Inst.new(:const, [v || 0]); c.ty = v.nil? ? :nil : :int; c.block = at.block
        at.block.insts.insert(at.block.insts.index(at), c); c
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
      if of(f, name_v) == :str # a String name: its symbol
        c = Inst.new(:call, [fn(:__str_to_sym), name_v]); c.ty = :sym; c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c)
        i.args[0] = name_v = c
      end
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
      # a container whose elements are still unknown may yet turn out to be something else entirely
      # (a tagged value, a string): wait, unless it is our own fresh literal
      return if partial?(t) && !@settled && !(r.is_a?(Inst) && (literal_origin?(r)))
      if arr(t) && i.op == :idx && i.args.size == 3 then i.op = :call; i.args = [fn(:__arr_slice), *i.args]; i.ty = nil # a[start, len]
      elsif arr(t) then i.op = i.op == :idx ? :aget : :aset; i.assumed = [r, :arr]
      elsif hsh(t) then i.op = i.op == :idx ? :hget : :hset; i.assumed = [r, :hash]
      elsif t == :str && !@settled && r.is_a?(Inst) && %i[aget hget apop idx phi cell_get].include?(r.op) then nil # an element read as a string may still turn out tagged: wait
      elsif t == :str && i.op == :idx_set then i.op = :call; i.args = [fn(:__str_set_at), *i.args]; i.ty = :str # s[i] = "c"
      elsif t == :str && i.op == :idx then i.assumed = [r, :str]; i.op = :ssub; i.args << (c = Inst.new(:const, [1]); c.ty = :int; c.block = i.block; i.block.insts.insert(i.block.insts.index(i), c); c) if i.args.size == 2
      elsif classes_of(t) # an object: its own [] / []= method
        i.args = [i.op == :idx ? :[] : :[]=, *i.args]; i.op = :mcall; i.ty = nil; bind(f, i)
      elsif t == :nil && @settled # indexing nil: dead code behind a nil? guard, or a NoMethodError at run time: trap, and the value is a constant
        tr = Inst.new(:trap, []); tr.ty = :int; tr.block = i.block; i.block.insts.insert(i.block.insts.index(i), tr)
        i.op = :const; i.args = [0]; i.ty = :nil
      elsif t == :nil then nil
      elsif t == :int && i.args.size == 2 && !@settled.nil? && of(f, i.args[1]) == :int # n[k]: bit k
        one = Inst.new(:const, [1]); one.ty = :int; one.block = i.block; i.block.insts.insert(i.block.insts.index(i), one)
        sh = Inst.new(:shr, [r, i.args[1]]); sh.ty = :int; sh.block = i.block; i.block.insts.insert(i.block.insts.index(i), sh)
        i.op = :and; i.args = [sh, one]; i.ty = :int
      elsif t == :sym # :abc[0]: index the name
        nm = Inst.new(:call, [fn(:__sym_name), r]); nm.ty = :str; nm.block = i.block; i.block.insts.insert(i.block.insts.index(i), nm)
        i.args[0] = nm; i.ty = nil
      elsif @settled then raise "[] on #{t.inspect}" end # a scalar before settling may be a provisional join: wait
    end

    # a class with its ancestors and descendants: one layout
    # the type of self inside klass's methods: the class alone, or with every descendant (an inherited
    # method runs on subclass instances too; a call on self then dispatches on the real class)
    def self.self_type(klass)
      return klass.name if klass.closure
      descendants = @classes.values.select { |c| c != klass && !c.closure && ancestor?(c, klass.name) && !c.mixins&.include?(klass.name) }
      descendants.empty? ? klass.name : [:poly, [klass.name, *descendants.map(&:name)]]
    end

    def self.related(klass)
      ups = []; c = klass.superclass; (ups << c; c = c.superclass) while c
      [klass, *ups, *@classes.values.select { |c| ancestor?(c, klass.name) && c != klass }]
    end

    def self.ancestor?(klass, cname) # a superclass, or a module mixed into one
      k = klass
      while k
        return true if k.name == cname || k.mixins&.include?(cname)
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
      when :fld_get then ivar_type(klass.name, payload) # the field may be set by a superclass's initialize
      when :fld_set then of(f, i.args[2])
      when :call then payload.rtype
      end
    end

    def self.infer(f, i)
      a = i.args
      case i.op
      when :const then %i[nil sym bool lambda str].include?(i.ty) ? i.ty : :int # :str: the nil word in a String slot (__nil_str_value)
      when :fconst then :float
      when :sconst, :scat, :sappend, :itos, :bool_to_s, :chr, :sdup, :salloc then :str
      when :rawld8 then :int
      when :mkbuf, :bufappend then :strbuf
      when :bufderef then :str
      when :apop then (t = of(f, a[0])) && arr(t) ? t[1] : nil
      when :nop then i.ty || of(f, a[0]) # the same value under another name
      when :is_sym, :is_dyn, :is_arr then :bool
      when :hcap, :gcepoch, :hsave, :sys then :int
      when :cell_new then (t = of(f, a[0])) && [:cell, t]
      when :cell_get then (t = of(f, a[0])) && t.is_a?(Array) && t[0] == :cell ? t[1] : nil
      when :cell_set then :int
      when :try_push, :try_pop, :raise, :class_id, :zcheck then :int
      when :exc_value then @exc_type || (fn(:__raise_zero_div); :StandardError) # nothing in the program raises yet: the runtime still can (ZeroDivisionError; demanding its raiser types the message)
      when :hkey_at then (t = of(f, a[0])) && hsh(t) ? t[1] : nil
      when :hval_at then (t = of(f, a[0])) && hsh(t) ? t[2] : nil
      when :seq, :sne, :scmp then :bool
      when :puts_i, :puts_str, :puts_bool, :puts_opt, :p_opt, :puts_nil, :print_i, :print_str, :p_str then :int
      when :p_v, :print_v then of(f, a[0]) && :int
      when :inspect_v then of(f, a[0]) && :str
      when :idx, :idx_set, :dsend, :mcall then nil
      when :lshift_or_append then (t = of(f, a[0])) && (t == :int ? :int : t)
      when :to_s then (t = of(f, a[0])) && (t == :str ? :str : narrow(t) == :int ? :str : %i[nil bool float int?].include?(t) ? :str : nil)
      when :puts_v then of(f, a[0]) && :int
      when :add, :sub, :mul, :div
        l, r = of(f, a[0]), of(f, a[1])
        l && r ? join(narrow(l), narrow(r)) : nil # both sides known, or no guess: a str * n is not an int
      when :and, :or then [of(f, a[0]), of(f, a[1])].all? { %i[bool nil].include?(_1) } ? :bool : :int # nil is the word 0, false: nil & x, nil | x are booleans
      when :xor then [of(f, a[0]), of(f, a[1])].all? { %i[bool nil].include?(_1) } ? :bool : :int
      when :mod then i.args.any? { of(f, _1) == :float } ? :float : :int
      when :shl, :shr, :to_i, :alen, :ipow, :rawld, :rawld32, :gbase, :adrlbl, :rawst, :rawmmap, :rawmunmap, :trap, :fbits, :lsr, :clz, :umulh, :wmul, :wadd, :wsub, :handle then :int
      when :cmp, :ucmp, :isa, :isa_dyn then :bool
      when :box then :dyn
      when :unbox then a[1]
      when :dyn_tag then :int
      when :pcall then a[0].map { arm_type(f, i, _1) }.reduce(nil) { join(_1, _2) }
      when :sendsw then a[0].map { |(_, kind, payload)| sw_arm_type(f, i, kind, payload) }.reduce(nil) { join(_1, _2) }
      when :dsend then nil
      when :gc_now, :raise_any, :setslot, :retag then :int
      when :respond_to_q then :bool
      when :str_or_empty then :str
      when :to_f, :fsqrt, :libm, :clock then :float
      when :eputs_v, :eputs_str then :int
      when :pow then (l = of(f, a[0])) && (r = of(f, a[1])) ? (join(narrow(l), narrow(r)) == :float ? :float : :int) : nil # both sides known first
      when :seq_char then :bool
      when :anew then (t = of(f, a[1])) && t != :nil ? [:arr, t] : [:arr, nil] # partial until a store
      when :hnew then [:hash, nil, nil]
      when :hget then (t = of(f, a[0])) && hsh(t) ? nullable(t[2]) : nil
      when :hset, :hset_raw then of(f, a[0])
      when :hkey then :bool
      when :hkeys then (t = of(f, a[0])) && hsh(t) ? [:arr, t[1]] : nil
      when :ssub then :str
      when :aget then (t = of(f, a[0])) && arr(t) ? nullable(t[1]) : nil
      when :aset then of(f, a[0])
      when :phi
        # an Integer meeting a Float at a branch merge keeps its identity (cond ? 1 : 2.0 prints 1, not 1.0);
        # at a loop header it becomes a Float (x = 0; loop { x += 0.5 }): the arithmetic is the same and
        # the loop stays untagged
        header = i.block.name.to_s.start_with?("head", "retry")
        a.map { of(f, _2) }.reduce(nil) { header ? join(_1, _2) : join_elem(_1, _2) }
      when :call
        # a generic prelude function may still be swapped for an instance once the argument
        # types are known: commit to no result type before then
        generic?(a[0]) && (a[1..].any? { |v| of(f, v).nil? } || deferred_generic?(a[0], a[1..].map { of(f, _1) })) ? nil : a[0].rtype
      when :todyn then :dyn
      when :itof, :ffrom then :float
      when :onew then (subs = @classes.values.select { |c| c.superclass.equal?(a[0]) && c.name.to_s.include?("$") }).empty? ? a[0].name : [:poly, [a[0].name, *subs.map(&:name)].sort] # an object that may be retagged to a hidden subclass (def x.m): the set
      when :fld_get then (k = of(f, a[0])) && ivar_type(k, a[1])
      when :fld_set then of(f, a[2])
      when :gget then @consts[a[0]]
      when :gset then of(f, a[1])
      end
    end

    # an ivar's type: joined over the class and its subclasses (same offset)
    def self.ivar_type(k, ix)
      # a poly receiver (an inherited field read on a set of related classes): the field has
      # the same index in every member, so join their types
      return k[1].map { ivar_type(_1, ix) }.reduce(nil) { join(_1, _2) } if poly?(k)
      klass = @classes[k] or raise "ivar_type: receiver typed #{k.inspect}"
      # the slot's type is whatever any class sharing the slot stores there: this class, the
      # ancestors whose initialize may set it, and the descendants that inherit it
      ups = []; c = klass.superclass; (ups << c; c = c.superclass) while c
      downs = @classes.values.select { |c| ancestor?(c, klass.name) && c != klass }
      [klass, *ups, *downs].map { @ivars[_1.name][ix] }.reduce(nil) { join(_1, _2) }
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
          when :add, :sub, :mul, :div, :cmp, :mod
            if i.args.any? { of(f, _1) == :float }
              i.args.map! { |v| %i[int int?].include?(of(f, v)) ? coerce(f, b, i, v, :float) : v }
              i.cond = :"f#{i.cond}" if i.op == :cmp
            end
          when :fsqrt then i.args[0] = coerce(f, b, i, i.args[0], :float)
          when :libm then i.args[1..].each_with_index { |v, k| i.args[k + 1] = coerce(f, b, i, v, :float) }
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
      when :hset, :hset_raw
        t = of(f, i.args[0])
        if hsh(t) then yield i.args[1], t[1], ->(w) { i.args[1] = w }; yield i.args[2], t[2], ->(w) { i.args[2] = w } end
      when :hget, :hkey # a lookup key takes the hash's key representation too
        t = of(f, i.args[0]); yield i.args[1], t[1], ->(w) { i.args[1] = w } if hsh(t)
      when :fld_set then yield i.args[2], ivar_type(of(f, i.args[0]), i.args[1]), ->(w) { i.args[2] = w }
      when :cell_set then (t = of(f, i.args[0])) && cell?(t) && (yield i.args[1], t[1], ->(w) { i.args[1] = w })
      when :gset then yield i.args[1], @consts[i.args[0]], ->(w) { i.args[1] = w }
      when :call then i.args[1..].each_with_index { |v, k| yield v, i.args[0].ptypes[k], ->(w) { i.args[k + 1] = w } }
      when :ret then yield i.args[0], f.rtype, ->(w) { i.args[0] = w }
      end
    end

    # `1.5 + "s"`: a TypeError at run time, with Ruby's wording (a provisional nil join is left alone: only a literal nil)
    def self.coerce_error(f, i)
      l, r = i.args
      lt, rt = of(f, l), of(f, r)
      return false unless %i[int int? float].include?(lt) && rt && (!%i[int int? float dyn nil].include?(rt) || rt == :nil && r.op == :const)
      what = rt == :str ? "String" : rt == :sym ? (r.op == :const ? ":" + @lower.syms.key(r.args[0]).to_s : "Symbol") : rt == :bool ? "true" : rt == :nil ? "nil" : arr(rt) ? "Array" : hsh(rt) ? "Hash" : rt.to_s
      into = lt == :float ? "Float" : "Integer"
      w = Inst.new(:sconst, [what]); w.ty = :str; w.block = i.block; i.block.insts.insert(i.block.insts.index(i), w)
      n = Inst.new(:sconst, [into]); n.ty = :str; n.block = i.block; i.block.insts.insert(i.block.insts.index(i), n)
      i.op = :call; i.args = [fn(:__raise_coerce), w, n]; i.ty = lt
      true
    end

    def self.drop_dead_phis(f)
      loop do
        used = Passes.phi_liveness(f.all)
        dead = f.blocks.flat_map { |b| b.phis.select { |p| !used[p] } }
        break if dead.empty?
        f.blocks.each { |b| b.phis.reject! { |p| dead.include?(p) } }
      end
    end

    # the Ruby method a prelude family function implements: __arr_sort_by$1 -> :sort_by, __str_to_i1 -> :to_i, __num_even_p -> :even?
    def self.method_name_of(callee)
      base = callee.name.to_s.sub(/\$.*\z/, "").sub(/\A__(str|arr|hash|num)_/, "")
      base = base.sub(/\d+\z/, "") # arity suffix
      base = base.sub(/_p\z/, "?").sub(/_bang\z/, "!")
      return nil if base.empty? || base.include?("_") && !%i[each_with_index each_slice each_cons sort_by group_by min_by max_by each_with_object find_index take_while drop_while flat_map filter_map start_with? end_with? to_s to_i to_f to_a to_h to_sym each_char each_line each_byte].include?(base.to_sym) && !Lower::ENUMERABLE.include?(base.to_sym)
      base.to_sym
    end

    def self.unbox_fn(dest)
      case dest
      when :int, :int? then :__dyn_int
      when :str then :__dyn_str
      when :sym then :__dyn_sym
      when :float then :__dyn_float
      else arr(dest) ? :__dyn_arr : hsh(dest) ? :__dyn_hash : nil
      end
    end

    # the value v as the slot type dest, or v itself when no change of representation is needed
    def self.coerce(f, blk, before, v, dest)
      t = of(f, v)
      return v if t.nil? || dest.nil? || t == dest
      c = case
          when dest == :float && (t == :int || t == :int?) then Inst.new(:itof, [v]).tap { _1.ty = :float } # a nil here would have raised already
          when dest == :dyn && t != :dyn then Inst.new(:box, [v, t]).tap { _1.ty = :dyn }
          when t == :dyn && (un = unbox_fn(dest)) then Inst.new(:call, [fn(un), v]).tap { _1.ty = dest } # a tagged value into a typed slot: unbox, trapping on the wrong tag
          when big?(dest) && %i[int int?].include?(t) then Inst.new(:call, [fn(:__big_from_int), v]).tap { _1.ty = BIG }
          else return v
          end
      c.block = blk
      blk.insts.insert(blk.insts.index(before), c)
      c
    end
  end
end
