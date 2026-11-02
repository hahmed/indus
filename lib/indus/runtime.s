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

// ---------------------------------------------------------------- hashes
// Open addressing, linear probe, power-of-two capacity, no deletes.
// Layout: [cap][len][entries...] with entries = [key][val] (16 bytes),
// handle -> entries. Empty slot: key == 0 (nil is never a key here).
// Two key kinds: strings (rt_hashs_*: FNV-1a over bytes, rt_str_eq) and
// integers (rt_hashi_*: multiplicative hash, ==).

// rt_str_hash(x0 s) -> x0 (FNV-1a 64)
rt_str_hash:
        ldur    x2, [x0, #-8]
        movz    x1, #0x2325
        movk    x1, #0x8422, lsl #16
        movk    x1, #0x9ce4, lsl #32
        movk    x1, #0xcbf2, lsl #48
        movz    x3, #0x01b3
        movk    x3, #0x0100, lsl #32
0:      cbz     x2, 1f
        ldrb    w4, [x0], #1
        eor     x1, x1, x4
        mul     x1, x1, x3
        sub     x2, x2, #1
        b       0b
1:      mov     x0, x1
        ret

// rt_hash_new(x0 cap) -> handle, zeroed
rt_hash_new:
        stp     x29, x30, [sp, #-32]!
        str     x19, [sp, #16]
        mov     x19, x0
        lsl     x0, x0, #4
        bl      rt_alloc
        stur    x19, [x0, #-16]
        stur    xzr, [x0, #-8]
        mov     x1, x0
        lsl     x2, x19, #4
        add     x2, x1, x2
0:      cmp     x1, x2
        b.hs    1f
        str     xzr, [x1], #8
        b       0b
1:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

// rt_hashs_find(x0 h, x1 key) -> x0 = entry address (key match, or the empty slot to use)
rt_hashs_find:
        stp     x29, x30, [sp, #-48]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        mov     x20, x1
        mov     x0, x1
        bl      rt_str_hash
        ldur    x21, [x19, #-16]        // cap
        sub     x21, x21, #1            // mask
        and     x22, x0, x21            // index
0:      add     x0, x19, x22, lsl #4    // entry
        ldr     x1, [x0]
        cbz     x1, 2f                  // empty -> return slot
        mov     x0, x1
        mov     x1, x20
        bl      rt_str_eq
        cbnz    x0, 1f
        add     x22, x22, #1
        and     x22, x22, x21
        b       0b
1:      add     x0, x19, x22, lsl #4
2:      ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

// rt_hashi_find(x0 h, x1 key): integer keys
rt_hashi_find:
        ldur    x2, [x0, #-16]
        sub     x2, x2, #1
        movz    x3, #0x7c15
        movk    x3, #0x58ed, lsl #16
        movk    x3, #0xa3c8, lsl #32
        movk    x3, #0x9e37, lsl #48
        mul     x4, x1, x3
        lsr     x4, x4, #20
        and     x4, x4, x2
0:      add     x5, x0, x4, lsl #4
        ldr     x6, [x5]
        cbz     x6, 1f
        cmp     x6, x1
        b.eq    1f
        add     x4, x4, #1
        and     x4, x4, x2
        b       0b
1:      mov     x0, x5
        ret

// rt_hashs_get(x0 h, x1 key) -> val or 0;  rt_hashs_key(x0 h, x1 key) -> 1/0
rt_hashs_get:
        stp     x29, x30, [sp, #-16]!
        bl      rt_hashs_find
        ldr     x1, [x0]
        cbz     x1, 0f
        ldr     x0, [x0, #8]
        ldp     x29, x30, [sp], #16
        ret
0:      mov     x0, #0
        ldp     x29, x30, [sp], #16
        ret
rt_hashs_key:
        stp     x29, x30, [sp, #-16]!
        bl      rt_hashs_find
        ldr     x0, [x0]
        cmp     x0, #0
        cset    x0, ne
        ldp     x29, x30, [sp], #16
        ret
rt_hashi_get:
        stp     x29, x30, [sp, #-16]!
        bl      rt_hashi_find
        ldr     x1, [x0]
        cbz     x1, 0f
        ldr     x0, [x0, #8]
        ldp     x29, x30, [sp], #16
        ret
0:      mov     x0, #0
        ldp     x29, x30, [sp], #16
        ret
rt_hashi_key:
        stp     x29, x30, [sp, #-16]!
        bl      rt_hashi_find
        ldr     x0, [x0]
        cmp     x0, #0
        cset    x0, ne
        ldp     x29, x30, [sp], #16
        ret

// rt_hashs_set(x0 h, x1 key, x2 val) -> handle (grown if load > 1/2)
rt_hashs_set:
        stp     x29, x30, [sp, #-64]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     x19, x0
        mov     x20, x1
        mov     x21, x2
        ldur    x22, [x19, #-16]        // cap
        ldur    x23, [x19, #-8]         // len
        add     x0, x23, #1
        lsl     x0, x0, #1
        cmp     x0, x22
        b.ls    1f
        // grow: new table of 2*cap, reinsert
        lsl     x0, x22, #1
        bl      rt_hash_new
        mov     x24, x0                 // new handle
        mov     x22, #0                 // i
0:      ldur    x1, [x19, #-16]
        cmp     x22, x1
        b.hs    2f
        add     x1, x19, x22, lsl #4
        ldr     x2, [x1]
        cbz     x2, 3f
        mov     x0, x24
        mov     x1, x2
        bl      rt_hashs_find
        add     x1, x19, x22, lsl #4
        ldr     x2, [x1]
        ldr     x3, [x1, #8]
        stp     x2, x3, [x0]
3:      add     x22, x22, #1
        b       0b
2:      stur    x23, [x24, #-8]
        mov     x19, x24
1:      mov     x0, x19
        mov     x1, x20
        bl      rt_hashs_find
        ldr     x1, [x0]
        cbnz    x1, 4f
        add     x23, x23, #1
        stur    x23, [x19, #-8]
4:      stp     x20, x21, [x0]
        mov     x0, x19
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

rt_hashi_set:
        stp     x29, x30, [sp, #-64]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     x19, x0
        mov     x20, x1
        mov     x21, x2
        ldur    x22, [x19, #-16]
        ldur    x23, [x19, #-8]
        add     x0, x23, #1
        lsl     x0, x0, #1
        cmp     x0, x22
        b.ls    1f
        lsl     x0, x22, #1
        bl      rt_hash_new
        mov     x24, x0
        mov     x22, #0
0:      ldur    x1, [x19, #-16]
        cmp     x22, x1
        b.hs    2f
        add     x1, x19, x22, lsl #4
        ldr     x2, [x1]
        cbz     x2, 3f
        mov     x0, x24
        mov     x1, x2
        bl      rt_hashi_find
        add     x1, x19, x22, lsl #4
        ldr     x2, [x1]
        ldr     x3, [x1, #8]
        stp     x2, x3, [x0]
3:      add     x22, x22, #1
        b       0b
2:      stur    x23, [x24, #-8]
        mov     x19, x24
1:      mov     x0, x19
        mov     x1, x20
        bl      rt_hashi_find
        ldr     x1, [x0]
        cbnz    x1, 4f
        add     x23, x23, #1
        stur    x23, [x19, #-8]
4:      stp     x20, x21, [x0]
        mov     x0, x19
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

// rt_hash_keys(x0 h) -> array handle [cap][len][keys...]
rt_hash_keys:
        stp     x29, x30, [sp, #-48]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        ldur    x20, [x19, #-8]         // len
        lsl     x0, x20, #3
        bl      rt_alloc
        stur    x20, [x0, #-16]
        stur    x20, [x0, #-8]
        mov     x21, x0                 // out
        mov     x22, #0                 // i
        ldur    x3, [x19, #-16]         // cap
0:      cmp     x22, x3
        b.hs    1f
        add     x1, x19, x22, lsl #4
        ldr     x2, [x1]
        cbz     x2, 2f
        str     x2, [x0], #8
2:      add     x22, x22, #1
        b       0b
1:      mov     x0, x21
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

// rt_str_sub(x0 s, x1 start, x2 len) -> new string, or 0 if start is out of range
rt_str_sub:
        ldur    x3, [x0, #-8]
        cmp     x1, x3
        b.hi    9f                      // start > len (unsigned: negatives too)
        sub     x3, x3, x1
        cmp     x2, x3
        csel    x2, x2, x3, ls          // clamp len
        add     x0, x0, x1
        mov     x1, x2
        b       rt_str_new
9:      mov     x0, #0
        ret
