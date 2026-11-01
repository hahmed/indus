# arm64 encoder + the hand-written runtime routines (puts, putc, arrays, syscalls).
module Indus
  class Asm
    attr_reader :words
    def initialize = (@words, @labels, @fixups, @data = [], {}, [], [])
    def pos = @words.size
    def emit(w) = @words << (w & 0xFFFFFFFF)
    def label(n) = (@labels[n] = pos)
    def fix(n, k) = @fixups << [pos, n, k]

    def movz(rd, imm, sh = 0) = emit(0xD2800000 | (sh << 21) | ((imm & 0xFFFF) << 5) | rd)
    def movk(rd, imm, sh) = emit(0xF2800000 | (sh << 21) | ((imm & 0xFFFF) << 5) | rd)
    def movn(rd, imm) = emit(0x92800000 | ((imm & 0xFFFF) << 5) | rd)
    def mov_imm(rd, v)
      if v < 0 && v >= -0x10000 then movn(rd, ~v)
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

    # x0 = bytes -> x0 = zeroed block from the bump heap
    def emit_object_new
      label(:__onew)
      emit 0xAA1C03E1                 # mov x1, x28
      emit 0x8B00039C                 # add x28, x28, x0
      emit 0x91003F9C; emit 0x927CEF9C # round x28 up to 16
      emit 0xAA0103E2                 # mov x2, x1
      l = uniq; d = uniq
      label(l)
      emit 0xEB1C005F                 # cmp x2, x28
      bhs(d)
      emit 0xF800845F                 # str xzr, [x2], #8
      b(l)
      label(d)
      emit 0xAA0103E0                 # mov x0, x1
      ret
    end

    # x0 = base, x1 = exp (>= 0) -> x0 = base ** exp
    def emit_ipow
      label(:__ipow)
      emit 0xAA0003E2                 # mov x2, x0
      emit 0xD2800020                 # mov x0, #1
      l = uniq; d = uniq
      label(l)
      cbz(1, d)
      emit 0x9B027C00                 # mul x0, x0, x2
      emit 0xD1000421                 # sub x1, x1, #1
      b(l)
      label(d)
      ret
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
    # putc: x0 = char. strb to stack, write(1, sp+15, 1)
    def emit_putc
      label(:__putc)
      stp_pre(29, 30, 32); mov_fp_sp
      emit 0x390043E0                 # strb w0, [sp, #16]   (above the saved fp/lr pair)
      emit 0x910003E1 | (16 << 10)    # add x1, sp, #16
      emit 0xD2800022                 # mov x2, #1
      emit 0xD2800020                 # mov x0, #1
      call_write
      ldp_post(29, 30, 32); ret
    end
    def uniq = (@u = (@u || 0) + 1; :"L#{@u}")

    HEAP = 28 # bump pointer, reserved; arrays: [cap][len][elems...], handle -> elems

    # x0 = len, x1 = fill -> x0 = handle. cap = len.
    def emit_array_new
      label(:__anew)
      emit 0x91004382             # add x2, x28, #16        handle after the header
      stur(0, 2, -16)             # cap = len
      stur(0, 2, -8)              # len
      emit 0x8B000C5C             # add x28, x2, x0, lsl #3
      emit 0x91003F9C             # add x28, x28, #15
      emit 0x927CEF9C             # and x28, x28, #~15      bump, 16-aligned
      emit 0xD2800003             # mov x3, #0
      l = uniq; d = uniq
      label(l)
      emit 0xEB00007F             # cmp x3, x0
      bhs(d)
      str_idx(1, 2, 3)            # [x2 + x3*8] = fill
      emit 0x91000463             # add x3, x3, #1
      b(l)
      label(d)
      emit 0xAA0203E0             # mov x0, x2
      ret
    end

    # x0 = handle, x1 = i (>= len), x2 = v -> x0 = handle (new one if grown)
    def emit_array_set_slow
      label(:__aset_slow)
      ldur(3, 0, -16)             # cap
      ldur(4, 0, -8)              # len
      emit 0xEB03003F             # cmp x1, x3
      grow = uniq; fill = uniq; store = uniq
      bhs(grow)
      label(fill)                 # fill len..i-1 with nil(0)
      emit 0xEB01009F             # cmp x4, x1
      bhs(store)
      str_idx(31, 0, 4)           # xzr
      emit 0x91000484             # add x4, x4, #1
      b(fill)
      label(store)
      str_idx(2, 0, 1)
      emit 0x91000424             # add x4, x1, #1
      stur(4, 0, -8)              # len = i+1
      ret
      label(grow)                 # newcap = max(cap*2, i+1); copy; then fill/store on the new array
      emit 0xD37FF865             # lsl x5, x3, #1
      emit 0x91000426             # add x6, x1, #1
      emit 0xEB0600BF             # cmp x5, x6
      emit 0x9A8680A5             # csel x5, x5, x6, hi     newcap = max(cap*2, i+1)
      emit 0x91004387             # add x7, x28, #16  (new handle)
      stur(5, 7, -16)             # cap
      stur(4, 7, -8)              # len (same as old)
      emit 0x8B050CFC             # add x28, x7, x5, lsl #3
      emit 0x91003F9C; emit 0x927CEF9C
      emit 0xD2800006             # x6 = 0 (copy index)
      cl = uniq; cd = uniq
      label(cl)
      emit 0xEB0400DF             # cmp x6, x4
      bhs(cd)
      ldr_idx(9, 0, 6); str_idx(9, 7, 6)
      emit 0x910004C6             # add x6, x6, #1
      b(cl)
      label(cd)
      emit 0xAA0703E0             # mov x0, x7
      b(fill)
    end
    def addi(rd, rn, i)
      raise "addi immediate out of range: #{i}" unless (0..4095).cover?(i) || (i % 4096 == 0 && i <= 4095 * 4096)
      i < 4096 ? emit(0x91000000 | (i << 10) | (rn << 5) | rd) : emit(0x91400000 | ((i >> 12) << 10) | (rn << 5) | rd)
    end
    def subi(rd, rn, i) = emit(0xD1000000 | (i << 10) | (rn << 5) | rd)
    def cmp(rn, rm) = emit(0xEB00001F | (rm << 16) | (rn << 5))
    def cmpi(rn, i) = emit(0xF100001F | (i << 10) | (rn << 5))
    COND = { eq: 0x0, ne: 0x1, ge: 0xA, lt: 0xB, gt: 0xC, le: 0xD, mi: 0x4, pl: 0x5, ls: 0x9, hi: 0x8,
             # float compares: unordered must be false for < <= (mi/ls), true for != (ne)
             feq: 0x0, fne: 0x1, flt: 0x4, fle: 0x9, fgt: 0xC, fge: 0xA }
    INV = { eq: :ne, ne: :eq, ge: :lt, lt: :ge, gt: :le, le: :gt, mi: :pl, pl: :mi, ls: :hi, hi: :ls,
            feq: :fne, fne: :feq, flt: :pl, fle: :hi, fgt: :fle_u, fge: :flt_u }
    COND[:fle_u] = 0xD; COND[:flt_u] = 0xB # le / lt (true on unordered), the inverses of gt / ge
    def cset(rd, c) = emit(0x9A9F07E0 | (COND[INV[c]] << 12) | rd)
    def bcond(c, n) = (fix(n, :b19); emit(0x54000000 | COND[c]))
    def cbz(rt, n) = (fix(n, :b19); emit(0xB4000000 | rt))
    def cbnz(rt, n) = (fix(n, :b19); emit(0xB5000000 | rt))
    def b(n) = (fix(n, :b26); emit(0x14000000))
    def bl(n) = (fix(n, :b26); emit(0x94000000))
    def blr(rn) = emit(0xD63F0000 | (rn << 5))
    def ret = emit(0xD65F03C0)
    def adr(rd, n) = (fix(n, :adr); emit(0x10000000 | rd))
    def stp(t1, t2, off) = t2 ? emit(0xA9000000 | ((off / 8) << 15) | (t2 << 10) | (31 << 5) | t1) : str(t1, off)
    def ldp(t1, t2, off) = t2 ? emit(0xA9400000 | ((off / 8) << 15) | (t2 << 10) | (31 << 5) | t1) : ldr(t1, off)
    def str(t, off) = emit(0xF9000000 | ((off / 8) << 10) | (31 << 5) | t)
    def ldr(t, off) = emit(0xF9400000 | ((off / 8) << 10) | (31 << 5) | t)
    def stp_pre(t1, t2, sz) = emit(0xA9800000 | (((-sz / 8) & 0x7F) << 15) | (t2 << 10) | (31 << 5) | t1)
    def ldp_post(t1, t2, sz) = emit(0xA8C00000 | ((sz / 8) << 15) | (t2 << 10) | (31 << 5) | t1)
    def mov_fp_sp = emit(0x910003FD)

    # data: bytes placed after the code, addressed with adr
    def data(name, bytes) = @data << [name, bytes]
    # globals: 8-byte slots at the start of the heap, addressed off x27
    GBASE = 27
    def global(name) = (@globals ||= {})[name] ||= @globals.size * 8

    # --- the whole "runtime": puts for an Integer, via write(2) --------------
    # x0 = value. Builds decimal + "\n" in a 32-byte stack buffer, calls write.
    attr_accessor :write_addr # nil => bl __write (syscall stub)
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
    end

    # linux has no dyld to call main: _start calls main then exit(0)
    def emit_start_linux
      label(:_start)
      # mmap(NULL, 256MB, PROT_READ|WRITE, MAP_PRIVATE|ANON, -1, 0) -> x0
      emit 0xD2800000             # mov x0, #0
      emit 0xD2A20001             # mov x1, #0x10000000
      emit 0xD2800062             # mov x2, #3
      emit 0xD2800443             # mov x3, #0x22
      emit 0x92800004             # mov x4, #-1
      emit 0xD2800005             # mov x5, #0
      emit 0xD2801BC8             # mov x8, #222
      emit 0xD4000001             # svc #0
      bl(:main)
      emit 0xD2800000; emit 0xD2800BA8; emit 0xD4000001            # mov x0,#0 ; mov x8,#93 ; svc #0
    end

    def emit_puts_i
      label(:__puts_i)
      stp_pre(29, 30, 48); mov_fp_sp
      emit 0x910083E1                 # add x1, sp, #32        (end of buffer; buf is [sp+16, sp+48))
      emit 0x9100C3E1                 # add x1, sp, #48
      emit 0x52800143                 # mov w3, #10  '\n'
      emit 0x381FFC23                 # strb w3, [x1, #-1]!
      emit 0xD280014A                 # mov x10, #10
      emit 0xD280000B                 # mov x11, #0  (negative flag)
      emit 0xF100001F                 # cmp x0, #0
      bcond(:ge, :__pi_loop)
      emit 0xCB0003E0                 # neg x0, x0
      emit 0xD280002B                 # mov x11, #1
      label(:__pi_loop)
      emit 0x9ACA0802                 # udiv x2, x0, x10
      emit 0x9B0A8043                 # msub x3, x2, x10, x0
      emit 0x1100C063                 # add w3, w3, #48
      emit 0x381FFC23                 # strb w3, [x1, #-1]!
      emit 0xAA0203E0                 # mov x0, x2
      cbnz(0, :__pi_loop)
      cbz(11, :__pi_write)
      emit 0x528005A3                 # mov w3, #45 '-'
      emit 0x381FFC23                 # strb w3, [x1, #-1]!
      label(:__pi_write)
      emit 0x9100C3E2                 # add x2, sp, #48
      emit 0xCB010042                 # sub x2, x2, x1
      emit 0xD2800020                 # mov x0, #1
      call_write
      ldp_post(29, 30, 48); ret
    end

    def resolve!
      # place data after code, 8-aligned
      emit 0 while pos % 2 != 0
      @data.each do |name, bytes|
        label(name)
        padded = bytes + "\0" * ((4 - bytes.bytesize % 4) % 4)
        @words.concat(padded.unpack("V*"))
      end
      @fixups.each do |at, n, k|
        off = @labels.fetch(n) { raise "undefined #{n}" } - at
        @words[at] |= case k
                      when :b19 then (off & 0x7FFFF) << 5
                      when :b26 then off & 0x3FFFFFF
                      when :adr then bo = off * 4; ((bo & 3) << 29) | (((bo >> 2) & 0x7FFFF) << 5)
                      end
      end
      @words.pack("V*")
    end
  end
end
