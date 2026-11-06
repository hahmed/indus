// Indus runtime routines, assembled once at dev time (tools/build-rt)
// into lib/indus/rt/blob.rb. Position independent; only internal branches.
//
// Conventions: x27 = globals base ([x27] holds the write(2) function address),
// x28 = heap bump pointer. Strings/arrays: [cap][len][data...], handle -> data.
// Everything here follows AAPCS64 (x19-x28 callee-saved, lr saved when calling).

        .text

// rt_memcpy(x0 dst, x1 src, x2 len). Clobbers x3. Returns x0 = dst + len.
rt_memcpy:
        cmp     x2, #16
        b.lo    2f
0:      ldp     x3, x4, [x1], #16       // 16 bytes a step while at least 16 remain
        stp     x3, x4, [x0], #16
        sub     x2, x2, #16
        cmp     x2, #16
        b.hs    0b
2:      cbz     x2, 1f
3:      ldrb    w3, [x1], #1            // the tail, bytewise
        strb    w3, [x0], #1
        subs    x2, x2, #1
        b.ne    3b
1:      ret

// rt_alloc(x0 bytes) -> x0 handle; 16-byte header before it, 16-aligned bump.
// If it does not fit in the current space ([x27+24] = from_end), it gets its
// own mapping: a large object the collector scans in place and never moves.
rt_alloc:
        add     x1, x28, #16
        add     x2, x1, x0
        add     x2, x2, #15
        and     x2, x2, #0xfffffffffffffff0
        ldr     x3, [x27, #24]
        cmp     x2, x3
        b.hi    1f
        mov     x28, x2
        mov     x0, x1
        ret
1:      stp     x29, x30, [sp, #-16]!
        add     x0, x0, #32
        bl      rt_mmap
        add     x0, x0, #16
        ldp     x29, x30, [sp], #16
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

// rt_str_alloc(x0 len) -> handle of an uninitialised string of len bytes
rt_str_alloc:
        stp     x29, x30, [sp, #-32]!
        str     x19, [sp, #16]
        mov     x19, x0
        bl      rt_alloc
        stur    x19, [x0, #-16]
        stur    x19, [x0, #-8]
        ldr     x19, [sp, #16]
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

// rt_str_catn(x0 n, x1 ptr to n handles) -> handle: the concatenation, sized once
rt_str_catn:
        stp     x29, x30, [sp, #-48]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0                 // n
        mov     x20, x1                 // handles
        mov     x21, #0                 // total
        mov     x2, #0
0:      ldr     x3, [x20, x2, lsl #3]
        ldur    x3, [x3, #-8]
        add     x21, x21, x3
        add     x2, x2, #1
        cmp     x2, x19
        b.lo    0b
        mov     x0, x21
        bl      rt_alloc
        stur    x21, [x0, #-16]
        stur    x21, [x0, #-8]
        mov     x22, x0                 // the handle
        mov     x21, #0                 // index
1:      ldr     x1, [x20, x21, lsl #3]
        ldur    x2, [x1, #-8]
        bl      rt_memcpy               // x0 advances
        add     x21, x21, #1
        cmp     x21, x19
        b.lo    1b
        mov     x0, x22
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
        cmp     x0, #32                 // a string that grows starts at 32 bytes: exact fit from 0 reallocates every append
        mov     x1, #32
        csel    x0, x0, x1, hi
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
// rt_puts_str(x0 s): write s, then a newline unless s already ends in one (Ruby's puts)
// rt_eputs_str: the same to stderr
rt_eputs_str:
        mov     x4, #2
        b       0f
rt_puts_str:
        mov     x4, #1
0:      stp     x29, x30, [sp, #-48]!
        stp     x19, x20, [sp, #16]
        mov     x19, x0
        mov     x20, x4
        ldur    x2, [x19, #-8]
        mov     x1, x19
        mov     x0, x20
        ldr     x16, [x27]
        blr     x16
        ldur    x2, [x19, #-8]
        cbz     x2, 1f
        sub     x2, x2, #1
        ldrb    w3, [x19, x2]
        cmp     w3, #10
        b.eq    2f
1:      mov     w3, #10
        add     x1, sp, #32             // scratch byte, above the saved registers
        strb    w3, [x1]
        mov     x2, #1
        mov     x0, x20
        ldr     x16, [x27]
        blr     x16
2:      ldp     x19, x20, [sp, #16]
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

// Loop regions with survivors (notes/65). At a region's back edge the iteration's
// allocations are dropped by resetting the bump pointer; a value that escaped into
// pre-existing memory is first moved down to the cursor and its slot patched.
//   rt_keep_str(x0 slot, x1 cursor) -> x1 new cursor   slot holds a string handle
//   rt_keep_cell(x0 slot, x1 cursor) -> x1              slot holds a one-word cell whose word is a string handle
// A handle is 16 past its header ([-16] cap, [-8] len). The copy keeps cap = len (trimmed).
rt_keep_str:
        cbz     x0, 9f                  // no slot this iteration (the store was conditional)
        stp     x29, x30, [sp, #-48]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0                 // slot
        mov     x20, x1                 // cursor (16-aligned)
        ldr     x21, [x19]              // old handle
        cbz     x21, 1f
        ldur    x22, [x21, #-8]         // len
        add     x1, x20, #16            // new handle
        str     x22, [x20]              // cap = len
        str     x22, [x20, #8]          // len
        mov     x0, x1
        mov     x2, x22
        mov     x1, x21
        stp     x0, x22, [sp, #-16]!
        bl      rt_memcpy
        ldp     x0, x22, [sp], #16
        str     x0, [x19]               // patch the slot
        add     x1, x0, x22
        add     x1, x1, #15
        and     x1, x1, #0xfffffffffffffff0
        b       2f
1:      mov     x1, x20
2:      ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
9:      ret
rt_keep_cell:
        cbz     x0, 9f                  // no slot this iteration (the store was conditional)
        stp     x29, x30, [sp, #-48]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0                 // slot holding the cell
        mov     x20, x1
        ldr     x21, [x19]              // the cell
        cbz     x21, 1f
        mov     x0, x21                 // keep the string the cell points at, patching the cell's word
        mov     x1, x20
        bl      rt_keep_str
        mov     x20, x1
        ldr     x22, [x21]              // the (new) string handle
        str     x22, [x20]              // the new cell: one word
        str     x20, [x19]              // patch the slot
        add     x1, x20, #16
        b       2f
1:      mov     x1, x20
2:      ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
9:      ret

// rt_hash_new(x0 cap) -> handle. Layout: [key,val] slots * cap (open
// addressing, zeroed), then cap words of slot indices in insertion order,
// so iteration follows Ruby's order. Header: [-16] cap, [-8] count.
rt_hash_new:
        stp     x29, x30, [sp, #-32]!
        str     x19, [sp, #16]
        mov     x19, x0
        lsl     x0, x0, #4
        add     x0, x0, x19, lsl #3
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
// integer-valued hashes: a miss is the int-nil sentinel INT64_MIN
rt_hashs_geti:
        stp     x29, x30, [sp, #-16]!
        bl      rt_hashs_find
        ldr     x1, [x0]
        cbz     x1, 0f
        ldr     x0, [x0, #8]
        ldp     x29, x30, [sp], #16
        ret
0:      movz    x0, #0x8000, lsl #48
        ldp     x29, x30, [sp], #16
        ret
rt_hashi_geti:
        stp     x29, x30, [sp, #-16]!
        bl      rt_hashi_find
        ldr     x1, [x0]
        cbz     x1, 0f
        ldr     x0, [x0, #8]
        ldp     x29, x30, [sp], #16
        ret
0:      movz    x0, #0x8000, lsl #48
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
        mov     x22, #0                 // i over the old order list
0:      cmp     x22, x23
        b.hs    2f
        ldur    x1, [x19, #-16]
        add     x1, x19, x1, lsl #4     // old order list
        ldr     x1, [x1, x22, lsl #3]   // old slot index
        add     x1, x19, x1, lsl #4     // old entry
        ldr     x2, [x1]
        mov     x0, x24
        mov     x1, x2
        bl      rt_hashs_find
        ldur    x1, [x19, #-16]
        add     x1, x19, x1, lsl #4
        ldr     x1, [x1, x22, lsl #3]
        add     x1, x19, x1, lsl #4
        ldr     x2, [x1]
        ldr     x3, [x1, #8]
        stp     x2, x3, [x0]
        sub     x0, x0, x24             // new slot index, appended in the same order
        lsr     x0, x0, #4
        ldur    x1, [x24, #-16]
        add     x1, x24, x1, lsl #4
        str     x0, [x1, x22, lsl #3]
        add     x22, x22, #1
        b       0b
2:      stur    x23, [x24, #-8]
        mov     x19, x24
1:      mov     x0, x19
        mov     x1, x20
        bl      rt_hashs_find
        ldr     x1, [x0]
        cbnz    x1, 4f
        sub     x1, x0, x19             // a new key: record its slot in the order list
        lsr     x1, x1, #4
        ldur    x2, [x19, #-16]
        add     x2, x19, x2, lsl #4
        str     x1, [x2, x23, lsl #3]
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
        mov     x24, x0                 // new handle
        mov     x22, #0                 // i over the old order list
0:      cmp     x22, x23
        b.hs    2f
        ldur    x1, [x19, #-16]
        add     x1, x19, x1, lsl #4     // old order list
        ldr     x1, [x1, x22, lsl #3]   // old slot index
        add     x1, x19, x1, lsl #4     // old entry
        ldr     x2, [x1]
        mov     x0, x24
        mov     x1, x2
        bl      rt_hashi_find
        ldur    x1, [x19, #-16]
        add     x1, x19, x1, lsl #4
        ldr     x1, [x1, x22, lsl #3]
        add     x1, x19, x1, lsl #4
        ldr     x2, [x1]
        ldr     x3, [x1, #8]
        stp     x2, x3, [x0]
        sub     x0, x0, x24             // new slot index, appended in the same order
        lsr     x0, x0, #4
        ldur    x1, [x24, #-16]
        add     x1, x24, x1, lsl #4
        str     x0, [x1, x22, lsl #3]
        add     x22, x22, #1
        b       0b
2:      stur    x23, [x24, #-8]
        mov     x19, x24
1:      mov     x0, x19
        mov     x1, x20
        bl      rt_hashi_find
        ldr     x1, [x0]
        cbnz    x1, 4f
        sub     x1, x0, x19             // a new key: record its slot in the order list
        lsr     x1, x1, #4
        ldur    x2, [x19, #-16]
        add     x2, x19, x2, lsl #4
        str     x1, [x2, x23, lsl #3]
        add     x23, x23, #1
        stur    x23, [x19, #-8]
4:      stp     x20, x21, [x0]
        mov     x0, x19
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

// rt_hashd_find(x0 h, x1 key): tagged keys (notes/29). A string (tag 2) hashes and compares
// by content through its bare handle; everything else (fixnum, symbol, bool, nil, an object,
// an array) by the word itself. Two equal strings boxed separately are the same key.
rt_hashd_find:
        stp     x29, x30, [sp, #-48]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        mov     x20, x1
        and     x2, x20, #15
        cmp     x2, #2
        b.ne    5f
        and     x0, x20, #~15
        bl      rt_str_hash
        b       6f
5:      movz    x3, #0x7c15
        movk    x3, #0x58ed, lsl #16
        movk    x3, #0xa3c8, lsl #32
        movk    x3, #0x9e37, lsl #48
        mul     x0, x20, x3
        lsr     x0, x0, #20
6:      ldur    x21, [x19, #-16]        // cap
        sub     x21, x21, #1            // mask
        and     x22, x0, x21            // index
0:      add     x0, x19, x22, lsl #4    // entry
        ldr     x1, [x0]
        cbz     x1, 2f                  // empty -> return slot
        cmp     x1, x20
        b.eq    1f                      // same word
        and     x2, x1, #15
        cmp     x2, #2
        b.ne    3f                      // not a string: no further test
        and     x2, x20, #15
        cmp     x2, #2
        b.ne    3f
        and     x0, x1, #~15
        and     x1, x20, #~15
        bl      rt_str_eq
        cbnz    x0, 1f
3:      add     x22, x22, #1
        and     x22, x22, x21
        b       0b
1:      add     x0, x19, x22, lsl #4
2:      ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret
rt_hashd_get:
        stp     x29, x30, [sp, #-16]!
        bl      rt_hashd_find
        ldr     x1, [x0]
        cbz     x1, 0f
        ldr     x0, [x0, #8]
        ldp     x29, x30, [sp], #16
        ret
0:      mov     x0, #0
        ldp     x29, x30, [sp], #16
        ret
rt_hashd_geti:
        stp     x29, x30, [sp, #-16]!
        bl      rt_hashd_find
        ldr     x1, [x0]
        cbz     x1, 0f
        ldr     x0, [x0, #8]
        ldp     x29, x30, [sp], #16
        ret
0:      movz    x0, #0x8000, lsl #48
        ldp     x29, x30, [sp], #16
        ret
rt_hashd_key:
        stp     x29, x30, [sp, #-16]!
        bl      rt_hashd_find
        ldr     x0, [x0]
        cmp     x0, #0
        cset    x0, ne
        ldp     x29, x30, [sp], #16
        ret
rt_hashd_set:
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
        mov     x22, #0                 // i over the old order list
0:      cmp     x22, x23
        b.hs    2f
        ldur    x1, [x19, #-16]
        add     x1, x19, x1, lsl #4     // old order list
        ldr     x1, [x1, x22, lsl #3]   // old slot index
        add     x1, x19, x1, lsl #4     // old entry
        ldr     x2, [x1]
        mov     x0, x24
        mov     x1, x2
        bl      rt_hashd_find
        ldur    x1, [x19, #-16]
        add     x1, x19, x1, lsl #4
        ldr     x1, [x1, x22, lsl #3]
        add     x1, x19, x1, lsl #4
        ldr     x2, [x1]
        ldr     x3, [x1, #8]
        stp     x2, x3, [x0]
        sub     x0, x0, x24             // new slot index, appended in the same order
        lsr     x0, x0, #4
        ldur    x1, [x24, #-16]
        add     x1, x24, x1, lsl #4
        str     x0, [x1, x22, lsl #3]
        add     x22, x22, #1
        b       0b
2:      stur    x23, [x24, #-8]
        mov     x19, x24
1:      mov     x0, x19
        mov     x1, x20
        bl      rt_hashd_find
        ldr     x1, [x0]
        cbnz    x1, 4f
        sub     x1, x0, x19             // a new key: record its slot in the order list
        lsr     x1, x1, #4
        ldur    x2, [x19, #-16]
        add     x2, x19, x2, lsl #4
        str     x1, [x2, x23, lsl #3]
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
        add     x3, x19, x3, lsl #4     // order list
0:      cmp     x22, x20
        b.hs    1f
        ldr     x1, [x3, x22, lsl #3]
        add     x1, x19, x1, lsl #4
        ldr     x2, [x1]
        str     x2, [x0], #8
        add     x22, x22, #1
        b       0b
1:      mov     x0, x21
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

// rt_str_sub(x0 s, x1 start, x2 len) -> new string, or 0 if start is out of range
rt_str_sub:
        ldur    x3, [x0, #-8]
        tbz     x1, #63, 0f
        add     x1, x1, x3              // a negative start counts from the end
0:      cmp     x1, x3
        b.hi    9f                      // start > len (unsigned: negatives too)
        sub     x3, x3, x1
        cmp     x2, x3
        csel    x2, x2, x3, ls          // clamp len
        add     x0, x0, x1
        mov     x1, x2
        b       rt_str_new
9:      mov     x0, #0
        ret

// ---------------------------------------------------------------- formerly hand-encoded
// __puts_i(x0 n): decimal + newline via write
__puts_i:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        add     x1, sp, #48
        mov     w3, #10
        strb    w3, [x1, #-1]!
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
        sub     x2, x2, x1
        mov     x0, #1
        ldr     x16, [x27]
        blr     x16
        ldp     x29, x30, [sp], #48
        ret

// __putc(x0 char)
__putc:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        strb    w0, [sp, #16]
        add     x1, sp, #16
        mov     x2, #1
        mov     x0, #1
        ldr     x16, [x27]
        blr     x16
        ldp     x29, x30, [sp], #32
        ret

// __anew(x0 len, x1 fill) -> handle; cap = len
__anew:
        stp     x29, x30, [sp, #-32]!
        stp     x19, x20, [sp, #16]
        mov     x19, x0
        mov     x20, x1
        lsl     x0, x0, #3
        bl      rt_alloc
        mov     x2, x0
        stur    x19, [x2, #-16]
        stur    x19, [x2, #-8]
        mov     x3, #0
0:      cmp     x3, x19
        b.hs    1f
        str     x20, [x2, x3, lsl #3]
        add     x3, x3, #1
        b       0b
1:      mov     x0, x2
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

// __aset_slow(x0 handle, x1 i >= len, x2 v) -> handle (grown if needed)
__aset_slow:
        ldur    x3, [x0, #-16]          // cap
        ldur    x4, [x0, #-8]           // len
        cmp     x1, x3
        b.hs    2f
0:      cmp     x4, x1                  // fill len..i-1 with nil
        b.hs    1f
        str     xzr, [x0, x4, lsl #3]
        add     x4, x4, #1
        b       0b
1:      str     x2, [x0, x1, lsl #3]
        add     x4, x1, #1
        stur    x4, [x0, #-8]
        ret
2:      lsl     x5, x3, #1              // grow: max(2*cap, i+1)
        add     x6, x1, #1
        cmp     x5, x6
        csel    x5, x5, x6, hi
        stp     x29, x30, [sp, #-64]!
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     x19, x0
        mov     x20, x1
        mov     x21, x2
        mov     x22, x4
        mov     x23, x5
        lsl     x0, x5, #3
        bl      rt_alloc
        mov     x7, x0
        mov     x0, x19
        mov     x1, x20
        mov     x2, x21
        mov     x4, x22
        mov     x5, x23
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        stur    x5, [x7, #-16]
        stur    x4, [x7, #-8]
        mov     x6, #0
3:      cmp     x6, x4
        b.hs    4f
        ldr     x9, [x0, x6, lsl #3]
        str     x9, [x7, x6, lsl #3]
        add     x6, x6, #1
        b       3b
4:      mov     x0, x7
        b       0b

// __onew(x0 bytes) -> zeroed block (no header: the handle is the block)
__onew:
        stp     x29, x30, [sp, #-32]!
        str     x19, [sp, #16]
        mov     x19, x0
        sub     x0, x0, #16             // rt_alloc adds a 16-byte header; objects have none,
        bl      rt_alloc                // so ask for 16 less and use the header as the block
        sub     x1, x0, #16
        mov     x2, x1
        add     x3, x1, x19
0:      cmp     x2, x3
        b.hs    1f
        str     xzr, [x2], #8
        b       0b
1:      mov     x0, x1
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

// __ipow(x0 base, x1 exp) -> base ** exp
__ipow:
        mov     x2, x0
        mov     x0, #1
0:      cbz     x1, 1f
        mul     x0, x0, x2
        sub     x1, x1, #1
        b       0b
1:      ret

// ---------------------------------------------------------------- the collector
// The collector itself is Ruby (lib/indus/rt/gc.rb), compiled by Indus
// into GC-mode programs as __gc_run(fp) -> new bump pointer. This stub is the
// safepoint entry: it preserves every caller-saved register (the compiled
// code may hold non-pointer temporaries in them) and hands over the frame
// pointer so the frame walk starts at the caller.
rt_gc:
        stp     x29, x30, [sp, #-176]!
        mov     x29, sp
        stp     x0, x1, [sp, #16]
        stp     x2, x3, [sp, #32]
        stp     x4, x5, [sp, #48]
        stp     x6, x7, [sp, #64]
        stp     x8, x9, [sp, #80]
        stp     x10, x11, [sp, #96]
        stp     x12, x13, [sp, #112]
        stp     x14, x15, [sp, #128]
        stp     x16, x17, [sp, #144]
        str     x18, [sp, #160]
        sub     sp, sp, #256
        stp     d0, d1, [sp, #0]
        stp     d2, d3, [sp, #16]
        stp     d4, d5, [sp, #32]
        stp     d6, d7, [sp, #48]
        stp     d16, d17, [sp, #64]
        stp     d18, d19, [sp, #80]
        stp     d20, d21, [sp, #96]
        stp     d22, d23, [sp, #112]
        stp     d24, d25, [sp, #128]
        stp     d26, d27, [sp, #144]
        stp     d28, d29, [sp, #160]
        stp     d30, d31, [sp, #176]
        ldr     x0, [x27, #16]                  // bytes the heap took since the last collection: from-space start to the bump
        sub     x0, x28, x0
        ldr     x1, [x27, #112]
        add     x1, x1, x0
        str     x1, [x27, #112]                 // __gc_allocated
        mov     x0, x29                         // the frame chain, starting here
        bl      __gc_run
        mov     x28, x0                         // allocation continues in to-space
        ldp     d0, d1, [sp, #0]
        ldp     d2, d3, [sp, #16]
        ldp     d4, d5, [sp, #32]
        ldp     d6, d7, [sp, #48]
        ldp     d16, d17, [sp, #64]
        ldp     d18, d19, [sp, #80]
        ldp     d20, d21, [sp, #96]
        ldp     d22, d23, [sp, #112]
        ldp     d24, d25, [sp, #128]
        ldp     d26, d27, [sp, #144]
        ldp     d28, d29, [sp, #160]
        ldp     d30, d31, [sp, #176]
        add     sp, sp, #256
        ldp     x0, x1, [sp, #16]
        ldp     x2, x3, [sp, #32]
        ldp     x4, x5, [sp, #48]
        ldp     x6, x7, [sp, #64]
        ldp     x8, x9, [sp, #80]
        ldp     x10, x11, [sp, #96]
        ldp     x12, x13, [sp, #112]
        ldp     x14, x15, [sp, #128]
        ldp     x16, x17, [sp, #144]
        ldr     x18, [sp, #160]
        ldp     x29, x30, [sp], #176
        ret

// rt_mmap(x0 bytes) -> address. Through the slot [x27+88] like write:
// libc mmap in-process, the syscall stub in a standalone binary.
rt_mmap:
        stp     x29, x30, [sp, #-16]!
        mov     x1, x0                          // size
        mov     x0, #0
        mov     x2, #3                          // RW
        mov     x3, #0x22                       // PRIVATE|ANON (linux); darwin uses 0x1002, stub below adapts
        mov     x4, #-1
        mov     x5, #0
        ldr     x16, [x27, #88]
        blr     x16
        ldp     x29, x30, [sp], #16
        ret

// rt_str_cmp(x0 a, x1 b) -> -1 / 0 / 1 (bytewise, then by length; Ruby's <=>)
rt_str_cmp:
        ldur    x2, [x0, #-8]
        ldur    x3, [x1, #-8]
        cmp     x2, x3
        csel    x4, x2, x3, lo                  // n = min(len)
0:      cbz     x4, 1f
        ldrb    w5, [x0], #1
        ldrb    w6, [x1], #1
        cmp     w5, w6
        b.lo    8f
        b.hi    9f
        sub     x4, x4, #1
        b       0b
1:      cmp     x2, x3
        b.lo    8f
        b.hi    9f
        mov     x0, #0
        ret
8:      mov     x0, #-1
        ret
9:      mov     x0, #1
        ret

// rt_str_to_i(x0 s) -> integer. Ruby's String#to_i: skip leading whitespace,
// optional sign, digits (underscores allowed between digits), stop at anything else; 0 if none.
rt_str_to_i:
        ldur    x2, [x0, #-8]           // len
        mov     x3, #0                  // result
        mov     x4, #0                  // negative?
0:      cbz     x2, 9f                  // skip whitespace
        ldrb    w5, [x0]
        cmp     w5, #32
        b.eq    1f
        cmp     w5, #9
        b.lo    2f
        cmp     w5, #13
        b.hi    2f
1:      add     x0, x0, #1
        sub     x2, x2, #1
        b       0b
2:      cmp     w5, #45                 // '-'
        b.ne    3f
        mov     x4, #1
        add     x0, x0, #1
        sub     x2, x2, #1
        b       4f
3:      cmp     w5, #43                 // '+'
        b.ne    4f
        add     x0, x0, #1
        sub     x2, x2, #1
4:      cbz     x2, 8f
        ldrb    w5, [x0]
        cmp     w5, #95                 // '_' between digits
        b.eq    5f
        sub     w5, w5, #48
        cmp     w5, #9
        b.hi    8f
        mov     x6, #10
        madd    x3, x3, x6, x5
5:      add     x0, x0, #1
        sub     x2, x2, #1
        b       4b
8:      cbz     x4, 9f
        neg     x3, x3
9:      mov     x0, x3
        ret

// rt_print_str(x0 s): write without newline
rt_print_str:
        stp     x29, x30, [sp, #-16]!
        ldur    x2, [x0, #-8]
        mov     x1, x0
        mov     x0, #1
        ldr     x16, [x27]
        blr     x16
        ldp     x29, x30, [sp], #16
        ret

// rt_print_i(x0 n): decimal, no newline (via rt_itos then rt_print_str)
rt_print_i:
        stp     x29, x30, [sp, #-16]!
        bl      rt_itos
        bl      rt_print_str
        ldp     x29, x30, [sp], #16
        ret

// rt_p_str(x0 s): "s" with a newline (inspect, without escapes for now)
rt_p_str:
        stp     x29, x30, [sp, #-32]!
        str     x19, [sp, #16]
        mov     x19, x0
        mov     w3, #34
        strb    w3, [sp, #24]
        add     x1, sp, #24
        mov     x2, #1
        mov     x0, #1
        ldr     x16, [x27]
        blr     x16                     // "
        mov     x0, x19
        bl      rt_print_str            // s
        mov     w3, #34
        strb    w3, [sp, #24]
        mov     w3, #10
        strb    w3, [sp, #25]
        add     x1, sp, #24
        mov     x2, #2
        mov     x0, #1
        ldr     x16, [x27]
        blr     x16                     // "\n
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

// rt_chr(x0 byte) -> a fresh one-byte string
rt_chr:
        stp     x29, x30, [sp, #-32]!
        strb    w0, [sp, #16]
        add     x0, sp, #16
        mov     x1, #1
        bl      rt_str_new
        ldp     x29, x30, [sp], #32
        ret

// rt_raise(x0 exception): unwind to the top handler record. With no handler it
// returns, and the compiled code after it calls __uncaught (prints, exits).
// record: [link, sp, fp, x19..x26, resume]; top at [x27 + 104]
rt_raise:
        ldr     x16, [x27, #104]
        cbz     x16, 1f
        ldr     x17, [x16]
        str     x17, [x27, #104]         // pop
        ldr     x17, [x16, #8]
        mov     sp, x17
        ldr     x29, [x16, #16]
        ldp     x19, x20, [x16, #24]
        ldp     x21, x22, [x16, #40]
        ldp     x23, x24, [x16, #56]
        ldp     x25, x26, [x16, #72]
        ldr     x17, [x16, #88]          // x27 (globals) and x28 (heap bump) are process state: not restored
        br      x17
1:      ret
