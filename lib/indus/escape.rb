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
        # a patchable method can be replaced by anything at run time: assume it keeps and stores everything
        f.leaks = Array.new(f.params.size, !!f.patchable)       # param k flows somewhere that keeps it
        f.stores_param = Array.new(f.params.size, !!f.patchable) # a heap value is stored into param k
        f.stores_other = !!f.patchable                           # a heap value is stored into non-param memory / global
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
      funcs.each { |f| tier0(f) unless ENV["NOTIER0"]; tier1(f) unless ENV["NOTIER1"] || ENV["NOTIER1_FN"] == f.name.to_s }
    end

    # values of f that escape: worklist over the "keeps it" positions
    def self.escaped(f)
      esc = {}
      mark = ->(v) { esc[v] = true if v.is_a?(Inst) && !esc[v] }
      f.all.each do |i|
        case i.op
        when :fld_set then mark.(i.args[2])
        when :cell_new then mark.(i.args[0])
        when :cell_set then mark.(i.args[1])
        when :box, :mkbuf, :raise then mark.(i.args[0]) # a tagged value / a cell's content / an exception is tracked no further
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
        when :sendsw
          arms, _, recv, *args = i.args
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
        when :bufappend then into.(i.args[0]) # the grown string is stored into the cell
        when :cell_set then into.(i.args[0]) if heap?(ty(f, i.args[1]))
        when :aset, :hset
          a, k, v = i.args
          into.(a) if heap?(ty(f, v)) || (i.op == :hset && heap?(ty(f, k)))
        when :gset then so = true if heap?(ty(f, i.args[1]))
        when :call
          callee, *args = i.args
          so ||= callee.stores_other
          args.each_with_index { |a, k| into.(a) if callee.stores_param[k] }
        when :pcall, :sendsw then so = true # conservative
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
        next unless body.keys.any? { |b| b.insts.any? { |i| GC::DIRECT_ALLOC.include?(i.op) || (i.op == :call && (i.args[0].allocates.nil? || i.args[0].allocates)) || %i[pcall sendsw].include?(i.op) } } # a reset is only worth it if the body allocates
        next unless region_safe?(f, h, body)
        # save the bump pointer before the loop, restore on every back edge
        save = Inst.new(:hsave); save.ty = :int; save.block = pre
        epoch = Inst.new(:gcepoch); epoch.ty = :int; epoch.block = pre # the collection count: a restore is valid only if nothing moved since
        pre.insts.insert(pre.insts.index(pre.term), save); pre.insts.insert(pre.insts.index(pre.term), epoch)
        latches.each { |l| r = Inst.new(:hrestore, [save, epoch]); r.block = l; l.insts.insert(l.insts.index(l.term), r) }
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

    OWN_ALLOC = %i[onew anew hnew sconst scat sappend itos ssub chr sdup salloc cell_new mkbuf box aset hset bufappend].freeze
    def self.region_safe?(f, h, body)
      fresh = {} # heap-typed values defined this iteration (may be fresh: used to detect leaks)
      body.each_key { |b| (b.phis + b.insts).each { |i| fresh[i] = true if heap?(i.ty) && !(b == h && i.op == :phi) } }
      # surely allocated this iteration: a store into one of these cannot leak. A load (aget,
      # fld_get, bufderef ...) or a call result may be a pre-existing object, so it is not here.
      own = {}
      body.each_key { |b| b.insts.each { |i| own[i] = true if OWN_ALLOC.include?(i.op) && heap?(i.ty) && (!%i[aset hset bufappend].include?(i.op) || own[i.args[0]]) } }
      body.each_key do |b|
        b.insts.each do |i|
          case i.op
          when :bufappend then return false unless own[i.args[0]] # a grown buffer into a pre-existing cell
          when :cell_set then return false if heap?(ty(f, i.args[1])) && !own[i.args[0]]
          when :fld_set, :aset, :hset
            o, k, v = i.args
            return false if heap?(ty(f, v)) && !own[o]      # heap value into pre-existing memory
            return false if i.op == :hset && heap?(ty(f, k)) && !own[o]
          when :gset then return false if heap?(ty(f, i.args[1]))
          when :ret then return false if heap?(ty(f, i.args[0]))
          when :call
            callee, *args = i.args
            return false if callee.stores_other
            args.each_with_index { |a, k| return false if callee.stores_param[k] && !fresh[a] }
          when :pcall, :sendsw then return false
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
