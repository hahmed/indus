# Type inference, to a fixpoint across functions, then conversions.
#   :int :float :nil  a class name (Symbol)  [:arr, elem]
# Params from call sites, returns from ret sites, ivars from writes, array
# elements from fills and stores, constants from their writes. Method calls
# on objects (:mcall) are bound to a function or a field once the receiver's
# class is known.
module Indus
  module Types
    def self.join(a, b)
      return b if a.nil? || a == :nil
      return a if b.nil? || b == :nil || a == b
      return :float if (a == :int && b == :float) || (a == :float && b == :int)
      return [:arr, join(a[1], b[1])] if arr(a) && arr(b)
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

    def self.run(funcs, classes)
      @classes = classes
      @ivars = Hash.new { |h, k| h[k] = {} } # class name -> ivar index -> type
      @consts = {}
      funcs.each { |f| next if f.ptypes; f.ptypes = Array.new(f.params.size); f.rtype = nil; f.ptypes[0] = f.cls.name if f.cls }
      loop do
        changed = false
        set = ->(cur, nt, &w) { (w.call(join(cur, nt)); changed = true) if nt && join(cur, nt) != cur }
        funcs.each do |f|
          f.all.each do |i|
            bind(f, i) if i.op == :mcall
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
            when :ret then set.(f.rtype, of(f, i.args[0])) { f.rtype = _1 }
            when :aset
              a, _, v = i.args
              nt = [:arr, of(f, v)]
              cur = of(f, a)
              if of(f, v) && (cur.nil? || (arr(cur) && join(cur, nt) != cur))
                a.op == :param ? f.ptypes[f.params.index(a)] = join(cur, nt) : a.ty = join(cur, nt); changed = true
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
      kind, payload = resolve(klass, name, args.size)
      case kind
      when :fld_get then i.op = :fld_get; i.args = [recv, payload]
      when :fld_set then i.op = :fld_set; i.args = [recv, payload, args[0]]
      when :call then i.op = :call; i.args = [payload, recv, *args]
      end
    end

    def self.resolve(klass, name, nargs)
      if (iv = klass.find_reader(name)) && nargs == 0 then [:fld_get, klass.ivar(iv)]
      elsif (iv = klass.find_writer(name)) && nargs == 1 then [:fld_set, klass.ivar(iv)]
      elsif (m = klass.find_method(name)) then [:call, m]
      else raise "no method #{name} on #{klass.name}"
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
      when :const then i.ty == :nil ? :nil : :int
      when :fconst then :float
      when :add, :sub, :mul, :div then join(of(f, a[0]), of(f, a[1]))
      when :and, :or, :xor, :shl, :shr, :mod, :cmp, :to_i, :alen, :ipow then :int
      when :pcall then a[0].map { arm_type(f, i, _1) }.reduce(nil) { join(_1, _2) }
      when :to_f, :fsqrt then :float
      when :anew then (t = of(f, a[1])) && t != :nil ? [:arr, t] : nil
      when :aget then (t = of(f, a[0])) && arr(t) ? t[1] : nil
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
      klass = @classes[k]
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
