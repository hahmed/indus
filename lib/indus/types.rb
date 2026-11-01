# Type inference: int / float / iarr / farr to a fixpoint, then insert conversions.
module Indus
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
end
