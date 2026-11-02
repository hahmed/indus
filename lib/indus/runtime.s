// Indus runtime routines, assembled once at dev time (tools/build_runtime.sh)
// into lib/indus/runtime_blob.rb. Position independent; only internal branches.
//
// Conventions: x27 = globals base ([x27] holds the write(2) function address),
// x28 = heap bump pointer. Strings/arrays: [cap][len][data...], handle -> data.
// Everything here follows AAPCS64 (x19-x28 callee-saved, lr saved when calling).

        .text

// rt_memcpy(x0 dst, x1 src, x2 len). Clobbers x3. Returns x0 = dst + len.
rt_memcpy:
        cbz     x2, 1f
0:      ldrb    w3, [x1], #1
        strb    w3, [x0], #1
        subs    x2, x2, #1
        b.ne    0b
1:      ret

// rt_alloc(x0 bytes) -> x0 handle; 16-byte header before it, 16-aligned bump.
rt_alloc:
        add     x1, x28, #16
        add     x28, x1, x0
        add     x28, x28, #15
        and     x28, x28, #0xfffffffffffffff0
        mov     x0, x1
        ret

// rt_str_new(x0 src, x1 len) -> handle (copy)
rt_str_new:
        stp     x29, x30, [sp, #-32]!
        stp     x19, x20, [sp, #16]
        mov     x19, x0
        mov     x20, x1
        mov     x0, x20
        bl      rt_alloc
        stur    x20, [x0, #-16]
        stur    x20, [x0, #-8]
        mov     x1, x19
        mov     x19, x0
        mov     x2, x20
        bl      rt_memcpy
        mov     x0, x19
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

// rt_str_cat(x0 a, x1 b) -> new handle a+b
rt_str_cat:
        stp     x29, x30, [sp, #-48]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        mov     x20, x1
        ldur    x21, [x19, #-8]
        ldur    x22, [x20, #-8]
        add     x0, x21, x22
        bl      rt_alloc
        add     x1, x21, x22
        stur    x1, [x0, #-16]
        stur    x1, [x0, #-8]
        mov     x1, x19
        mov     x19, x0                 // x19 = new handle
        mov     x2, x21
        bl      rt_memcpy               // x0 advanced past a's bytes
        mov     x1, x20
        mov     x2, x22
        bl      rt_memcpy
        mov     x0, x19
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

// rt_str_append(x0 a, x1 b) -> handle (a if it fits, else a grown copy)
rt_str_append:
        stp     x29, x30, [sp, #-64]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     x19, x0
        mov     x20, x1
        ldur    x21, [x19, #-8]         // len a
        ldur    x22, [x20, #-8]         // len b
        ldur    x23, [x19, #-16]        // cap a
        add     x24, x21, x22           // needed
        cmp     x24, x23
        b.hi    2f
        add     x0, x19, x21
        mov     x1, x20
        mov     x2, x22
        bl      rt_memcpy
        stur    x24, [x19, #-8]
        mov     x0, x19
        b       3f
2:      lsl     x0, x23, #1
        cmp     x0, x24
        csel    x0, x0, x24, hi
        mov     x23, x0                 // new cap
        bl      rt_alloc
        stur    x23, [x0, #-16]
        stur    x24, [x0, #-8]
        mov     x23, x0                 // new handle
        mov     x1, x19
        mov     x2, x21
        bl      rt_memcpy
        mov     x1, x20
        mov     x2, x22
        bl      rt_memcpy
        mov     x0, x23
3:      ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

// rt_str_eq(x0 a, x1 b) -> x0 1/0
rt_str_eq:
        ldur    x2, [x0, #-8]
        ldur    x3, [x1, #-8]
        cmp     x2, x3
        b.ne    9f
0:      cbz     x2, 8f
        ldrb    w3, [x0], #1
        ldrb    w4, [x1], #1
        cmp     w3, w4
        b.ne    9f
        sub     x2, x2, #1
        b       0b
8:      mov     x0, #1
        ret
9:      mov     x0, #0
        ret

// rt_itos(x0 n) -> handle, decimal
rt_itos:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        add     x1, sp, #48             // buffer is [sp+16, sp+48), filled backwards
        mov     x10, #10
        mov     x11, #0
        cmp     x0, #0
        b.ge    0f
        neg     x0, x0
        mov     x11, #1
0:      udiv    x2, x0, x10
        msub    x3, x2, x10, x0
        add     w3, w3, #48
        strb    w3, [x1, #-1]!
        mov     x0, x2
        cbnz    x0, 0b
        cbz     x11, 1f
        mov     w3, #45
        strb    w3, [x1, #-1]!
1:      add     x2, sp, #48
        sub     x2, x2, x1              // len
        mov     x0, x1
        mov     x1, x2
        bl      rt_str_new
        ldp     x29, x30, [sp], #48
        ret

// rt_puts_str(x0 s): write(1, s, len); write(1, "\n", 1)
rt_puts_str:
        stp     x29, x30, [sp, #-48]!
        str     x19, [sp, #16]
        mov     x19, x0
        ldur    x2, [x19, #-8]
        mov     x1, x19
        mov     x0, #1
        ldr     x16, [x27]
        blr     x16
        mov     w3, #10
        add     x1, sp, #32             // scratch byte, above the saved registers
        strb    w3, [x1]
        mov     x2, #1
        mov     x0, #1
        ldr     x16, [x27]
        blr     x16
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret
