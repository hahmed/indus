# SSA -> arm64: layout, register allocation, instruction selection.
module Indus
  class Codegen
    TMP = 8; FTMP = 30; FTMP2 = 31 # scratch; pools live in RegAlloc
    # ops that may bump the heap: a collection may run just before them
    ALLOCATING = %i[anew aset onew hnew hset hkeys sconst scat sappend ssub itos call pcall sendsw].freeze

    def initialize(asm, classes = {}) = (@asm, @classes = asm, classes)

    def layout(f)
      order, seen, work = [], {}, [f.entry]
      until work.empty?
        b = work.shift
        next if seen[b]
        seen[b] = true; order << b
        sc = b.succs
        if b.term.op == :condbr
          t, e, *handlers = sc # a try_push in this block adds its handler after the branch targets
          sc = (e.cold ? [t, e] : [e, t]) + handlers # fall into the loop body; else-first otherwise
        end
        work = sc + work
      end
      f.blocks = order
    end

    def func(f)
      @f = f
      layout(f)
      f.count_uses!
      f.params.each_with_index { |p, k| p.ty = f.ptypes[k] || :int }
      ra = RegAlloc.new(f).run
      used, fused, nslots = ra.used.dup, ra.fused.dup, ra.nslots
      @safepoint_live = ra.safepoint_live

      used |= [Asm::HEAP, Asm::GBASE] if f.name == :main
      used.sort!; fused.sort!
      fsave = 16 + ((used.size + 1) / 2) * 16
      @spill_base = fsave + ((fused.size + 1) / 2) * 16
      # tier-0 objects live in the frame after the spill slots
      @stack_objs = {}; obj_base = @spill_base + ((nslots + 1) / 2) * 16
      f.all.each { |i| next unless i.op == :onew && i.stack; @stack_objs[i] = obj_base; obj_base += (([i.args[0].size, 8].max + 15) / 16) * 16 }
      # handler records (begin/rescue): [link, sp, fp, x19..x26, resume] = 12 words, 16-aligned
      @try_recs = {}
      f.all.each { |i| next unless i.op == :try_push; @try_recs[i] = obj_base; obj_base += 96 }
      frame = obj_base
      raise "frame too large (#{frame})" if frame > 4080
      @asm.label(f.name)
      @asm.sub_sp(frame); @asm.stp(29, 30, 0); @asm.mov_fp_sp
      if GC.enabled? # pointer slots are roots: zero them, and describe this frame
        ptr_slots = (f.params + f.all).select { |i| i.slot && GC.pointer?(i.ty) }.map { |i| [slot_off(i), @asm.gc_table.tid(i.ty)] }
        ptr_slots += (f.params + f.all).select { |i| i.home && GC.pointer?(i.ty) }.map { |i| [@spill_base + 8 * i.home, @asm.gc_table.tid(i.ty)] }
        ptr_slots.each { |(off, _)| @asm.str(31, off) }
        @asm.gc_frames << [f.name, :"#{f.name}_ret", ptr_slots]
      end
      used.each_slice(2).with_index { |(a, b), i| @asm.stp(a, b, 16 + i * 16) }
      fused.each_slice(2).with_index { |(a, b), i| @asm.fstp(a, b, fsave + i * 16) }
      if f.name == :main # heap base arrives in x0: globals in the first 4K, bump pointer after
        @asm.mov(Asm::GBASE, 0); @asm.addi(Asm::HEAP, 0, 4096)
        # [x27] = write(2): libc in-process, our syscall stub standalone
        @asm.write_addr ? @asm.mov_imm(16, @asm.write_addr) : @asm.adr(16, :__write)
        @asm.str_off(16, Asm::GBASE, 0)
        @asm.adr(16, :__mmap_fn_entry); @asm.str_off(16, Asm::GBASE, @asm.global(:__mmap_fn))
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
      f.params.each do |p|
        if p.float? then p.reg ? @asm.fmov(p.reg, fi) : @asm.fstr(fi, slot_off(p)); fi += 1
        else p.reg ? @asm.mov(p.reg, xi) : @asm.str(xi, slot_off(p)); xi += 1 end
      end
      f.blocks.each { block(_1) }
      @asm.label(:"#{f.name}_ret")
      @asm.str_off(Asm::HEAP, Asm::GBASE, @asm.global(:__heap_end)) if f.name == :main
      fused.each_slice(2).with_index { |(a, b), i| @asm.fldp(a, b, fsave + i * 16) }
      used.each_slice(2).with_index { |(a, b), i| @asm.ldp(a, b, 16 + i * 16) }
      @asm.ldp(29, 30, 0); @asm.add_sp(frame); @asm.ret
    end

    def fused?(c)
      nxt = c.block.insts[c.block.insts.index(c) + 1]
      nxt&.op == :condbr && nxt.args[0] == c && c.uses == 1 # a compare used elsewhere must be materialized
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

    # the file primitives as raw syscalls (a standalone binary has no libc). Linux has only the
    # *at forms of open/unlink: AT_FDCWD (-100) in x0, the arguments shift up one; creat is
    # openat with O_WRONLY|O_CREAT|O_TRUNC (0o1101).
    def raw_syscall(name, a)
      os = @asm.os or raise "#{name}: no libc in-process and no target OS"
      raise "#{name}: darwin syscalls report errors in the carry flag, not the result; standalone file I/O is linux only" if os == :darwin
      nums = Asm::SYSCALLS[os]
      case [os, name]
      when [:linux, :open]   then @asm.mov(1, reg(a[0], 1)); @asm.mov(2, reg(a[1], 2)); @asm.mov_imm(0, -100); @asm.mov_imm(8, nums[:open])
      when [:linux, :creat]  then @asm.mov(1, reg(a[0], 1)); @asm.mov(3, reg(a[1], 3)); @asm.mov_imm(0, -100); @asm.mov_imm(2, 0o1101); @asm.mov_imm(8, nums[:open])
      when [:linux, :unlink] then @asm.mov(1, reg(a[0], 1)); @asm.mov_imm(0, -100); @asm.mov_imm(2, 0); @asm.mov_imm(8, nums[:unlink])
      when [:darwin, :creat] then @asm.mov(0, reg(a[0], 0)); @asm.mov(2, reg(a[1], 2)); @asm.mov_imm(1, 0o1101); @asm.mov_imm(16, nums[:open])
      else
        a.each_with_index { |v, k| @asm.mov(k, reg(v, k)) }
        n = nums[name] or raise "#{name}: no syscall on #{os}"
        os == :linux ? @asm.mov_imm(8, n) : @asm.mov_imm(16, n)
      end
      @asm.emit(os == :linux ? 0xD4000001 : 0xD4001001) # svc #0 / svc #0x80
    end
    def spill!(i)
      return unless i.slot
      i.float? ? @asm.fstr(FTMP, slot_off(i)) : @asm.str(SPILL, slot_off(i))
    end

    def block(b)
      @asm.label(lbl(b))
      if GC.enabled? && (push = @f.all.find { _1.op == :try_push && _1.args[0] == b })
        # a handler: the exception is in x0 (first instruction is exc_value); live pointers reload from homes
        d0 = dst(b.insts[0]); @asm.mov(d0, 0) if b.insts[0]&.op == :exc_value
        handler_entry(push)
      end
      b.insts.each do |i|
        d = dst(i)
        calls_before = @asm.ncalls || 0
        sp = GC.enabled? && GC.needs_safepoint?(i) && i.op != :aset && !@f.name.to_s.start_with?("__gc") # aset: on its grow path
        safepoint(i) if sp
        case i.op
        when :const, :fconst then nil
        when :add, :sub, :mul, :div
          l, r = i.args
          if i.float?
            @asm.send({ add: :fadd, sub: :fsub, mul: :fmul, div: :fdiv }[i.op], d, freg(l), freg(r, FTMP2))
          elsif i.op == :div && r.op == :const && r.args[0] >= 2 then @asm.divmod_const(d, reg(l), r.args[0], :div, !!i.nonneg)
          elsif i.op == :div then @asm.sdiv_floor(d, reg(l), reg(r, 9))
          elsif i.op == :mul then (Asm::CHECKED && !i.nocheck) ? @asm.muls(d, reg(l), reg(r, 9)) : @asm.mul(d, reg(l), reg(r, 9))
          elsif imm?(r) then @asm.send((Asm::CHECKED && !i.nocheck) ? (i.op == :add ? :addsi : :subsi) : (i.op == :add ? :addi : :subi), d, reg(l), r.args[0])
          else @asm.send((Asm::CHECKED && !i.nocheck) ? (i.op == :add ? :adds : :subs) : i.op, d, reg(l), reg(r, 9)) end
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
        when :apop # len -= 1; d = a[len]  (traps on empty)
          r = reg(i.args[0]); ok = @asm.uniq
          @asm.ldur(16, r, -8); @asm.cbnz(16, ok); @asm.emit(0xD4200000); @asm.label(ok) # pop of [] traps
          @asm.subi(16, 16, 1); @asm.stur(16, r, -8)
          i.float? ? @asm.emit(0xFC607800 | (16 << 16) | (r << 5) | d) : @asm.emit(0xF8607800 | (16 << 16) | (r << 5) | d) # ldr d, [r, x16, lsl #3]
        when :hcap then @asm.ldur(d, reg(i.args[0]), -8) # iteration bound: the count (entries come from the order list)
        when :hkey_at, :hval_at # the i-th inserted entry: slot = order[i]; entry = h + slot*16
          ri = reg(i.args[1], 9); rh = reg(i.args[0])
          @asm.ldur(16, rh, -16)
          @asm.emit(0x8B000000 | (16 << 16) | (4 << 10) | (rh << 5) | 16)   # add x16, h, cap, lsl #4  (order list)
          @asm.emit(0xF8607800 | (ri << 16) | (16 << 5) | 16)               # ldr x16, [x16, i, lsl #3]
          @asm.emit(0x8B000000 | (16 << 16) | (4 << 10) | (rh << 5) | 16)   # add x16, h, slot, lsl #4
          off = i.op == :hkey_at ? 0 : 8
          i.float? ? @asm.fldr_off(d, 16, off) : @asm.ldr_off(d, 16, off)
        when :chr then @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:rt_chr); @asm.mov(d, 0)
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
        when :mkbuf # a one-word cell holding the current string handle
          @asm.emit(0xF81F0FE0 | reg(i.args[0], 9)) # str v, [sp, #-16]!  (survives the allocation call)
          @asm.mov_imm(0, 8); @asm.bl(:__onew)
          @asm.emit(0xF84107F0); @asm.str_off(16, 0, 0) # ldr x16, [sp], #16 ; str x16, [x0]
          @asm.mov(d, 0)
        when :bufderef then @asm.ldr_off(d, reg(i.args[0]), 0)
        when :cell_new # a shared local: one word on the heap holding the current value
          v = i.args[0]
          if v.float? then @asm.emit(0xFC1F0FE0 | freg(v, 16)) else @asm.emit(0xF81F0FE0 | reg(v, 9)) end # push the value (survives the allocation call)
          @asm.mov_imm(0, 8); @asm.bl(:__onew)
          @asm.emit(0xF84107F0); @asm.str_off(16, 0, 0) # pop into x16; store
          @asm.mov(d, 0)
        when :cell_get then i.float? ? @asm.fldr_off(d, reg(i.args[0]), 0) : @asm.ldr_off(d, reg(i.args[0]), 0)
        when :cell_set
          c, v = i.args
          v.float? ? @asm.fstr_off(freg(v), reg(c), 0) : @asm.str_off(reg(v, 9), reg(c), 0)
        when :bufappend # *cell = rt_str_append(*cell, v); result is the cell
          rb = reg(i.args[0], 9); @asm.mov(1, reg(i.args[1], 1)) # operands first: spill slots are sp-relative
          @asm.emit(0xF81F0FE0 | rb); @asm.ldr_off(0, rb, 0)
          @asm.bl(:rt_str_append)
          @asm.emit(0xF84107F0); @asm.str_off(0, 16, 0); @asm.mov(d, 16)
        when :nop then @asm.mov(d, reg(i.args[0]))
        when :rawld then @asm.ldr_off(d, reg(i.args[0]), 0)
        when :rawld8 then @asm.emit(0x38606800 | (reg(i.args[1], 9) << 16) | (reg(i.args[0]) << 5) | d)   # ldrb wd, [s, i]
        when :rawst8 then @asm.emit(0x38206800 | (reg(i.args[1], 9) << 16) | (reg(i.args[0]) << 5) | reg(i.args[2], 10)) # strb
        when :salloc then @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:rt_str_alloc); @asm.mov(d, 0)
        when :sdup then @asm.mov(0, reg(i.args[0], 0)); @asm.ldur(1, 0, -8); @asm.bl(:rt_str_new); @asm.mov(d, 0)
        when :rawld32 then @asm.emit(0xB9400000 | (reg(i.args[0]) << 5) | d)      # ldr wd, [xn]
        when :rawst then @asm.str_off(reg(i.args[1], 9), reg(i.args[0]), 0)
        when :gbase then @asm.mov(d, Asm::GBASE)
        when :trap then @asm.emit(0xD4200000) # brk #0: heap exhausted
        when :zcheck # divisor nonzero, or raise (the raiser never returns here)
          ok = @asm.uniq
          @asm.cbnz(reg(i.args[1]), ok); @asm.bl(i.args[0].name); @asm.label(ok)
        when :handle then @asm.mov(d, reg(i.args[0]))
        when :class_id then @asm.ldr_off(d, reg(i.args[0]), 0) # word 0 of an object: its class id
        when :isa_tag then @asm.ldr_off(16, reg(i.args[0]), 0); @asm.cmpi(16, i.args[1]); @asm.cset(d, :eq)
        when :isa_tags # class id in word 0 is one of several (a rescue matching a class and its descendants)
          @asm.ldr_off(16, reg(i.args[0]), 0); @asm.mov_imm(d, 0); yes = @asm.uniq
          i.args[1].each { |id| @asm.cmpi(16, id); @asm.bcond(:eq, yes) }
          @asm.b(dn = @asm.uniq); @asm.label(yes); @asm.mov_imm(d, 1); @asm.label(dn)
        when :try_push # install a handler record in this frame; the handler block reloads live pointers from their homes
          off = @try_recs.fetch(i); hb = i.args[0]
          @asm.ldr_off(16, Asm::GBASE, @asm.global(:__try_top)); @asm.str(16, off)       # link
          @asm.emit(0x910003F0); @asm.str(16, off + 8); @asm.str(29, off + 16)             # mov x16, sp ; sp, fp
          (19..26).each_with_index { |r, k| @asm.str(r, off + 24 + 8 * k) }
          @asm.adr(16, lbl(hb)); @asm.str(16, off + 88)                                    # resume address
          @asm.addi(16, 31, off); @asm.str_off(16, Asm::GBASE, @asm.global(:__try_top))  # top = this record
        when :try_pop
          off = @try_recs.fetch(i.args[0])
          @asm.ldr(16, off); @asm.str_off(16, Asm::GBASE, @asm.global(:__try_top))
        when :raise then @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:rt_raise)
        when :exc_value then @asm.mov(d, 0) unless GC.enabled? # rt_raise lands here with the exception in x0 (GC mode: block entry did it, before the reloads)
        when :box # tag a typed value: see notes/29_tagged_scalars_design.md
          v, t = i.args; r = v.float? ? nil : reg(v)
          case t
          when :int, :int? then @asm.emit(0xD37FF800 | (r << 5) | d) ; @asm.emit(0xB2400000 | (d << 5) | d) # lsl d, r, #1 ; orr d, d, #1
          when :str then @asm.emit(0xB27F0000 | (r << 5) | d)                            # orr d, r, #2
          when :bool then @asm.emit(0xD37CEC00 | (r << 5) | d); @asm.emit(0xB27D0000 | (d << 5) | d); @asm.emit(0xB27F0000 | (d << 5) | d) # (<<4) |8 |2 = 10
          when :sym then @asm.emit(0xD37CEC00 | (r << 5) | d); @asm.emit(0xB27E0400 | (d << 5) | d) # (<<4) |12
          when :nil then @asm.mov_imm(d, 0)
          when :float # box: 16 bytes, bits in word 0
            @asm.emit(0x9E660000 | (freg(v) << 5) | 16); @asm.emit(0xF81F0FF0) # fmov x16, dv ; str x16, [sp, #-16]!
            @asm.addi(0, 31, 0); @asm.mov_imm(1, 8); @asm.bl(:rt_str_new)     # an 8-byte leaf object (STR descriptor)
            @asm.emit(0x910043FF)                                              # add sp, sp, #16
            @asm.emit(0xB27F0800 | (0 << 5) | d)                               # orr d, x0, #14
          else
            if t.is_a?(Array) && t[0] == :arr then @asm.emit(0xB27E0000 | (r << 5) | d)      # orr d, r, #4
            elsif t.is_a?(Array) && t[0] == :hash then @asm.emit(0xB27F0400 | (r << 5) | d)   # orr d, r, #6
            else @asm.emit(0xB27D0000 | (r << 5) | d) end                                   # object: orr d, r, #8
          end
        when :unbox
          v, t = i.args; r = reg(v)
          case t
          when :int, :int? then @asm.emit(0x9341FC00 | (r << 5) | d)            # asr d, r, #1
          when :bool, :sym then @asm.emit(0x9344FC00 | (r << 5) | d)            # asr d, r, #4
          when :float then @asm.emit(0x927CEC00 | (r << 5) | 16); @asm.fldr_off(d, 16, 0) # and x16, r, #~15 ; ldr d, [x16]
          else @asm.emit(0x927CEC00 | (r << 5) | d)                             # and d, r, #~15 (handles are 16-aligned)
          end
        when :dyn_tag then @asm.emit(0x92400C00 | (reg(i.args[0]) << 5) | d)  # and d, r, #15
        when :isa_dyn
          v, cname = i.args; r = reg(v)
          case cname
          when :Integer then @asm.emit(0x92400000 | (r << 5) | 16); @asm.cmpi(16, 1); @asm.cset(d, :eq)        # bit 0
          when :NilClass then @asm.cmpi(r, 0); @asm.cset(d, :eq)
          else
            tag = { String: 2, Array: 4, Hash: 6, Float: 14, TrueClass: 10, FalseClass: 10, Symbol: 12 }[cname]
            if tag
              @asm.emit(0x92400C00 | (r << 5) | 16); @asm.cmpi(16, tag); @asm.cset(d, :eq)
            else # a user class: tag 8 and class id in word 0
              k = @classes.fetch(cname); no = @asm.uniq; dn = @asm.uniq
              @asm.emit(0x92400C00 | (r << 5) | 16); @asm.cmpi(16, 8); @asm.bcond(:ne, no)
              @asm.emit(0x927CEC00 | (r << 5) | 16); @asm.ldr_off(16, 16, 0); @asm.cmpi(16, k.id); @asm.cset(d, :eq); @asm.b(dn)
              @asm.label(no); @asm.mov_imm(d, 0); @asm.label(dn)
            end
          end
        when :ucmp then @asm.cmp(reg(i.args[0]), reg(i.args[1], 9)); @asm.cset(d, i.cond)
        when :fbits then @asm.emit(0x9E660000 | (freg(i.args[0]) << 5) | d)                       # fmov d, dn
        when :ffrom then @asm.emit(0x9E670000 | (reg(i.args[0]) << 5) | d)                        # fmov dn, x: the bits as a float
        when :lsr then @asm.emit(0x9AC02400 | (reg(i.args[1], 9) << 16) | (reg(i.args[0]) << 5) | d) # lsrv
        when :clz then @asm.emit(0xDAC01000 | (reg(i.args[0]) << 5) | d)
        when :umulh then @asm.emit(0x9BC07C00 | (reg(i.args[1], 9) << 16) | (reg(i.args[0]) << 5) | d)
        when :wmul then @asm.mul(d, reg(i.args[0]), reg(i.args[1], 9))
        when :wadd then @asm.add(d, reg(i.args[0]), reg(i.args[1], 9))
        when :wsub then @asm.sub(d, reg(i.args[0]), reg(i.args[1], 9))
        when :rawmmap then @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:rt_mmap); @asm.mov(d, 0)
        when :adrlbl then @asm.adr(d, i.args[0])
        when :hsave then @asm.mov(d, Asm::HEAP)        # tier 1: remember the bump pointer
        when :gcepoch then @asm.ldr_off(d, Asm::GBASE, @asm.global(:__gc_count)) # ...and the collection count it is valid for
        when :hrestore # ...and drop the iteration's garbage
          if GC.enabled? # unless a collection ran since the save (semispaces swap, so a range test would be fooled)
            skip = @asm.uniq; r = reg(i.args[0]); e = reg(i.args[1], 9)
            @asm.ldr_off(16, Asm::GBASE, @asm.global(:__gc_count)); @asm.cmp(e, 16); @asm.bcond(:ne, skip)
            @asm.mov(Asm::HEAP, r)
            # frame maps are per function, so a dead slot may still hold a pointer into the memory
            # just handed back; the next allocation would turn it into an interior pointer. Clear
            # every pointer slot the body wrote.
            header = b.succs.find { |sb| sb != b }
            Escape.loop_body(@f, header, [b]).each_key do |bb|
              (bb.phis + bb.insts).each do |v|
                next unless GC.pointer?(v.ty)
                @asm.str(31, slot_off(v)) if v.slot
                @asm.str(31, @spill_base + 8 * v.home) if v.home
              end
            end
            @asm.label(skip)
          else
            @asm.mov(Asm::HEAP, reg(i.args[0]))
          end
        when :mod # Ruby modulo: floor division remainder
          l, r = i.args
          if r.op == :const && r.args[0] >= 2 then @asm.divmod_const(d, reg(l), r.args[0], :mod, !!i.nonneg)
          else @asm.sdiv_floor(16, reg(l), reg(r, 9)); @asm.emit(0x9B008000 | (reg(r, 9) << 16) | (reg(l) << 10) | (16 << 5) | d) end # msub d, x16, r, l
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
              [recv, *args].each_with_index do |v, n|
                if v.float? then @asm.fmov(fi, freg(v, fi)); fi += 1
                else (n == 0 && recv.ty == :dyn ? @asm.mov(xi, rr) : @asm.mov(xi, reg(v, xi))); xi += 1 end
              end
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
          rr = reg(recv)
          if recv.ty == :dyn # a tagged object: the handle is the word with the tag cleared
            @asm.emit(0x927CEC00 | (rr << 5) | 17) # and x17, rr, #~15
            rr = 17
          end
          @asm.ldr_off(16, rr, 0)
          done = @asm.uniq
          arms.each do |klass, kind, payload|
            nxt = @asm.uniq
            @asm.cmpi(16, klass.id); @asm.bcond(:ne, nxt)
            case kind
            when :call
              xi = fi = 0
              [recv, *args].each_with_index do |v, n|
                if v.float? then @asm.fmov(fi, freg(v, fi)); fi += 1
                else (n == 0 && recv.ty == :dyn ? @asm.mov(xi, rr) : @asm.mov(xi, reg(v, xi))); xi += 1 end
              end
              @asm.bl(payload.name); i.float? ? @asm.fmov(d, 0) : @asm.mov(d, 0)
              @asm.ldr_off(16, rr, 0) if false
            when :fld_get
              off = klass.base + payload * 8
              i.float? ? @asm.fldr_off(d, reg(recv), off) : @asm.ldr_off(d, reg(recv), off)
            when :fld_set
              off = klass.base + payload * 8; v = args[0]
              v.float? ? @asm.fstr_off(freg(v), reg(recv), off) : @asm.str_off(reg(v, 9), reg(recv), off)
            when :trap then @asm.emit(0xD4200000) # NoMethodError: this class has no such method
            end
            @asm.b(done); @asm.label(nxt)
          end
          @asm.label(done)
        when :ipow
          @asm.mov(0, reg(i.args[0], 0)); @asm.mov(1, reg(i.args[1], 1)); @asm.bl(:__ipow); @asm.mov(d, 0)
        when :fld_get
          o, ix = i.args; kt = o.ty.is_a?(Array) && o.ty[0] == :poly ? o.ty[1][0] : o.ty # a poly set shares the field layout
          off = @classes.fetch(kt) { raise "fld_get on #{o} (#{o.op}) typed #{o.ty.inspect} in #{@f.name}" }.base + ix * 8
          i.float? ? @asm.fldr_off(d, reg(o), off) : @asm.ldr_off(d, reg(o), off)
        when :fld_set
          o, ix, v = i.args; ro = reg(o); off = @classes[o.ty].base + ix * 8
          v.float? ? @asm.fstr_off(freg(v), ro, off) : @asm.str_off(reg(v, 9), ro, off)
        when :gget
          off = @asm.global(i.args[0])
          i.float? ? @asm.fldr_off(d, Asm::GBASE, off) : @asm.ldr_off(d, Asm::GBASE, off)
        when :gset
          name, v = i.args; off = @asm.global(name)
          @asm.gc_globals << [off, @asm.gc_table.tid(v.ty)] if GC.enabled? && GC.pointer?(v.ty) && @asm.gc_globals.none? { _1[0] == off }
          v.float? ? @asm.fstr_off(freg(v), Asm::GBASE, off) : @asm.str_off(reg(v, 9), Asm::GBASE, off)
        when :to_f then @asm.scvtf(d, reg(i.args[0]))
        when :to_i
          raise "to_i on #{i.args[0].ty.inspect}" unless i.args[0].float? || %i[int int?].include?(i.args[0].ty) || i.args[0].ty.nil?
          i.args[0].float? ? @asm.fcvtzs(d, freg(i.args[0])) : @asm.mov(d, reg(i.args[0]))
        when :stoi then @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:rt_str_to_i); @asm.mov(d, 0)
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
          a, ix = i.args
          @asm.fmov_imm(d, 0.0) if i.float?             # the nil default first: its mov_imm uses x8
          ra = reg(a); ri = reg(ix, 9)                  # ra may be x8 (a spill load), ri x9: work in x16/x17
          @asm.ldur(17, ra, -8)                         # x17: len (d is written last, so d == x17 is fine)
          @asm.mov(16, ri); ri = 16                     # a negative index counts from the end (Ruby)
          @asm.emit(0xB6F80050); @asm.emit(0x8B110210)   # tbz x16, #63, +8 ; add x16, x16, x17
          @asm.cmp(ri, 17)
          skip = @asm.uniq
          if i.float? then @asm.bhs(skip); @asm.fldr_idx(d, ra, ri)
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
          @asm.label(slow)
          if GC.enabled? && !@f.name.to_s.start_with?("__gc") # the store may grow the array: collect first if due
            safepoint(i); @asm.mov(0, reg(a, 0)); @asm.mov(1, reg(ix, 1)) # reload: a may have moved
            v.float? ? @asm.emit(0x9E660000 | (freg(v) << 5) | 2) : @asm.mov(2, reg(v, 2))
          end
          @asm.bl(:__aset_slow)
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
        when :sconst_ro # a literal only read: its handle in the data section (header at the label, bytes 16 past it)
          name = :"str#{i.id}"; @asm.str_data(name, i.args[0])
          @asm.adr(d, name) # the data label is the bytes; the header sits in the 16 bytes before it
        when :sconst # a literal evaluates to a fresh mutable copy (as in Ruby)
          name = :"str#{i.id}"; @asm.str_data(name, i.args[0])
          @asm.adr(0, name); @asm.mov_imm(1, i.args[0].bytesize); @asm.bl(:rt_str_new); @asm.mov(d, 0)
        when :scat then @asm.mov(0, reg(i.args[0], 0)); @asm.mov(1, reg(i.args[1], 1)); @asm.bl(:rt_str_cat); @asm.mov(d, 0)
        when :sappend then @asm.mov(0, reg(i.args[0], 0)); @asm.mov(1, reg(i.args[1], 1)); @asm.bl(:rt_str_append); @asm.mov(d, 0)
        when :seq then @asm.mov(0, reg(i.args[0], 0)); @asm.mov(1, reg(i.args[1], 1)); @asm.bl(:rt_str_eq); @asm.mov(d, 0)
        when :sne then @asm.mov(0, reg(i.args[0], 0)); @asm.mov(1, reg(i.args[1], 1)); @asm.bl(:rt_str_eq); @asm.emit(0xD2400000 | d) # eor d, x0, #1
        when :scmp # a <=> b, then the sign against the original condition
          @asm.mov(0, reg(i.args[0], 0)); @asm.mov(1, reg(i.args[1], 1)); @asm.bl(:rt_str_cmp)
          @asm.cmpi(0, 0); @asm.cset(d, i.cond)
        when :itos then @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:rt_itos); @asm.mov(d, 0)
        when :bool_to_s # "true" / "false" as fresh strings
          @asm.str_data(:__true, "true"); @asm.str_data(:__false, "false")
          f_ = @asm.uniq; dn = @asm.uniq
          @asm.cbz(reg(i.args[0]), f_); @asm.adr(0, :__true); @asm.mov_imm(1, 4); @asm.b(dn); @asm.label(f_); @asm.adr(0, :__false); @asm.mov_imm(1, 5); @asm.label(dn)
          @asm.bl(:rt_str_new); @asm.mov(d, 0)
        when :puts_str then @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:rt_puts_str)
        when :sys # a file primitive by name, integer args/result: libc in-process, the raw syscall standalone
          name, *a = i.args
          if (addr = @asm.libm&.[](name))
            a.each_with_index { |v, k| @asm.mov(k, reg(v, k)) }
            @asm.mov_imm(16, addr); @asm.blr(16); @asm.mov(d, 0)
          else
            raw_syscall(name, a); @asm.mov(d, 0)
          end
        when :eputs_str then @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:rt_eputs_str)
        when :clock # clock_gettime(CLOCK_MONOTONIC, &ts): libc in-process, the syscall standalone; seconds + nanos * 1e-9
          addr = @asm.libm&.[](:clock_gettime)
          raise "Process.clock_gettime: no clock_gettime syscall on darwin standalone" if !addr && @asm.os != :linux
          @asm.emit(0xD10043FF)                                  # sub sp, sp, #16
          @asm.mov_imm(0, RUBY_PLATFORM.include?("darwin") && addr ? 6 : 1); @asm.addi(1, 31, 0)
          if addr then @asm.mov_imm(16, addr); @asm.blr(16)
          else @asm.mov_imm(8, Asm::SYSCALLS[:linux][:clock_gettime]); @asm.emit(0xD4000001) end # svc #0
          @asm.emit(0xF94003E0); @asm.emit(0xF94007E1)          # ldr x0, [sp] ; ldr x1, [sp, #8]
          @asm.emit(0x910043FF)                                  # add sp, sp, #16
          @asm.scvtf(0, 0); @asm.scvtf(1, 1); @asm.fmov_imm(2, 1e-9)
          @asm.emit(0x1E620821)                                  # fmul d1, d1, d2
          @asm.emit(0x1E612800 | d)                              # fadd d, d0, d1
        when :hnew then @asm.mov_imm(0, 8); @asm.bl(:rt_hash_new); @asm.mov(d, 0)
        when :hget, :hkey, :hset
          kt = i.args[0].ty&.[](1) or raise "hash #{i.args[0]} has no key type in #{@f.name}"
          kind = kt == :str ? "s" : kt == :dyn ? "d" : "i" # strings by content, tagged keys by tag, the rest by word
          i.args[1..].each_with_index { |v, n| @asm.mov(n + 1, reg(v, n + 1)) }
          @asm.mov(0, reg(i.args[0], 0))
          op = i.op.to_s.sub("h", ""); op = "geti" if i.op == :hget && i.ty == :int? # int values: miss -> sentinel
          @asm.bl(:"rt_hash#{kind}_#{op}"); @asm.mov(d, 0)
        when :puts_nil then @asm.str_data(:__nl, ""); @asm.adr(0, :__nl); @asm.bl(:rt_puts_str)
        when :puts_nil_word then @asm.str_data(:__nilw, "nil"); @asm.adr(0, :__nilw); @asm.bl(:rt_puts_str)
        when :p_str then @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:rt_p_str)
        when :print_str then @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:rt_print_str)
        when :print_i then @asm.mov(0, reg(i.args[0], 0)); @asm.bl(:rt_print_i)
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
          s = i.args[0].end_with?("\n") ? i.args[0] : i.args[0] + "\n"; name = :"str#{i.id}" # puts adds no newline to one that has it
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
          elsif c.ty == :dyn # nil (0) and false (10) are the falsy words
            r = reg(c); @asm.cbz(r, lbl(e)); @asm.cmpi(r, 10); @asm.bcond(:eq, lbl(e)); @asm.b(lbl(t)) unless nb == t
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
        reload_homes(i) if sp && i.call? # a collection inside the callee moved what our registers point at
        # the allocator trusted Inst#call?; make sure codegen agreed
        emitted = (@asm.ncalls || 0) > calls_before
        raise "#{i.op} emits a call but is not Inst#call? (register allocation would be unsafe)" if emitted && !i.call?
      end
    end

    # live pointers go to their typed home slots around the collection check
    # entry to a handler block: a collection inside the try may have moved what the record's
    # registers point to; the frame homes are current, reload live pointers from them
    def handler_entry(push)
      (@safepoint_live[push] || []).each { |v| @asm.ldr(v.reg, @spill_base + 8 * v.home) if v.reg && v.home && GC.pointer?(v.ty) }
    end

    def safepoint(i)
      live = (@safepoint_live[i] || []).select { |v| v.reg && v.home } # spilled ones are already in slots
      live.each { |v| @asm.str(v.reg, @spill_base + 8 * v.home) }
      @asm.gc_safepoint
      reload_homes(i)
    end

    def reload_homes(i)
      (@safepoint_live[i] || []).each { |v| @asm.ldr(v.reg, @spill_base + 8 * v.home) if v.reg && v.home && v != i }
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
