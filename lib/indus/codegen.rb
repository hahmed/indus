# SSA -> arm64: layout, register allocation, instruction selection.
module Indus
  class Codegen
    CALLEE = (19..26).to_a # x27 = globals base, x28 = heap bump pointer
    CALLER = (10..15).to_a # x8, x9 scratch
    FCALLEE = (8..15).to_a  # d8-d15
    FCALLER = (16..29).to_a # d30, d31 scratch
    TMP = 8; FTMP = 30; FTMP2 = 31

    def initialize(asm) = @asm = asm

    def layout(f)
      order, seen, work = [], {}, [f.entry]
      until work.empty?
        b = work.shift
        next if seen[b]
        seen[b] = true; order << b
        sc = b.succs
        if b.term.op == :condbr
          t, e = sc
          sc = e.cold ? [t, e] : [e, t] # fall into the loop body; else-first otherwise
        end
        work = sc + work
      end
      f.blocks = order
    end

    def func(f)
      @f = f
      layout(f)
      all = f.all
      idx = {}; all.each_with_index { |i, k| idx[i] = k }
      f.params.each { |p| idx[p] = -1 }
      last = Hash.new(-1)
      all.each_with_index do |i, k|
        if i.op == :phi
          i.args.each { |(pred, v)| last[v] = [last[v], idx[pred.term]].max if v.is_a?(Inst) }
        else
          i.args.each { |a| last[a] = [last[a], k].max if a.is_a?(Inst) }
        end
      end
      phis = all.select { _1.op == :phi }
      # a phi is live over its whole loop: from its block to the last pred terminator
      phis.each { |p| last[p] = [last[p], *p.args.map { |(pred, _)| idx[pred.term] }].max }
      # loops: a value defined before a loop and used inside it is live to the loop's end
      loops = f.blocks.filter_map do |h|
        next if h.phis.empty?
        back = f.blocks.select { |b| b.succs.include?(h) && idx[b.term] > idx[h.phis.first] }
        [idx[h.phis.first], back.map { idx[_1.term] }.max] unless back.empty?
      end
      loop do
        changed = false
        (f.params + all).each do |v|
          d = idx[v]
          loops.each do |(ls, le)|
            if d < ls && last[v] >= ls && last[v] < le then last[v] = le; changed = true end
          end
        end
        break unless changed
      end

      call_at = all.each_index.select { all[_1].call? }
      across = ->(v, from) { call_at.any? { |c| c > from && c < last[v] } }
      callee, caller = CALLEE.dup, CALLER.dup; used = []; freed = []
      fcallee, fcaller = FCALLEE.dup, FCALLER.dup; fused = []
      nslots = 0
      assign = ->(v, pool) {
        if v.float?
          pool = pool.equal?(callee) ? fcallee : fcaller
          r = pool.shift || (pool.equal?(fcallee) ? fcaller : fcallee).shift
          if r then fused |= [r] if FCALLEE.include?(r); v.reg = r
          else v.slot = nslots; nslots += 1 end
          next
        end
        r = pool.shift || (pool.equal?(callee) ? caller : callee).shift
        if r then used |= [r] if CALLEE.include?(r); v.reg = r
        else v.slot = nslots; nslots += 1 end # spill to the frame
      }
      phi_srcs = phis.flat_map { |p| p.args.map(&:last) }
      f.params.each_with_index { |p, k| p.ty = f.ptypes[k] || :int }
      f.params.each { |p| assign.(p, (across.(p, -1) || phi_srcs.include?(p)) ? callee : caller) }
      phis.each do |ph|
        src = ph.args.map(&:last).find { |v| v.op == :param && last[v] <= idx[ph] && phi_srcs.count(v) == 1 }
        if src then ph.reg = src.reg; src.shared = true
        else assign.(ph, across.(ph, idx[ph.block.insts.first] - 1) || across.(ph, -1) ? callee : caller) end
      end
      phis.each do |ph|
        ph.args.each do |(pred, v)|
          next unless v.is_a?(Inst) && !v.reg && !%i[param phi const fconst].include?(v.op) && v.block == pred
          next unless last[v] == idx[pred.term]
          after = pred.insts[(pred.insts.index(v) + 1)..].any? { |j| j.args.include?(ph) }
          (v.reg = ph.reg; v.shared = true) unless after || ph.reg.nil?
        end
      end
      all.each_with_index do |i, k|
        expired = (f.params + all[0...k]).select { |v| v.reg && !v.shared && last[v] < k && !freed.include?(v) }
        expired.each do |v|
          freed << v
          if v.float? then (FCALLEE.include?(v.reg) ? fcallee : fcaller).unshift(v.reg)
          else (CALLEE.include?(v.reg) ? callee : caller).unshift(v.reg) end
        end
        next if i.reg || i.slot || i.term? || %i[phi const fconst puts_s puts_i putc gset fld_set].include?(i.op)
        next if i.op == :cmp && fused?(i)
        assign.(i, across.(i, k) ? callee : caller)
      end

      used |= [Asm::HEAP, Asm::GBASE] if f.name == :main
      used.sort!; fused.sort!
      fsave = 16 + ((used.size + 1) / 2) * 16
      @spill_base = fsave + ((fused.size + 1) / 2) * 16
      frame = @spill_base + ((nslots + 1) / 2) * 16
      raise "frame too large" if frame > 504
      @asm.label(f.name)
      @asm.stp_pre(29, 30, frame); @asm.mov_fp_sp
      used.each_slice(2).with_index { |(a, b), i| @asm.stp(a, b, 16 + i * 16) }
      fused.each_slice(2).with_index { |(a, b), i| @asm.fstp(a, b, fsave + i * 16) }
      if f.name == :main # heap base arrives in x0: globals in the first 4K, bump pointer after
        @asm.mov(Asm::GBASE, 0); @asm.addi(Asm::HEAP, 0, 4096)
      end
      # params: ints in x0.., floats in d0.. (separate counters, AAPCS64)
      xi = fi = 0
      f.params.each { |p| p.float? ? (@asm.fmov(p.reg, fi); fi += 1) : (@asm.mov(p.reg, xi); xi += 1) }
      f.blocks.each { block(_1) }
      @asm.label(:"#{f.name}_ret")
      fused.each_slice(2).with_index { |(a, b), i| @asm.fldp(a, b, fsave + i * 16) }
      used.each_slice(2).with_index { |(a, b), i| @asm.ldp(a, b, 16 + i * 16) }
      @asm.ldp_post(29, 30, frame); @asm.ret
    end

    def fused?(c)
      nxt = c.block.insts[c.block.insts.index(c) + 1]
      nxt&.op == :condbr && nxt.args[0] == c
    end

    def imm?(v) = v.op == :const && (0..4095).cover?(v.args[0])

    SPILL = 17 # scratch for a spilled definition (x16/x17 are free between calls)

    def slot_off(v) = @spill_base + 8 * v.slot

    # a value in a register, loading a constant or a spilled value into tmp
    def reg(v, tmp = TMP)
      return freg(v, tmp == TMP ? FTMP : FTMP2) if v.float?
      return v.reg if v.reg
      return (@asm.ldr(tmp, slot_off(v)); tmp) if v.slot
      raise "no reg for #{v.op} #{v}" unless v.op == :const
      @asm.mov_imm(tmp, v.args[0]); tmp
    end
    def freg(v, tmp = FTMP)
      return v.reg if v.reg
      return (@asm.fldr(tmp, slot_off(v)); tmp) if v.slot
      raise "no freg for #{v.op} #{v}" unless v.op == :fconst
      @asm.fmov_imm(tmp, v.args[0]); tmp
    end

    # where a definition is written; stored to its slot afterwards if spilled
    def dst(i) = i.reg || (i.float? ? FTMP : SPILL)
    def spill!(i)
      return unless i.slot
      i.float? ? @asm.fstr(FTMP, slot_off(i)) : @asm.str(SPILL, slot_off(i))
    end

    def block(b)
      @asm.label(lbl(b))
      b.insts.each do |i|
        d = dst(i)
        case i.op
        when :const, :fconst then nil
        when :add, :sub, :mul, :div
          l, r = i.args
          if i.float?
            @asm.send({ add: :fadd, sub: :fsub, mul: :fmul, div: :fdiv }[i.op], d, freg(l), freg(r, FTMP2))
          elsif i.op == :div then @asm.sdiv_floor(d, reg(l), reg(r, 9))
          elsif i.op == :mul then @asm.mul(d, reg(l), reg(r, 9))
          elsif imm?(r) then @asm.send(i.op == :add ? :addi : :subi, d, reg(l), r.args[0])
          else @asm.send(i.op, d, reg(l), reg(r, 9)) end
        when :itof then @asm.scvtf(d, reg(i.args[0]))
        when :fsqrt then @asm.fsqrt(d, freg(i.args[0]))
        when :alen then @asm.ldur(d, reg(i.args[0]), -8)
        when :onew
          @asm.mov_imm(0, [i.args[0].size, 8].max); @asm.bl(:__onew); @asm.mov(d, 0)
        when :ipow
          @asm.mov(0, reg(i.args[0], 0)); @asm.mov(1, reg(i.args[1], 1)); @asm.bl(:__ipow); @asm.mov(d, 0)
        when :fld_get
          o, ix = i.args
          i.float? ? @asm.fldr_off(d, reg(o), ix * 8) : @asm.ldr_off(d, reg(o), ix * 8)
        when :fld_set
          o, ix, v = i.args; ro = reg(o)
          v.float? ? @asm.fstr_off(freg(v), ro, ix * 8) : @asm.str_off(reg(v, 9), ro, ix * 8)
        when :gget
          off = @asm.global(i.args[0])
          i.float? ? @asm.fldr_off(d, Asm::GBASE, off) : @asm.ldr_off(d, Asm::GBASE, off)
        when :gset
          name, v = i.args; off = @asm.global(name)
          v.float? ? @asm.fstr_off(freg(v), Asm::GBASE, off) : @asm.str_off(reg(v, 9), Asm::GBASE, off)
        when :to_f then @asm.scvtf(d, reg(i.args[0]))
        when :to_i then i.args[0].float? ? @asm.fcvtzs(d, freg(i.args[0])) : @asm.mov(d, reg(i.args[0]))
        when :putc
          @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:__putc)
        when :and then @asm.and_(d, reg(i.args[0]), reg(i.args[1], 9))
        when :or  then @asm.orr(d, reg(i.args[0]), reg(i.args[1], 9))
        when :xor then @asm.eor(d, reg(i.args[0]), reg(i.args[1], 9))
        when :shl then @asm.lslv(d, reg(i.args[0]), reg(i.args[1], 9))
        when :shr then @asm.asrv(d, reg(i.args[0]), reg(i.args[1], 9))
        when :anew
          l, v = i.args
          @asm.mov(0, reg(l, 0))
          v.float? ? @asm.emit(0x9E660000 | (freg(v) << 5) | 1) : @asm.mov(1, reg(v, 1)) # fmov x1, d
          @asm.bl(:__anew); @asm.mov(d, 0)
        when :aget # out of range (incl. negative, via unsigned compare) -> nil (0)
          a, ix = i.args; ra = reg(a); ri = reg(ix, 9)
          @asm.ldur(16, ra, -8); @asm.cmp(ri, 16)      # x16: len (x8/x9 may hold ra/ri)
          skip = @asm.uniq
          if i.float? then @asm.fmov_imm(d, 0.0); @asm.bhs(skip); @asm.fldr_idx(d, ra, ri)
          else @asm.mov_imm(d, 0); @asm.bhs(skip); @asm.ldr_idx(d, ra, ri) end
          @asm.label(skip)
        when :aset # in range: store; else slow path (fill / grow) which returns the handle
          a, ix, v = i.args
          @asm.mov(0, reg(a, 0)); @asm.mov(1, reg(ix, 1))
          v.float? ? @asm.emit(0x9E660000 | (freg(v) << 5) | 2) : @asm.mov(2, reg(v, 2)) # fmov x2, d
          @asm.ldur(TMP, 0, -8); @asm.cmp(1, TMP)
          slow = @asm.uniq; done = @asm.uniq
          @asm.bhs(slow); @asm.str_idx(2, 0, 1); @asm.b(done)
          @asm.label(slow); @asm.bl(:__aset_slow)
          @asm.label(done); @asm.mov(d, 0)
        when :cmp
          l, r = i.args
          if l.float? then @asm.fcmp(freg(l), freg(r, FTMP2))
          elsif imm?(r) then @asm.cmpi(reg(l), r.args[0])
          else @asm.cmp(reg(l), reg(r, 9)) end
          @asm.cset(d, i.cond) unless fused?(i)
        when :call
          f, *a = i.args
          xi = fi = 0
          a.each { |v| v.float? ? (@asm.fmov(fi, freg(v, fi)); fi += 1) : (@asm.mov(xi, reg(v, xi)); xi += 1) }
          @asm.bl(f.name)
          i.float? ? @asm.fmov(d, 0) : @asm.mov(d, 0)
        when :puts_i
          @asm.mov(0, reg(i.args[0], 0))
          @asm.bl(:__puts_i)
        when :puts_s
          s = i.args[0] + "\n"; name = :"str#{i.id}"
          @asm.data(name, s)
          @asm.adr(1, name); @asm.mov_imm(2, s.bytesize); @asm.mov_imm(0, 1)
          @asm.call_write
        when :condbr
          c, t, e = i.args
          phi_moves(b, t); phi_moves(b, e)
          nb = next_block(b)
          if c.op == :cmp && fused?(c)
            if nb == e then @asm.bcond(c.cond, lbl(t))
            else @asm.bcond(Asm::INV[c.cond], lbl(e)); @asm.b(lbl(t)) unless nb == t end
          else
            @asm.cbz(reg(c), lbl(e)); @asm.b(lbl(t)) unless nb == t
          end
        when :br
          phi_moves(b, i.args[0])
          @asm.b(lbl(i.args[0])) unless next_block(b) == i.args[0]
        when :ret
          v = i.args[0]
          if v.float? then @asm.fmov(0, freg(v, 0))
          elsif v.reg || v.slot || v.op == :const then @asm.mov(0, reg(v, 0))
          else @asm.mov_imm(0, 0) end # nil-valued (puts, while)
          @asm.b(:"#{@f.name}_ret") unless b == @f.blocks.last
        else raise "codegen: #{i.op}"
        end
        spill!(i)
      end
    end

    def lbl(b) = :"#{@f.name}_#{b.name}"
    def next_block(b) = @f.blocks[@f.blocks.index(b) + 1]

    # parallel copy for the phis of `to` along the edge from `from`.
    # locations: Integer register, [:slot, n], or a const Inst (source only)
    def loc(v) = v.reg ? (v.float? ? [:f, v.reg] : v.reg) : (v.slot ? [:slot, v.slot] : v)
    def move(d, s)
      if (d.is_a?(Array) && d[0] == :f) || (s.is_a?(Array) && s[0] == :f) || (s.is_a?(Inst) && s.float?) || (s.is_a?(Inst) && s.op == :fconst)
        sreg = case s
               when Array then s[0] == :f ? s[1] : (@asm.fldr(FTMP, @spill_base + 8 * s[1]); FTMP)
               when Inst then @asm.fmov_imm(FTMP, s.args[0]); FTMP
               else s
               end
        d.is_a?(Array) && d[0] == :f ? @asm.fmov(d[1], sreg) : @asm.fstr(sreg, @spill_base + 8 * d[1])
        return
      end
      sreg = case s
             when Integer then s
             when Inst then @asm.mov_imm(TMP, s.args[0]); TMP
             else @asm.ldr(TMP, @spill_base + 8 * s[1]); TMP
             end
      d.is_a?(Integer) ? @asm.mov(d, sreg) : @asm.str(sreg, @spill_base + 8 * d[1])
    end
    def phi_moves(from, to)
      moves = to.phis.filter_map { |p| v = p.args.find { _1[0] == from }&.last; v && [loc(p), loc(v)] }
      moves.reject! { |(d, s)| d == s }
      until moves.empty?
        ready = moves.find { |(d, _)| moves.none? { |(_, s2)| s2 == d } }
        if ready
          move(*ready); moves.delete(ready)
        else # cycle: park one source in x9 / d31
          _, s = moves.first
          park = (s.is_a?(Array) && s[0] == :f) ? [:f, FTMP2] : 9
          move(park, s); moves.map! { |(dd, ss)| [dd, ss == s ? park : ss] }
        end
      end
    end
  end
end
