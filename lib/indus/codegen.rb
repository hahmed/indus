# SSA -> arm64: layout, register allocation, instruction selection.
module Indus
  class Codegen
    TMP = 8; FTMP = 30; FTMP2 = 31 # scratch; pools live in RegAlloc

    def initialize(asm, classes = {}) = (@asm, @classes = asm, classes)

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
      f.params.each_with_index { |p, k| p.ty = f.ptypes[k] || :int }
      ra = RegAlloc.new(f).run
      used, fused, nslots = ra.used.dup, ra.fused.dup, ra.nslots

      used |= [Asm::HEAP, Asm::GBASE] if f.name == :main
      used.sort!; fused.sort!
      fsave = 16 + ((used.size + 1) / 2) * 16
      @spill_base = fsave + ((fused.size + 1) / 2) * 16
      # tier-0 objects live in the frame after the spill slots
      @stack_objs = {}; obj_base = @spill_base + ((nslots + 1) / 2) * 16
      f.all.each { |i| next unless i.op == :onew && i.stack; @stack_objs[i] = obj_base; obj_base += (([i.args[0].size, 8].max + 15) / 16) * 16 }
      frame = obj_base
      raise "frame too large (#{frame})" if frame > 4080
      @asm.label(f.name)
      @asm.sub_sp(frame); @asm.stp(29, 30, 0); @asm.mov_fp_sp
      used.each_slice(2).with_index { |(a, b), i| @asm.stp(a, b, 16 + i * 16) }
      fused.each_slice(2).with_index { |(a, b), i| @asm.fstp(a, b, fsave + i * 16) }
      if f.name == :main # heap base arrives in x0: globals in the first 4K, bump pointer after
        @asm.mov(Asm::GBASE, 0); @asm.addi(Asm::HEAP, 0, 4096)
        # [x27] = write(2): libc in-process, our syscall stub standalone
        @asm.write_addr ? @asm.mov_imm(16, @asm.write_addr) : @asm.adr(16, :__write)
        @asm.str_off(16, Asm::GBASE, 0)
        # patchable methods start out pointing at their static code
        @classes.each_value do |k|
          k.methods.each_value do |m|
            next unless m.patchable
            @asm.adr(16, m.name); @asm.str_off(16, Asm::GBASE, @asm.global(:"m_#{m.name}"))
          end
        end
      end
      # params: ints in x0.., floats in d0.. (separate counters, AAPCS64)
      xi = fi = 0
      f.params.each { |p| p.float? ? (@asm.fmov(p.reg, fi); fi += 1) : (@asm.mov(p.reg, xi); xi += 1) }
      f.blocks.each { block(_1) }
      @asm.label(:"#{f.name}_ret")
      @asm.str_off(Asm::HEAP, Asm::GBASE, @asm.global(:__heap_end)) if f.name == :main
      fused.each_slice(2).with_index { |(a, b), i| @asm.fldp(a, b, fsave + i * 16) }
      used.each_slice(2).with_index { |(a, b), i| @asm.ldp(a, b, 16 + i * 16) }
      @asm.ldp(29, 30, 0); @asm.add_sp(frame); @asm.ret
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
        when :libm, :fpow # in-process: call libm by absolute address (d0[, d1] -> d0)
          @asm.libm or raise "Math.#{i.op == :fpow ? 'pow' : i.args[0]} needs libm; not available in a standalone binary yet"
          name, *fa = i.op == :fpow ? [:pow, *i.args] : i.args
          fa.each_with_index { |v, n| @asm.fmov(n, freg(v, n)) }
          @asm.mov_imm(16, @asm.libm.fetch(name)); @asm.blr(16); @asm.fmov(d, 0)
        when :seq_char # s[i] == "c" without allocating: bounds check, byte load, compare
          s_, ix, byte = i.args
          rs = reg(s_); ri = reg(ix, 9)
          @asm.ldur(16, rs, -8); @asm.cmp(ri, 16)
          no = @asm.uniq; dn = @asm.uniq
          @asm.bhs(no)
          @asm.ldrb_idx(16, rs, ri); @asm.cmpi(16, byte); @asm.cset(d, :eq); @asm.b(dn)
          @asm.label(no); @asm.mov_imm(d, 0); @asm.label(dn)
        when :alen then @asm.ldur(d, reg(i.args[0]), -8)
        when :onew
          k = i.args[0]
          if i.stack # tier 0: in the frame, zeroed here, gone at ret
            off = @stack_objs.fetch(i)
            @asm.addi(d, 31, off)
            (k.size / 8).times { |w| @asm.str_off(31, d, w * 8) }
            (@asm.mov_imm(TMP, k.id); @asm.str_off(TMP, d, 0)) if k.tagged
          else
            @asm.mov_imm(0, [k.size, 8].max); @asm.bl(:__onew)
            (@asm.mov_imm(TMP, k.id); @asm.str_off(TMP, 0, 0)) if k.tagged # class id in word 0
            @asm.mov(d, 0)
          end
        when :nop then @asm.mov(d, reg(i.args[0]))
        when :hsave then @asm.mov(d, Asm::HEAP)        # tier 1: remember the bump pointer
        when :hrestore then @asm.mov(Asm::HEAP, reg(i.args[0])) # ...and drop the iteration's garbage
        when :mod # Ruby modulo: floor division remainder
          l, r = i.args
          @asm.sdiv_floor(16, reg(l), reg(r, 9)); @asm.emit(0x9B008000 | (reg(r, 9) << 16) | (reg(l) << 10) | (16 << 5) | d) # msub d, x16, r, l
        when :sendsw # send(name): compare the symbol id against each candidate, direct call
          arms, name_v, recv, *args = i.args
          rn = reg(name_v)
          done = @asm.uniq
          arms.each do |sid, kind, payload|
            nxt = @asm.uniq
            @asm.cmpi(rn, sid); @asm.bcond(:ne, nxt)
            case kind
            when :call
              xi = fi = 0
              [recv, *args].each { |v| v.float? ? (@asm.fmov(fi, freg(v, fi)); fi += 1) : (@asm.mov(xi, reg(v, xi)); xi += 1) }
              @asm.bl(payload.name); i.float? ? @asm.fmov(d, 0) : @asm.mov(d, 0)
            when :fld_get
              off = @classes[recv.ty].base + payload * 8
              i.float? ? @asm.fldr_off(d, reg(recv), off) : @asm.ldr_off(d, reg(recv), off)
            when :fld_set
              off = @classes[recv.ty].base + payload * 8; v = args[0]
              v.float? ? @asm.fstr_off(freg(v), reg(recv), off) : @asm.str_off(reg(v, 9), reg(recv), off)
            end
            @asm.b(done); @asm.label(nxt)
          end
          @asm.emit(0xD4200000) # brk #0: no such method
          @asm.label(done)
        when :pcall # dispatch on the class id in word 0; one arm per class, each a direct call or a field access
          arms, recv, *args = i.args
          rr = reg(recv); @asm.ldr_off(16, rr, 0)
          done = @asm.uniq
          arms.each do |klass, kind, payload|
            nxt = @asm.uniq
            @asm.cmpi(16, klass.id); @asm.bcond(:ne, nxt)
            case kind
            when :call
              xi = fi = 0
              [recv, *args].each { |v| v.float? ? (@asm.fmov(fi, freg(v, fi)); fi += 1) : (@asm.mov(xi, reg(v, xi)); xi += 1) }
              @asm.bl(payload.name); i.float? ? @asm.fmov(d, 0) : @asm.mov(d, 0)
              @asm.ldr_off(16, rr, 0) if false
            when :fld_get
              off = klass.base + payload * 8
              i.float? ? @asm.fldr_off(d, reg(recv), off) : @asm.ldr_off(d, reg(recv), off)
            when :fld_set
              off = klass.base + payload * 8; v = args[0]
              v.float? ? @asm.fstr_off(freg(v), reg(recv), off) : @asm.str_off(reg(v, 9), reg(recv), off)
            end
            @asm.b(done); @asm.label(nxt)
          end
          @asm.label(done)
        when :ipow
          @asm.mov(0, reg(i.args[0], 0)); @asm.mov(1, reg(i.args[1], 1)); @asm.bl(:__ipow); @asm.mov(d, 0)
        when :fld_get
          o, ix = i.args; off = @classes.fetch(o.ty) { raise "fld_get on #{o} (#{o.op}) typed #{o.ty.inspect} in #{@f.name}" }.base + ix * 8
          i.float? ? @asm.fldr_off(d, reg(o), off) : @asm.ldr_off(d, reg(o), off)
        when :fld_set
          o, ix, v = i.args; ro = reg(o); off = @classes[o.ty].base + ix * 8
          v.float? ? @asm.fstr_off(freg(v), ro, off) : @asm.str_off(reg(v, 9), ro, off)
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
          else
            i.ty == :int? ? @asm.emit(0xD2F00000 | d) : @asm.mov_imm(d, 0) # nil: sentinel for ints, null for pointers
            @asm.bhs(skip); @asm.ldr_idx(d, ra, ri)
          end
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
          if f.patchable # through the method's slot: redefinition rewrites one word
            @asm.ldr_off(16, Asm::GBASE, @asm.global(:"m_#{f.name}")); @asm.blr(16)
          else
            @asm.bl(f.name)
          end
          i.float? ? @asm.fmov(d, 0) : @asm.mov(d, 0)
        when :seam # call the resident compiler with the seam id; it patches the slots
          @asm.seams << i.args
          @asm.mov_imm(0, @asm.seams.size - 1)
          @asm.ldr_off(16, Asm::GBASE, @asm.global(:__seam_cb)); @asm.blr(16)
        when :puts_i
          @asm.mov(0, reg(i.args[0], 0))
          @asm.bl(:__puts_i)
        when :sconst # a literal evaluates to a fresh mutable copy (as in Ruby)
          name = :"str#{i.id}"; @asm.str_data(name, i.args[0])
          @asm.adr(0, name); @asm.mov_imm(1, i.args[0].bytesize); @asm.bl(:rt_str_new); @asm.mov(d, 0)
        when :scat then @asm.mov(0, reg(i.args[0], 0)); @asm.mov(1, reg(i.args[1], 1)); @asm.bl(:rt_str_cat); @asm.mov(d, 0)
        when :sappend then @asm.mov(0, reg(i.args[0], 0)); @asm.mov(1, reg(i.args[1], 1)); @asm.bl(:rt_str_append); @asm.mov(d, 0)
        when :seq then @asm.mov(0, reg(i.args[0], 0)); @asm.mov(1, reg(i.args[1], 1)); @asm.bl(:rt_str_eq); @asm.mov(d, 0)
        when :itos then @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:rt_itos); @asm.mov(d, 0)
        when :puts_str then @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:rt_puts_str)
        when :hnew then @asm.mov_imm(0, 8); @asm.bl(:rt_hash_new); @asm.mov(d, 0)
        when :hget, :hkey, :hset
          kt = i.args[0].ty&.[](1) or raise "hash #{i.args[0]} has no key type in #{@f.name}"
          kind = kt == :str ? "s" : "i"
          i.args[1..].each_with_index { |v, n| @asm.mov(n + 1, reg(v, n + 1)) }
          @asm.mov(0, reg(i.args[0], 0))
          op = i.op.to_s.sub("h", ""); op = "geti" if i.op == :hget && i.ty == :int? # int values: miss -> sentinel
          @asm.bl(:"rt_hash#{kind}_#{op}"); @asm.mov(d, 0)
        when :puts_nil then @asm.str_data(:__nl, ""); @asm.adr(0, :__nl); @asm.bl(:rt_puts_str)
        when :puts_opt # nullable int: blank line for nil
          @asm.str_data(:__nl, "")
          nl = @asm.uniq; dn = @asm.uniq
          r = reg(i.args[0]); @asm.emit(0xD2F00000 | 16); @asm.cmp(r, 16); @asm.bcond(:eq, nl)
          @asm.mov(0, r); @asm.bl(:__puts_i); @asm.b(dn)
          @asm.label(nl); @asm.adr(0, :__nl); @asm.bl(:rt_puts_str); @asm.label(dn)
        when :hkeys then @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:rt_hash_keys); @asm.mov(d, 0)
        when :ssub
          @asm.mov(1, reg(i.args[1], 1)); @asm.mov(2, reg(i.args[2], 2)); @asm.mov(0, reg(i.args[0], 0))
          @asm.bl(:rt_str_sub); @asm.mov(d, 0)
        when :puts_bool
          @asm.str_data(:__true, "true"); @asm.str_data(:__false, "false")
          f_ = @asm.uniq; dn = @asm.uniq
          @asm.cbz(reg(i.args[0]), f_); @asm.adr(0, :__true); @asm.b(dn); @asm.label(f_); @asm.adr(0, :__false); @asm.label(dn)
          @asm.bl(:rt_puts_str)
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
             when Inst then raise "phi source #{s} (#{s.op}, ty #{s.ty.inspect}) has no location in #{@f.name}" unless s.op == :const; @asm.mov_imm(TMP, s.args[0]); TMP
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
