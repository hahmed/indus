# Register allocation: linear scan over real liveness.
#
# 1. Number instructions in layout order. Phis sit at their block's first
#    position; a phi's arguments are uses at the end of each predecessor.
# 2. Liveness by iterative dataflow over the CFG (live_in / live_out per
#    block), so loops and values defined before a loop and used inside it
#    are handled by construction, not by patches.
# 3. One interval per value: [def, last position it is live]. Conservative
#    (no holes) but correct.
# 4. Linear scan: intervals sorted by start; expire; pick a pool. An
#    interval that crosses a call may only take a callee-saved register or
#    spill; one that does not prefers caller-saved and may fall back to
#    callee. When out of registers, spill the active interval that ends
#    last (or the new one). Phis pass a register hint to their arguments
#    and vice versa, so loop-carried values usually need no move.
#
# Results land on Inst#reg / Inst#slot exactly as before; codegen is unchanged.
module Indus
  class RegAlloc
    CALLEE = (19..26).to_a   # x27 globals, x28 heap
    CALLER = (10..15).to_a   # x8, x9 scratch; x16, x17 scratch
    FCALLEE = (8..15).to_a
    FCALLER = (16..29).to_a  # d30, d31 scratch

    Interval = Struct.new(:v, :start, :stop, :crosses_call, :hint, :gc_home, :gc_slot)

    attr_reader :used, :fused, :nslots, :safepoint_live

    def initialize(f) = @f = f

    def run
      f = @f
      blocks = f.blocks
      # ---- numbering: block start, each inst
      pos = {}; bstart = {}; bend = {}
      n = 0
      blocks.each do |b|
        bstart[b] = n
        b.phis.each { pos[_1] = n }
        n += 1
        b.insts.each { |i| pos[i] = n; n += 1 }
        bend[b] = n - 1
      end
      f.params.each { pos[_1] = -1 }
      skip = ->(i) { i.term? || %i[const fconst puts_s puts_i puts_str puts_bool puts_opt puts_nil puts_nil_word p_str print_i print_str putc gset fld_set seam hrestore rawst trap].include?(i.op) || (i.op == :cmp && fused?(i)) }
      value = ->(x) { x.is_a?(Inst) && !skip.(x) && !%i[const fconst].include?(x.op) }

      # ---- liveness
      use = Hash.new { |h, k| h[k] = {} }; dfn = Hash.new { |h, k| h[k] = {} }
      blocks.each do |b|
        b.phis.each { dfn[b][_1] = true }
        b.insts.each do |i|
          i.args.each { |a| use[b][a] = true if value.(a) && !dfn[b][a] }
          dfn[b][i] = true unless skip.(i)
        end
        b.succs.each do |s|
          s.phis.each { |p| p.args.each { |(pred, v)| use[b][v] = true if pred == b && value.(v) && !dfn[b][v] } }
        end
      end
      live_in = Hash.new { |h, k| h[k] = {} }; live_out = Hash.new { |h, k| h[k] = {} }
      loop do
        changed = false
        blocks.reverse_each do |b|
          out = {}
          b.succs.each do |s|
            live_in[s].each_key { |v| out[v] = true unless s.phis.include?(v) }
            s.phis.each { |p| p.args.each { |(pred, v)| out[v] = true if pred == b && value.(v) } }
          end
          inn = use[b].dup
          out.each_key { |v| inn[v] = true unless dfn[b][v] }
          if inn != live_in[b] || out != live_out[b]
            live_in[b] = inn; live_out[b] = out; changed = true
          end
        end
        break unless changed
      end

      # ---- intervals
      iv = {}
      get = ->(v) { iv[v] ||= Interval.new(v, pos[v], pos[v], false, nil) }
      blocks.each do |b|
        live_out[b].each_key { |v| get.(v).stop = [get.(v).stop, bend[b]].max }
        live_in[b].each_key { |v| get.(v).stop = [get.(v).stop, bstart[b]].max }
        b.insts.each do |i|
          i.args.each { |a| get.(a).stop = [get.(a).stop, pos[i]].max if value.(a) }
          get.(i) unless skip.(i)
        end
        b.phis.each { |p| get.(p); p.args.each { |(pred, v)| get.(v).stop = [get.(v).stop, bend[pred]].max if value.(v) } }
      end
      f.params.each { get.(_1) }
      calls = blocks.flat_map { |b| b.insts.select(&:call?).map { pos[_1] } }
      # a call at the interval's last use consumes the value before clobbering: not a crossing
      iv.each_value { |it| it.crosses_call = calls.any? { |c| c > it.start && c < it.stop } }
      # GC mode: a pointer that is live at a call -- including as that call's argument, since a
      # collection may run before the callee sees it -- must sit in a frame slot the collector can find
      # GC: a pointer live at a safepoint keeps its register but also gets a typed
      # home slot; codegen stores it there right before the collection check and
      # reloads after. Per-safepoint live sets tell codegen which ones.
      @safepoint_live = {}
      if GC.enabled?
        sps = blocks.flat_map { |b| b.insts.select { GC.needs_safepoint?(_1) } }
        crossings = Hash.new(0)
        sps.each do |sp|
          c = pos[sp]
          live = iv.values.select { |it| GC.pointer?(it.v.ty) && c > it.start && c <= it.stop }
          live.each { |it| crossings[it] += 1 }
          @safepoint_live[sp] = live.map(&:v)
        end
        # a value that crosses more safepoints than it has uses is cheaper in its slot
        # (one load per use) than in a register with a home (store+load per safepoint)
        uses = Hash.new(0)
        blocks.each { |b| (b.phis + b.insts).each { |i| (i.op == :phi ? i.args.map(&:last) : i.args).each { uses[_1] += 1 if _1.is_a?(Inst) } } }
        crossings.each { |it, n| n > uses[it.v] ? it.gc_slot = true : it.gc_home = true }
      end
      # phi hints: phi <-> its args
      blocks.each do |b|
        b.phis.each do |p|
          p.args.each { |(_, v)| next unless iv[v]; iv[v].hint ||= p; iv[p].hint ||= v }
        end
      end

      # ---- linear scan
      intervals = iv.values.sort_by { [_1.start, _1.stop] }
      active = []
      free = { CALLEE => CALLEE.dup, CALLER => CALLER.dup, FCALLEE => FCALLEE.dup, FCALLER => FCALLER.dup }
      pool_of = ->(r, fl) { fl ? (FCALLEE.include?(r) ? FCALLEE : FCALLER) : (CALLEE.include?(r) ? CALLEE : CALLER) }
      @used = []; @fused = []; @nslots = 0
      take = ->(it, r) {
        it.v.reg = r
        fl = it.v.float?
        (fl ? @fused : @used) << r if (fl ? FCALLEE : CALLEE).include?(r) && !(fl ? @fused : @used).include?(r)
        active << it
      }
      spill = ->(it) { it.v.slot = @nslots; @nslots += 1 }

      intervals.each do |it|
        if it.gc_slot then spill.(it); next end                   # lives in its (typed) slot
        if it.gc_home then it.v.home = @nslots; @nslots += 1 end # register + typed home slot for safepoints
        # expire
        active.reject! do |a|
          if a.stop < it.start
            free[pool_of.(a.v.reg, a.v.float?)].unshift(a.v.reg) if a.v.reg
            true
          end
        end
        fl = it.v.float?
        pools = if it.crosses_call then [fl ? FCALLEE : CALLEE]
                else fl ? [FCALLER, FCALLEE] : [CALLER, CALLEE] end
        # hint first, if it is free and in an allowed pool
        h = it.hint&.reg
        if h && pools.any? { |p| free[p].include?(h) }
          free[pool_of.(h, fl)].delete(h); take.(it, h); next
        end
        pool = pools.find { free[_1].any? }
        if pool
          take.(it, free[pool].shift)
        else
          # spill: the active interval in an allowed pool that ends last, if later than ours
          cands = active.select { |a| a.v.reg && pools.include?(pool_of.(a.v.reg, fl)) && a.v.op != :param }
          victim = cands.max_by(&:stop)
          if victim && victim.stop > it.stop
            r = victim.v.reg; victim.v.reg = nil; spill.(victim); active.delete(victim)
            take.(it, r)
          else
            spill.(it)
          end
        end
      end
      @used.sort!; @fused.sort!
      self
    end

    def fused?(c)
      nxt = c.block.insts[c.block.insts.index(c) + 1]
      nxt&.op == :condbr && nxt.args[0] == c
    end
  end
end
