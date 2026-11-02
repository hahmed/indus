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
      return :int? if (a == :int? && b == :nil) || (a == :nil && b == :int?)
      return [:arr, join(a[1], b[1])] if arr(a) && arr(b)
      return [:hash, join(a[1], b[1]), join(a[2], b[2])] if hsh(a) && hsh(b)
      # two classes meet: a closed poly set (whole program, so it is finite)
      ca, cb = classes_of(a), classes_of(b)
      return [:poly, (ca | cb).sort] if ca && cb
      raise "type clash: #{a.inspect} vs #{b.inspect}"
    end
    def self.classes_of(t)
      return t[1] if poly?(t)
      [t] if t.is_a?(Symbol) && @classes[t]
    end
    def self.poly?(t) = t.is_a?(Array) && t[0] == :poly
    def self.of(f, v) = v.op == :param ? f.ptypes[f.params.index(v)] : v.ty
    def self.arr(t) = t.is_a?(Array) && t[0] == :arr
    def self.hsh(t) = t.is_a?(Array) && t[0] == :hash

    def self.run(funcs, classes, lower = nil)
      @classes = classes; @lower = lower || @lower
      @ivars = Hash.new { |h, k| h[k] = {} } # class name -> ivar index -> type
      @consts = {}
      funcs.each { |f| next if f.ptypes; f.ptypes = Array.new(f.params.size); f.rtype = nil; f.ptypes[0] = f.cls.name if f.cls }
      loop do
        changed = false
        set = ->(cur, nt, &w) { (w.call(join(cur, nt)); changed = true) if nt && join(cur, nt) != cur }
        funcs.each do |f|
          f.all.each do |i|
            bind(f, i) if i.op == :mcall
            dsend(f, i) if i.op == :dsend
            index(f, i) if i.op == :idx || i.op == :idx_set
            t = infer(f, i)
            set.(i.ty, t) { i.ty = _1 }
            case i.op
            when :call
              callee = i.args[0]
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
            when :ret then set.(f.rtype, of(f, i.args[0])) { f.rtype = _1 }
            when :aset
              a, _, v = i.args
              nt = [:arr, of(f, v)]
              cur = of(f, a)
              if of(f, v) && (cur.nil? || (arr(cur) && join(cur, nt) != cur))
                a.op == :param ? f.ptypes[f.params.index(a)] = join(cur, nt) : a.ty = join(cur, nt); changed = true
              end
            when :hset
              h, k, v = i.args
              kt, vt = of(f, k), of(f, v)
              if kt && vt && vt != :nil
                nt = [:hash, kt, vt]; cur = of(f, h)
                if cur.nil? || join(cur, nt) != cur
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
        break unless changed
      end
      # classes that appear in any poly type carry a tag word
      tag = ->(t) { classes_of(t)&.each { @classes[_1].tagged = true } if poly?(t) || arr(t) && poly?(t[1]) }
      funcs.each { |f| f.all.each { tag.(_1.ty) }; f.ptypes.each { tag.(_1) }; tag.(f.rtype) }
      @ivars.each_value { |h| h.each_value { tag.(_1) } }
      funcs.each { convert(_1) }
      funcs.each { strings(_1) }
    end

    # generic ops whose operands turned out to be strings
    def self.strings(f)
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
          (i.op = :seq; i.cond = nil) if of(f, l) == :str && of(f, r) == :str && i.cond == :eq # nil stays a pointer compare
          if of(f, l) == :int? && of(f, r) == :nil then r.args[0] = INT_NIL; r.ty = :int
          elsif of(f, r) == :int? && of(f, l) == :nil then l.args[0] = INT_NIL; l.ty = :int end
        when :to_s then i.op = of(f, i.args[0]) == :str ? :nop : :itos
        when :puts_v then i.op = { str: :puts_str, bool: :puts_bool, int?: :puts_opt, nil: :puts_nil }.fetch(of(f, i.args[0]), :puts_i)
        when :lshift_or_append then i.op = of(f, i.args[0]) == :int ? :shl : :sappend
        end
      end
    end

    # :mcall name, recv, args -> :call Func / :fld_get / :fld_set
    def self.bind(f, i)
      name, recv, *args = i.args
      t = of(f, recv)
      if poly?(t) # one arm per class: [klass, kind, payload]
        arms = t[1].map { |c| [@classes[c], *resolve(@classes[c], name, args.size)] }
        i.op = :pcall; i.args = [arms, recv, *args]
        return
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

    def self.resolve(klass, name, nargs, allow_missing: false)
      if (iv = klass.find_reader(name)) && nargs == 0 then [:fld_get, klass.ivar(iv)]
      elsif (iv = klass.find_writer(name)) && nargs == 1 then [:fld_set, klass.ivar(iv)]
      elsif (m = klass.find_method(name)) then [:call, m]
      elsif allow_missing && (mm = klass.find_method(:method_missing)) then [:missing, mm]
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
      when :sconst, :scat, :sappend, :itos then :str
      when :seq then :bool
      when :puts_i, :puts_str, :puts_bool, :puts_opt, :puts_nil then :int
      when :idx, :idx_set, :dsend, :mcall then nil
      when :lshift_or_append then (t = of(f, a[0])) && (t == :int ? :int : t)
      when :to_s then (t = of(f, a[0])) && (t == :str ? :str : narrow(t) == :int ? :str : nil)
      when :puts_v then of(f, a[0]) && :int
      when :add, :sub, :mul, :div then join(narrow(of(f, a[0])), narrow(of(f, a[1])))
      when :and, :or then (of(f, a[0]) == :bool && of(f, a[1]) == :bool) ? :bool : :int
      when :xor, :shl, :shr, :mod, :to_i, :alen, :ipow then :int
      when :cmp then :bool
      when :pcall then a[0].map { arm_type(f, i, _1) }.reduce(nil) { join(_1, _2) }
      when :sendsw then a[0].map { |(_, kind, payload)| sw_arm_type(f, i, kind, payload) }.reduce(nil) { join(_1, _2) }
      when :dsend then nil
      when :to_f, :fsqrt, :libm then :float
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
            i.args.map! { |v| of(f, v) == :int ? cvt.(b, i, v) : v }
            i.cond = :"f#{i.cond}" if i.op == :cmp
          when :fsqrt then i.args[0] = cvt.(b, i, i.args[0]) if of(f, i.args[0]) == :int
          when :libm then i.args[1] = cvt.(b, i, i.args[1]) if of(f, i.args[1]) == :int
          when :pow
            if i.ty == :float
              i.args.map! { |v| of(f, v) == :int ? cvt.(b, i, v) : v }; i.op = :fpow
            else i.op = :ipow end
          when :aset
            a, _, v = i.args
            i.args[2] = cvt.(b, i, v) if arr(of(f, a)) && of(f, a)[1] == :float && of(f, v) == :int
          when :fld_set
            o, ix, v = i.args
            i.args[2] = cvt.(b, i, v) if ivar_type(of(f, o), ix) == :float && of(f, v) == :int
          when :gset then i.args[1] = cvt.(b, i, i.args[1]) if @consts[i.args[0]] == :float && of(f, i.args[1]) == :int
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
end
