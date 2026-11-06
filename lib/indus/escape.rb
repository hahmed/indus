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
        f.returns_fresh = false                                  # every ret is an object allocated here that nothing else holds
      end
      loop do
        changed = false
        funcs.each do |f|
          esc = escaped(f)
          esc_noret = escaped(f, with_ret: false)
          f.params.each_with_index { |p, k| (f.leaks[k] = true; changed = true) if esc[p] && !f.leaks[k] }
          sp, so = store_summary(f)
          sp.each_with_index { |b, k| (f.stores_param[k] = true; changed = true) if b && !f.stores_param[k] }
          (f.stores_other = true; changed = true) if so && !f.stores_other
          (f.returns_fresh = true; changed = true) if !f.returns_fresh && fresh_ret?(f, esc_noret)
        end
        break unless changed
      end
      funcs.each { |f| tier0(f) unless ENV["NOTIER0"]; tier1(f) unless ENV["NOTIER1"] || ENV["NOTIER1_FN"] == f.name.to_s }
    end

    # f returns a value it allocated (directly, or through a callee that does) and stored nowhere:
    # the caller is the only holder. Only strings and string cells, the shapes a region can copy out.
    def self.fresh_ret?(f, esc)
      rets = f.all.select { |i| i.op == :ret }
      return false if rets.empty? || f.patchable
      rets.all? do |r|
        v = r.args[0]
        v.is_a?(Inst) && %i[str strbuf].include?(v.ty) && !esc[v] &&
          ((OWN_ALLOC.include?(v.op) && !%i[aset hset bufappend].include?(v.op)) || (v.op == :call && v.args[0].returns_fresh))
      end
    end

    # values of f that escape: worklist over the "keeps it" positions
    def self.escaped(f, with_ret: true)
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
        when :ret then mark.(i.args[0]) if with_ret
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
    def self.fresh_here?(v) = v.is_a?(Inst) && %i[onew anew hnew mkbuf cell_new].include?(v.op) # memory this function made (a cell holds one word, like a field)

    def self.store_summary(f)
      sp = Array.new(f.params.size, false); so = false
      # the memory written is whatever o came from: through phis, and through bufappend / aset / hset results
      # (the same container, possibly reallocated)
      origins = ->(o, seen = {}) do
        return [] if seen[o]; seen[o] = true
        case o.op
        when :phi then o.args.flat_map { |(_, v)| origins.(v, seen) }
        when :bufappend, :aset, :hset then origins.(o.args[0], seen)
        else [o]
        end
      end
      into = ->(o) { origins.(o).each { |r| r.op == :param ? sp[f.params.index(r)] = true : (so = true unless fresh_here?(r)) } }
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
        surv = region_safe?(f, h, body)
        next unless surv
        next if !(surv[:grown].empty? && surv[:keeps].empty?) && latches.size > 1 # survivors must dominate the latch; one latch keeps that trivially
        next unless surv[:keeps].all? { |st| st.block == latches[0] } # the store happens every iteration, in the latch block
        # save the bump pointer before the loop, restore on every back edge. The mark and the collection
        # count are loop-carried: when a restore cannot happen (a collection ran, a container moved into
        # the region) the back edge starts a new region from where the heap is now, instead of giving up
        # for the rest of the loop.
        save0 = Inst.new(:hsave); save0.ty = :int; save0.block = pre
        epoch0 = Inst.new(:gcepoch); epoch0.ty = :int; epoch0.block = pre # the collection count: a restore is valid only if nothing moved since
        pre.insts.insert(pre.insts.index(pre.term), save0); pre.insts.insert(pre.insts.index(pre.term), epoch0)
        save = Inst.new(:phi, [[pre, save0]]); save.ty = :int; save.block = h
        epoch = Inst.new(:phi, [[pre, epoch0]]); epoch.ty = :int; epoch.block = h
        h.phis << save << epoch
        # a survivor stored into a pre-existing array: remember the slot (base after the store, so a grown
        # array is addressed through its new handle) and copy the value down at the back edge
        slots = surv[:keeps].map do |st|
          sl = Inst.new(:aslot, [st, st.args[1]]); sl.ty = :int; sl.block = st.block; sl.kind = st.args[2].ty
          st.block.insts.insert(st.block.insts.index(st) + 1, sl); sl
        end
        latches.each do |l|
          r = Inst.new(:hrestore, [save, epoch, *surv[:grown], *slots]); r.block = l; r.ngrown = surv[:grown].size; r.ty = :int # the mark for the next iteration
          e = Inst.new(:gcepoch); e.ty = :int; e.block = l
          l.insts.insert(l.insts.index(l.term), r); l.insts.insert(l.insts.index(l.term), e)
          save.args << [l, r]; epoch.args << [l, e]
        end
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
    # Survivors (notes/65). A region may keep two kinds of value across the back edge:
    #   keeps: a fresh string / string cell stored once into a pre-existing array ("rows << line");
    #          copied down to the saved mark at the back edge, the slot patched.
    #   grown: a pre-existing container that grew (its new handle lives in the region); the back edge
    #          skips the reset when that happened (rarely: growth doubles).
    # Anything else that escapes still refuses the region. Returns nil, or {keeps:, grown:}.
    KEEP_TYPES = %i[str strbuf].freeze
    def self.region_safe?(f, h, body)
      fresh = {} # heap-typed values defined this iteration (may be fresh: used to detect leaks)
      body.each_key { |b| (b.phis + b.insts).each { |i| fresh[i] = true if heap?(i.ty) && !(b == h && i.op == :phi) } }
      keeps = []; grown = []
      uses = Hash.new(0)
      f.all.each { |i| (i.op == :phi ? i.args.map(&:last) : i.args).each { |a| uses[a] += 1 if a.is_a?(Inst) } }
      # a value only this iteration holds: allocated here, or returned fresh by a callee, and used once (the store)
      sole = ->(v) { v.is_a?(Inst) && fresh[v] && KEEP_TYPES.include?(v.ty) && uses[v] == 1 &&
                     ((OWN_ALLOC.include?(v.op) && !%i[aset hset bufappend].include?(v.op)) || (v.op == :call && v.args[0].returns_fresh)) }
      # surely allocated this iteration: a store into one of these cannot leak. A load (aget,
      # fld_get, bufderef ...) or a call result may be a pre-existing object, so it is not here.
      own = {}
      body.each_key { |b| b.insts.each { |i| own[i] = true if OWN_ALLOC.include?(i.op) && heap?(i.ty) && (!%i[aset hset bufappend].include?(i.op) || own[i.args[0]]) } }
      body.each_key do |b|
        b.insts.each do |i|
          case i.op
          when :bufappend then return nil unless own[i.args[0]] # a grown buffer into a pre-existing cell
          when :cell_set then return nil if heap?(ty(f, i.args[1])) && !own[i.args[0]]
          when :fld_set, :aset, :hset
            o, k, v = i.args
            if i.op == :aset && heap?(ty(f, v)) && !own[o] && sole.(v) && !fresh[o] then keeps << i
            else
              return nil if heap?(ty(f, v)) && !own[o]      # heap value into pre-existing memory
            end
            return nil if i.op == :hset && heap?(ty(f, k)) && !own[o]
            if %i[aset hset].include?(i.op) && !own[o] && !fresh[o] then grown << i end # may have reallocated the container
          when :gset then return nil if heap?(ty(f, i.args[1]))
          when :ret then return nil if heap?(ty(f, i.args[0]))
          when :call
            callee, *args = i.args
            return nil if callee.stores_other
            args.each_with_index { |a, k| return nil if callee.stores_param[k] && !own[a] } # the callee stores into it: it must be ours this iteration (a load is not)
          when :pcall, :sendsw then return nil
          when :hsave, :hrestore then return nil # already a region at this level
          end
          # a fresh value used outside the body survives the loop
          i.args.each { |a| return nil if a.is_a?(Inst) && fresh[a] && !body[i.block] } if false
        end
        b.succs.each { |s| s.phis.each { |p| p.args.each { |(pred, v)| return nil if pred == b && fresh[v] && (s == h || !body[s]) && !grown.include?(v) } } }
      end
      # uses outside the body
      f.blocks.each do |b|
        next if body[b]
        (b.phis + b.insts).each do |i|
          vals = i.op == :phi ? i.args.map(&:last) : i.args
          return nil if vals.any? { |a| a.is_a?(Inst) && fresh[a] && !grown.include?(a) }
        end
      end
      # a grown container's new handle must reach the back edge unchanged: it is the header phi's incoming value
      grown.each { |g| return nil unless h.phis.any? { |p| p.args.any? { |(_, v)| v == g } } }
      # the kept value's own container must be the one that reaches the back edge
      keeps.each { |k| return nil unless grown.include?(k) }
      { keeps: keeps, grown: grown.uniq }
    end
  end
end
