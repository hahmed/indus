# arm64 encoder + the hand-written runtime routines (puts, putc, arrays, syscalls).
module Indus
  class Asm
    attr_reader :words
    attr_accessor :gc_table, :gc_frames, :gc_globals
    def initialize
      @words, @labels, @fixups, @data, @seams = [], {}, [], [], []
      @gc_frames, @gc_globals = [], []
      global(:__write_fn) # offset 0: the runtime blob calls write through [x27]
      # fixed global slots the collector uses (offsets 8..)
      %i[__gc_limit __gc_from __gc_from_end __gc_to __gc_to_end __gc_bitmap __gc_work __gc_count __gc_free __gc_wtop __mmap_fn __gc_extra __try_top].each { global(_1) }
      label(:__text_base)
    end

    # if the bump pointer passed the limit, collect before allocating
    def gc_safepoint
      ok = uniq
      ldr_off(16, GBASE, global(:__gc_limit))
      emit(0xEB10039F)                 # cmp x28, x16
      bcond(:lo, ok)
      bl(:rt_gc)
      label(ok)
    end

    # the collector's tables, as data: type descriptors, frame maps, global roots
    def emit_gc_tables
      t = gc_table.words
      frames = gc_frames.flat_map { |(start, stop, slots)| [[:lbl, start], [:lbl, stop], slots.size, *slots.flatten] }
      globals = gc_globals.flatten
      words = [t.size, *t, gc_frames.size, *frames, gc_globals.size, *globals]
      emit 0 while pos % 2 != 0
      label(:__gc_tables)
      words.each do |w|
        if w.is_a?(Array) then fix(w[1], :abs32); emit(0) # code offset of a label, in bytes
        else emit(w & 0xFFFFFFFF) end
      end
    end

    # the assembled runtime (lib/indus/runtime.s): drop it in, name its entry points
    def emit_runtime_blob
      base = pos
      RuntimeBlob::LABELS.each { |n, off| @labels[n] = base + off / 4 }
      RuntimeBlob::RELOCS.each { |idx, sym| @fixups << [base + idx, sym, :b26] }
      @words.concat(RuntimeBlob::WORDS)
      # without the collector compiled in, its entry is unreachable (no safepoints are emitted)
      (label(:__gc_run); emit(0xD4200000)) unless @labels[:__gc_run] || GC.enabled?
    end

    # a 64-bit literal in the data area, for pc-relative loads
    def literal(v)
      name = :"lit_#{v & 0xFFFFFFFFFFFFFFFF}"
      @data << [name, [v & 0xFFFFFFFFFFFFFFFF].pack("Q")] unless @data.any? { _1[0] == name }
      name
    end

    # a string literal: [cap][len][bytes] in the data area; label at the bytes
    def str_data(name, str)
      @data << [name, [str.bytesize, str.bytesize].pack("QQ") + str, 16] unless @data.any? { _1[0] == name }
    end
    def pos = @words.size
    def emit(w) = @words << (w & 0xFFFFFFFF)
    def label(n) = (@labels[n] = pos)
    def fix(n, k) = @fixups << [pos, n, k]

    def movz(rd, imm, sh = 0) = emit(0xD2800000 | (sh << 21) | ((imm & 0xFFFF) << 5) | rd)
    def movk(rd, imm, sh) = emit(0xF2800000 | (sh << 21) | ((imm & 0xFFFF) << 5) | rd)
    def movn(rd, imm) = emit(0x92800000 | ((imm & 0xFFFF) << 5) | rd)
    def mov_imm(rd, v)
      if v < 0 && v >= -0x10000 then movn(rd, ~v)
      elsif v == -(1 << 63) then emit(0xD2F00000 | rd) # movz rd, #0x8000, lsl #48
      else
        u = v & 0xFFFFFFFFFFFFFFFF
        movz(rd, u & 0xFFFF)
        movk(rd, (u >> 16) & 0xFFFF, 1) if u > 0xFFFF
        movk(rd, (u >> 32) & 0xFFFF, 2) if u > 0xFFFFFFFF
        movk(rd, (u >> 48) & 0xFFFF, 3) if u > 0xFFFFFFFFFFFF
      end
    end
    def mov(rd, rn) = (emit(0xAA0003E0 | (rn << 16) | rd) unless rd == rn)
    def add(rd, rn, rm) = emit(0x8B000000 | (rm << 16) | (rn << 5) | rd)
    def sub(rd, rn, rm) = emit(0xCB000000 | (rm << 16) | (rn << 5) | rd)
    def mul(rd, rn, rm) = emit(0x9B007C00 | (rm << 16) | (rn << 5) | rd)
    # checked integer arithmetic: Ruby integers never wrap (they become Bignums,
    # which Indus does not have), so an overflow traps instead of returning a
    # wrong number. INDUS_INT_WRAP=1 restores silent wrapping for measurement.
    CHECKED = !ENV["INDUS_INT_WRAP"]
    def adds(rd, rn, rm) = (emit(0xAB000000 | (rm << 16) | (rn << 5) | rd); bvs_trap)
    def subs(rd, rn, rm) = (emit(0xEB000000 | (rm << 16) | (rn << 5) | rd); bvs_trap)
    def addsi(rd, rn, i) = (emit(0xB1000000 | (i << 10) | (rn << 5) | rd); bvs_trap)
    def subsi(rd, rn, i) = (emit(0xF1000000 | (i << 10) | (rn << 5) | rd); bvs_trap)
    def muls(rd, rn, rm) # smulh must equal the sign extension of the low word
      emit(0x9B407C00 | (rm << 16) | (rn << 5) | 16)             # smulh x16, rn, rm
      mul(rd, rn, rm)
      emit(0xEB80FE1F | (rd << 16))                              # cmp x16, rd, asr #63
      bne_trap
    end
    def bvs_trap = (fix(:__overflow, :b19); emit(0x54000006))   # b.vs __overflow
    def bne_trap = (fix(:__overflow, :b19); emit(0x54000001))   # b.ne __overflow
    def emit_overflow_trap = (label(:__overflow); emit(0xD4200000)) # brk #0: integer overflow
    def and_(rd, rn, rm) = emit(0x8A000000 | (rm << 16) | (rn << 5) | rd)
    def orr(rd, rn, rm) = emit(0xAA000000 | (rm << 16) | (rn << 5) | rd)
    def eor(rd, rn, rm) = emit(0xCA000000 | (rm << 16) | (rn << 5) | rd)
    def lslv(rd, rn, rm) = emit(0x9AC02000 | (rm << 16) | (rn << 5) | rd)
    def asrv(rd, rn, rm) = emit(0x9AC02800 | (rm << 16) | (rn << 5) | rd)
    def ldr_idx(rt, rn, rm) = emit(0xF8607800 | (rm << 16) | (rn << 5) | rt)   # ldr rt,[rn, rm, lsl #3]
    def str_idx(rt, rn, rm) = emit(0xF8207800 | (rm << 16) | (rn << 5) | rt)   # str rt,[rn, rm, lsl #3]
    def ldur(rt, rn, off) = emit(0xF8400000 | ((off & 0x1FF) << 12) | (rn << 5) | rt) # ldr rt,[rn,#simm9]
    def stur(rt, rn, off) = emit(0xF8000000 | ((off & 0x1FF) << 12) | (rn << 5) | rt)
    def bhs(n) = (fix(n, :b19); emit(0x54000002))   # b.hs (unsigned >=): index out of range
    # floats (d registers)
    def fadd(rd, rn, rm) = emit(0x1E602800 | (rm << 16) | (rn << 5) | rd)
    def fsub(rd, rn, rm) = emit(0x1E603800 | (rm << 16) | (rn << 5) | rd)
    def fmul(rd, rn, rm) = emit(0x1E600800 | (rm << 16) | (rn << 5) | rd)
    def fdiv(rd, rn, rm) = emit(0x1E601800 | (rm << 16) | (rn << 5) | rd)
    def fcmp(rn, rm) = emit(0x1E602000 | (rm << 16) | (rn << 5))
    def scvtf(rd, rn) = emit(0x9E620000 | (rn << 5) | rd)      # d <- x
    def fcvtzs(rd, rn) = emit(0x9E780000 | (rn << 5) | rd)     # x <- d (truncate)
    def fmov_dx(rd, rn) = emit(0x9E670000 | (rn << 5) | rd)
    def fmov(rd, rn) = (emit(0x1E604000 | (rn << 5) | rd) unless rd == rn)
    def fldr_idx(rt, rn, rm) = emit(0xFC607800 | (rm << 16) | (rn << 5) | rt)
    def fstr_idx(rt, rn, rm) = emit(0xFC207800 | (rm << 16) | (rn << 5) | rt)
    def fstr(t, off) = emit(0xFD000000 | ((off / 8) << 10) | (31 << 5) | t)
    def fldr(t, off) = emit(0xFD400000 | ((off / 8) << 10) | (31 << 5) | t)
    def fstp(t1, t2, off) = t2 ? emit(0x6D000000 | ((off / 8) << 15) | (t2 << 10) | (31 << 5) | t1) : fstr(t1, off)
    def fldp(t1, t2, off) = t2 ? emit(0x6D400000 | ((off / 8) << 15) | (t2 << 10) | (31 << 5) | t1) : fldr(t1, off)
    def fmov_imm(rd, v) = (mov_imm(8, [v].pack("E").unpack1("Q")); fmov_dx(rd, 8))
    def fsqrt(rd, rn) = emit(0x1E61C000 | (rn << 5) | rd)
    # field access: unsigned scaled offsets
    def ldr_off(rt, rn, off) = emit(0xF9400000 | ((off / 8) << 10) | (rn << 5) | rt)
    def str_off(rt, rn, off) = emit(0xF9000000 | ((off / 8) << 10) | (rn << 5) | rt)
    def fldr_off(rt, rn, off) = emit(0xFD400000 | ((off / 8) << 10) | (rn << 5) | rt)
    def fstr_off(rt, rn, off) = emit(0xFD000000 | ((off / 8) << 10) | (rn << 5) | rt)
    def ldr_lit(rt, n) = (fix(n, :b19); emit(0x58000000 | rt))        # ldr xt, label (pc-relative data)
    def fldr_lit(rt, n) = (fix(n, :b19); emit(0x5C000000 | rt))       # ldr dt, label


    # division / modulo by a constant d >= 2 (Ruby floor semantics) without sdiv:
    # multiply-high by a magic number, shift, truncate, then the floor fix.
    # rd <- quotient (want == :div) or remainder (want == :mod). Scratch: x8, x9, x16, x17.
    def divmod_const(rd, rn, d, want)
      m, s = Magic.for(d)
      ldr_lit(16, literal(m))                                      # one load from the pool (rn may be x8: a materialized constant)
      emit(0x9B407C00 | (16 << 16) | (rn << 5) | 16)             # smulh x16, rn, x16
      emit(0x8B000000 | (rn << 16) | (16 << 5) | 16) if m < 0      # add x16, x16, rn
      emit(0x9340FC00 | (s << 16) | (16 << 5) | 16) if s > 0       # asr x16, x16, #s
      emit(0x8B40FC00 | (rn << 16) | (16 << 5) | 16)               # add x16, x16, rn, lsr #63   (toward zero)
      mov_imm(9, d)
      emit(0x9B008000 | (9 << 16) | (rn << 10) | (16 << 5) | 17)   # msub x17, x16, x9, rn      r = rn - q*d
      emit(0xF100023F)                                             # cmp x17, #0
      emit(0xFA401800 | (rn << 5))                                 # ccmp rn, #0, #0, ne        r != 0 && rn < 0 -> lt
      cset(8, :lt)                                                 # x8 = fix (0/1)
      if want == :div
        emit(0xCB080200 | rd)                                      # sub rd, x16, x8
      else
        emit(0x9B094500 | rd)                                      # madd rd, x8, x9, x17       r + fix*d
      end
    end

    # integer division, Ruby semantics (floor): q = a/b; if r != 0 && (r^b) < 0 then q -= 1
    def sdiv_floor(rd, rn, rm)
      emit(0x9AC00C00 | (rm << 16) | (rn << 5) | rd)                 # sdiv rd, rn, rm
      emit(0x9B008000 | (rm << 16) | (rn << 10) | (rd << 5) | 8)     # msub x8, rd, rm, rn   (r)
      emit(0xCA000000 | (rm << 16) | (8 << 5) | 9)                   # eor x9, x8, rm
      emit(0xF100011F)                                               # cmp x8, #0
      emit(0xFA401924)                                               # ccmp x9, #0, #4, ne
      cset(9, :lt)
      emit(0xCB090000 | (rd << 5) | rd)                              # sub rd, rd, x9
    end
    def uniq = (@u = (@u || 0) + 1; :"L#{@u}")

    HEAP = 28 # bump pointer, reserved; arrays: [cap][len][elems...], handle -> elems


    def addi(rd, rn, i)
      raise "addi immediate out of range: #{i}" unless (0..4095).cover?(i) || (i % 4096 == 0 && i <= 4095 * 4096)
      i < 4096 ? emit(0x91000000 | (i << 10) | (rn << 5) | rd) : emit(0x91400000 | ((i >> 12) << 10) | (rn << 5) | rd)
    end
    def subi(rd, rn, i) = emit(0xD1000000 | (i << 10) | (rn << 5) | rd)
    def cmp(rn, rm) = emit(0xEB00001F | (rm << 16) | (rn << 5))
    def cmpi(rn, i) = emit(0xF100001F | (i << 10) | (rn << 5))
    COND = { eq: 0x0, ne: 0x1, ge: 0xA, lt: 0xB, gt: 0xC, le: 0xD, mi: 0x4, pl: 0x5, ls: 0x9, hi: 0x8, lo: 0x3, hs: 0x2,
             # float compares: unordered must be false for < <= (mi/ls), true for != (ne)
             feq: 0x0, fne: 0x1, flt: 0x4, fle: 0x9, fgt: 0xC, fge: 0xA }
    INV = { eq: :ne, ne: :eq, ge: :lt, lt: :ge, gt: :le, le: :gt, mi: :pl, pl: :mi, ls: :hi, hi: :ls, lo: :hs, hs: :lo,
            feq: :fne, fne: :feq, flt: :pl, fle: :hi, fgt: :fle_u, fge: :flt_u }
    COND[:fle_u] = 0xD; COND[:flt_u] = 0xB # le / lt (true on unordered), the inverses of gt / ge
    def cset(rd, c) = emit(0x9A9F07E0 | (COND[INV[c]] << 12) | rd)
    def bcond(c, n) = (fix(n, :b19); emit(0x54000000 | COND[c]))
    def cbz(rt, n) = (fix(n, :b19); emit(0xB4000000 | rt))
    def cbnz(rt, n) = (fix(n, :b19); emit(0xB5000000 | rt))
    def b(n) = (fix(n, :b26); emit(0x14000000))
    # a later compilation unit calls back into the first through absolute addresses
    attr_accessor :externs # name -> absolute address
    attr_reader :ncalls # bl/blr emitted so far; codegen checks it against Inst#call?
    def bl(n)
      @ncalls = (@ncalls || 0) + 1
      if externs&.key?(n) then mov_imm(16, externs[n]); emit(0xD63F0000 | (16 << 5))
      else fix(n, :b26); emit(0x94000000) end
    end
    attr_reader :labels
    attr_accessor :seams # [[klass, src], ...] in id order
    def blr(rn) = (@ncalls = (@ncalls || 0) + 1; emit(0xD63F0000 | (rn << 5)))
    def ret = emit(0xD65F03C0)
    def adr(rd, n) = (fix(n, :adr); emit(0x10000000 | rd))
    def stp(t1, t2, off) = t2 ? emit(0xA9000000 | ((off / 8) << 15) | (t2 << 10) | (31 << 5) | t1) : str(t1, off)
    def ldp(t1, t2, off) = t2 ? emit(0xA9400000 | ((off / 8) << 15) | (t2 << 10) | (31 << 5) | t1) : ldr(t1, off)
    def str(t, off) = emit(0xF9000000 | ((off / 8) << 10) | (31 << 5) | t)
    def ldr(t, off) = emit(0xF9400000 | ((off / 8) << 10) | (31 << 5) | t)
    def stp_pre(t1, t2, sz) = emit(0xA9800000 | (((-sz / 8) & 0x7F) << 15) | (t2 << 10) | (31 << 5) | t1)
    def ldp_post(t1, t2, sz) = emit(0xA8C00000 | ((sz / 8) << 15) | (t2 << 10) | (31 << 5) | t1)
    def mov_fp_sp = emit(0x910003FD)
    def sub_sp(n) = emit(0xD10003FF | (n << 10))   # sub sp, sp, #n   (n < 4096, multiple of 16)
    def add_sp(n) = emit(0x910003FF | (n << 10))

    # data: bytes placed after the code, addressed with adr
    def data(name, bytes) = @data << [name, bytes]
    # globals: 8-byte slots at the start of the heap, addressed off x27
    GBASE = 27
    def global(name) = (@globals ||= {})[name] ||= @globals.size * 8
    def globals = (@globals ||= {})

    # --- the whole "runtime": puts for an Integer, via write(2) --------------
    # x0 = value. Builds decimal + "\n" in a 32-byte stack buffer, calls write.
    attr_accessor :write_addr # nil => bl __write (syscall stub)
    attr_accessor :libm       # name -> address, in-process only
    attr_accessor :mmap_addr  # libc mmap in-process; nil => syscall stub
    def ldrb_idx(rt, rn, rm) = emit(0x38606800 | (rm << 16) | (rn << 5) | rt) # ldrb wt, [xn, xm]
    def call_write = write_addr ? (mov_imm(16, write_addr); blr(16)) : bl(:__write)

    # raw syscalls for a standalone binary.
    #   darwin: number in x16, svc #0x80, write=4
    #   linux:  number in x8,  svc #0,    write=64 exit=93
    def emit_syscalls(os)
      label(:__write)
      case os
      when :darwin then emit 0xD2800090; emit 0xD4001001; ret      # mov x16,#4 ; svc #0x80
      when :linux  then emit 0xD2800808; emit 0xD4000001; ret      # mov x8,#64 ; svc #0
      end
      # mmap as a function (rt_mmap sets the arguments): in-process on darwin fix
      # the flags and jump to libc; standalone, the raw syscall
      if mmap_addr
        label(:__mmap_fn_entry); emit 0xD2820043; mov_imm(16, mmap_addr); emit 0xD61F0200 # mov x3,#0x1002 ; br x16
      else
        label(:__mmap_fn_entry)
        case os
        when :darwin then emit 0xD2820043; emit 0xD28018B0; emit 0xD4001001; ret # mov x3,#0x1002 ; mov x16,#197 ; svc
        when :linux  then emit 0xD2801BC8; emit 0xD4000001; ret                   # mov x8,#222 ; svc #0
        end
      end
    end

    # linux has no dyld to call main: _start calls main then exit(0)
    # linux mmap(NULL, size, RW, PRIVATE|ANON, -1, 0) -> x0
    def linux_mmap(size)
      emit 0xD2800000             # mov x0, #0
      mov_imm(1, size)
      emit 0xD2800062             # mov x2, #3
      emit 0xD2800443             # mov x3, #0x22
      emit 0x92800004             # mov x4, #-1
      emit 0xD2800005             # mov x5, #0
      emit 0xD2801BC8             # mov x8, #222
      emit 0xD4000001             # svc #0
    end

    def emit_start_linux
      label(:_start)
      if GC.enabled?
        semi = GC.semispace_bytes
        linux_mmap(semi + 4096); mov(19, 0)                     # heap: globals page + from-space
        linux_mmap(semi); mov(20, 0)                            # to-space
        linux_mmap(semi / 128 + 4096); mov(21, 0)               # forwarding bitmap
        linux_mmap(1 << 26); mov(22, 0)                         # worklist
        addi(23, 19, 4096); str_off(23, 19, global(:__gc_from))
        mov_imm(16, semi); add(24, 23, 16); str_off(24, 19, global(:__gc_from_end))
        mov_imm(16, 1 << 20); sub(25, 24, 16); str_off(25, 19, global(:__gc_limit))
        str_off(20, 19, global(:__gc_to))
        add(16, 20, 16); mov_imm(17, semi); add(16, 20, 17); str_off(16, 19, global(:__gc_to_end))
        str_off(21, 19, global(:__gc_bitmap))
        str_off(22, 19, global(:__gc_work))
        mov(0, 19)
      else
        linux_mmap(1 << 28); mov(19, 0)
        mov_imm(16, 1 << 28); add(16, 19, 16); str_off(16, 19, global(:__gc_from_end)) # rt_alloc's bound
        mov(0, 19)
      end
      bl(:main)
      emit 0xD2800000; emit 0xD2800BA8; emit 0xD4000001            # mov x0,#0 ; mov x8,#93 ; svc #0
    end

    def resolve!
      # place data after code, 8-aligned
      emit 0 while pos % 2 != 0
      @data.each do |name, bytes, label_off|
        emit 0 while pos % 4 != 0 if label_off # 16-byte align headers
        @labels[name] = pos + (label_off || 0) / 4
        padded = bytes + "\0" * ((4 - bytes.bytesize % 4) % 4)
        @words.concat(padded.unpack("V*"))
      end
      @fixups.each do |at, n, k|
        raise "fixup #{n} (#{k}) at word #{at} beyond code (#{@words.size})" if @words[at].nil?
        off = @labels.fetch(n) { raise "undefined #{n}" } - at
        @words[at] |= case k
                      when :b19 then (off & 0x7FFFF) << 5
                      when :b26 then off & 0x3FFFFFF
                      when :adr then bo = off * 4; ((bo & 3) << 29) | (((bo >> 2) & 0x7FFFF) << 5)
                      when :abs32 then @labels.fetch(n) * 4 # byte offset from the text base
                      end
      end
      @words.pack("V*")
    end
  end
end
