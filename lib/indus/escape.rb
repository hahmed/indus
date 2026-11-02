# Escape analysis -> memory tiers. Everything here is static.
#
# Tier 0, stack objects: an `onew` whose result never escapes -- not stored
# into a field/array/global, not returned, not passed to a call that keeps
# it (interprocedural, to a fixpoint over Func#leaks) -- is allocated in the
# frame. No heap, no header, freed by `ret`.
#
# Tier 1, loop regions: if nothing allocated during a loop iteration can
# survive the back edge (no heap-typed value defined in the body reaches a
# header phi, a store into pre-existing memory, a return, or a use outside
# the body), the bump pointer is reset at every back edge. The per-request
# arena, derived by the compiler. Stores into objects that are themselves
# fresh this iteration (Node.new(l, r) -> initialize writes @left) are fine.
module Indus
  module Escape
    def self.heap?(t) = t.is_a?(Symbol) && !%i[int float nil].include?(t) || (t.is_a?(Array) && %i[arr poly hash].include?(t[0])) # :str and classes are heap
    def self.ty(f, v) = v.op == :param ? f.ptypes[f.params.index(v)] : v.ty

    def self.run(funcs, classes)
      @classes = classes
      funcs.each do |f|
        f.leaks = Array.new(f.params.size, false)       # param k flows somewhere that keeps it
        f.stores_param = Array.new(f.params.size, false) # a heap value is stored into param k
        f.stores_other = false                           # a heap value is stored into non-param memory / global
      end
      loop do
        changed = false
        funcs.each do |f|
          esc = escaped(f)
          f.params.each_with_index { |p, k| (f.leaks[k] = true; changed = true) if esc[p] && !f.leaks[k] }
          sp, so = store_summary(f)
          sp.each_with_index { |b, k| (f.stores_param[k] = true; changed = true) if b && !f.stores_param[k] }
          (f.stores_other = true; changed = true) if so && !f.stores_other
        end
        break unless changed
      end
      funcs.each { |f| tier0(f); tier1(f) }
    end

    # values of f that escape: worklist over the "keeps it" positions
    def self.escaped(f)
      esc = {}
      mark = ->(v) { esc[v] = true if v.is_a?(Inst) && !esc[v] }
      f.all.each do |i|
        case i.op
        when :fld_set then mark.(i.args[2])
        when :aset then mark.(i.args[2])
        when :hset then mark.(i.args[1]); mark.(i.args[2])
        when :gset then mark.(i.args[1])
        when :ret then mark.(i.args[0])
        when :call
          callee, *args = i.args
          args.each_with_index { |a, k| mark.(a) if callee.leaks[k] }
        when :pcall
          arms, recv, *args = i.args
          arms.each do |_, kind, payload|
            case kind
            when :call then [recv, *args].each_with_index { |a, k| mark.(a) if payload.leaks[k] }
            when :fld_set then mark.(args[0])
            end
          end
        end
      end
      # propagate backwards through phis and forwards into them
      loop do
        before = esc.size
        f.all.each do |i|
          next unless i.op == :phi
          if esc[i] then i.args.each { |(_, v)| mark.(v) }
          elsif i.args.any? { |(_, v)| esc[v] } then mark.(i) end
        end
        break if esc.size == before
      end
      esc
    end

    # a store into memory this function allocated itself keeps nothing alive
    # beyond what the allocation already does
    def self.fresh_here?(v) = v.is_a?(Inst) && %i[onew anew hnew].include?(v.op)

    def self.store_summary(f)
      sp = Array.new(f.params.size, false); so = false
      into = ->(o) { o.op == :param ? sp[f.params.index(o)] = true : (so = true unless fresh_here?(o)) }
      f.all.each do |i|
        case i.op
        when :fld_set
          o, _, v = i.args
          into.(o) if heap?(ty(f, v))
        when :aset, :hset
          a, k, v = i.args
          into.(a) if heap?(ty(f, v)) || (i.op == :hset && heap?(ty(f, k)))
        when :gset then so = true if heap?(ty(f, i.args[1]))
        when :call
          callee, *args = i.args
          so ||= callee.stores_other
          args.each_with_index { |a, k| into.(a) if callee.stores_param[k] }
        when :pcall then so = true # conservative
        end
      end
      [sp, so]
    end

    # ---- tier 0
    def self.tier0(f)
      esc = escaped(f)
      f.all.each { |i| i.stack = true if i.op == :onew && !esc[i] }
    end

    # ---- tier 1
    def self.tier1(f)
      f.blocks.each do |h|
        next unless h.name.to_s.start_with?("head") && !h.phis.empty?
        pre = h.phis.first.args[0][0]
        latches = f.blocks.select { |b| b.succs.include?(h) && b != pre }
        next if latches.empty?
        body = loop_body(f, h, latches)
        next unless region_safe?(f, h, body)
        # save the bump pointer before the loop, restore on every back edge
        save = Inst.new(:hsave); save.ty = :int; save.block = pre
        pre.insts.insert(pre.insts.index(pre.term), save)
        latches.each { |l| r = Inst.new(:hrestore, [save]); r.block = l; l.insts.insert(l.insts.index(l.term), r) }
      end
    end

    def self.loop_body(f, h, latches)
      body = {}; work = latches.dup
      until work.empty?
        b = work.shift; next if body[b] || b == h
        body[b] = true
        f.blocks.each { |p| work << p if p.succs.include?(b) }
      end
      body[h] = true
      body
    end

    def self.region_safe?(f, h, body)
      fresh = {} # heap-typed values defined this iteration
      body.each_key { |b| (b.phis + b.insts).each { |i| fresh[i] = true if heap?(i.ty) && !(b == h && i.op == :phi) } }
      body.each_key do |b|
        b.insts.each do |i|
          case i.op
          when :fld_set, :aset, :hset
            o, k, v = i.args
            return false if heap?(ty(f, v)) && !fresh[o]      # heap value into pre-existing memory
            return false if i.op == :hset && heap?(ty(f, k)) && !fresh[o]
          when :gset then return false if heap?(ty(f, i.args[1]))
          when :ret then return false if heap?(ty(f, i.args[0]))
          when :call
            callee, *args = i.args
            return false if callee.stores_other
            args.each_with_index { |a, k| return false if callee.stores_param[k] && !fresh[a] }
          when :pcall then return false
          when :hsave, :hrestore then return false # already a region at this level
          end
          # a fresh value used outside the body survives the loop
          i.args.each { |a| return false if a.is_a?(Inst) && fresh[a] && !body[i.block] } if false
        end
        b.succs.each { |s| s.phis.each { |p| p.args.each { |(pred, v)| return false if pred == b && fresh[v] && (s == h || !body[s]) } } }
      end
      # uses outside the body
      f.blocks.each do |b|
        next if body[b]
        (b.phis + b.insts).each do |i|
          vals = i.op == :phi ? i.args.map(&:last) : i.args
          return false if vals.any? { |a| a.is_a?(Inst) && fresh[a] }
        end
      end
      true
    end
  end
end
