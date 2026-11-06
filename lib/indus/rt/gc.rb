# The collector, written in the Indus subset and compiled into GC-mode programs.
# Copying (Cheney) over two semispaces. Objects have no headers: a pointer is
# followed with the type id of the slot that held it (lib/indus/gc.rb).
#
# Intrinsics (lowered by the compiler, not methods):
#   __ld(a) / __ld32(a) / __st(a, v)   raw memory
#   __gbase                           x27 (globals)
#   __adr_tables / __adr_text         addresses of __gc_tables / __text_base
#
# Globals (byte offsets from __gbase): 8 limit, 16 from, 24 from_end,
# 32 to, 40 to_end, 48 bitmap, 56 worklist, 64 count, 72/80 scratch,
# 88 mmap fn, 96 chain of seam-compiled units' tables.
# Table layout: [ntypewords, types..., nframes, frames..., nglobals, globals...]
# (32-bit words). types: [count, off_0.., descriptors]; a descriptor is
#   [0]  STR       [1, elem_tid]  ARR       [2, k_tid, v_tid]  HASH
#   [3, size, nfields, (off, tid)...]  OBJ      [4, npairs, (class_id, tid)...]  POLY

def __gc_run(fp)
  g = __gbase
  from = __ld(g + 16)
  from_end = __ld(g + 24)
  to = __ld(g + 32)
  work = __ld(g + 56)
  bitmap = __ld(g + 48)
  tables = __adr_tables
  text = __adr_text
  # the pair must match: after a growth the other space is still the old size
  if __ld(g + 40) - to < from_end - from
    to = __mmap(from_end - from)
    __st(g + 32, to)
    __st(g + 40, to + (from_end - from))
  end

  # clear the forwarding bitmap: one bit per 16 bytes of from-space
  nbytes = (from_end - from) / 128 + 8
  i = 0
  while i < nbytes
    __st(bitmap + i, 0)
    i = i + 8
  end

  free = to          # to-space bump
  wtop = work        # worklist: [ptr, tid] pairs, 16 bytes each

  ntw = __ld32(tables)
  types = tables + 4
  frames = types + ntw * 4
  nframes = __ld32(frames)
  globals = frames + 4
  k = 0
  while k < nframes
    ns = __ld32(globals + 8)
    globals = globals + 12 + ns * 8
    k = k + 1
  end
  nglobals = __ld32(globals)
  globals = globals + 4

  # ---- roots: globals
  k = 0
  while k < nglobals
    off = __ld32(globals + k * 8)
    tid = __ld32(globals + k * 8 + 4)
    r = __gc_forward(g + off, tid, from, from_end, free, wtop, bitmap, types)
    free = __ld(g + 72)
    wtop = __ld(g + 80)
    k = k + 1
  end

  # ---- roots: frames. The return address saved in frame F points into the
  # function that owns F's parent; scan the parent's slots with that function's map.
  child = fp
  while child != 0
    ret = __ld(child + 8) - text
    parent = __ld(child)
    if parent == 0
      child = 0
    else
      fe = frames + 4
      f = 0
      found = 0
      while f < nframes
        cs = __ld32(fe)
        ce = __ld32(fe + 4)
        ns = __ld32(fe + 8)
        if found == 0 && ret >= cs && ret < ce
          found = 1
          s = 0
          while s < ns
            so = __ld32(fe + 12 + s * 8)
            tid = __ld32(fe + 16 + s * 8)
            __gc_forward(parent + so, tid, from, from_end, free, wtop, bitmap, types)
            free = __ld(g + 72)
            wtop = __ld(g + 80)
            s = s + 1
          end
        end
        fe = fe + 12 + ns * 8
        f = f + 1
      end
      # not in the static table: try code compiled later through a seam.
      # Each extra record: [next, text_base, tables] with its own types/frames.
      extra = __ld(g + 96)
      while extra != 0 && found == 0
        xtext = __ld(extra + 8)
        xtables = __ld(extra + 16)
        xret = __ld(child + 8) - xtext
        xntw = __ld32(xtables)
        xtypes = xtables + 4
        xframes = xtypes + xntw * 4
        xn = __ld32(xframes)
        fe = xframes + 4
        f = 0
        while f < xn
          cs = __ld32(fe)
          ce = __ld32(fe + 4)
          ns = __ld32(fe + 8)
          if found == 0 && xret >= cs && xret < ce
            found = 1
            s = 0
            while s < ns
              so = __ld32(fe + 12 + s * 8)
              tid = __ld32(fe + 16 + s * 8)
              __gc_forward(parent + so, tid, from, from_end, free, wtop, bitmap, xtypes)
              free = __ld(g + 72)
              wtop = __ld(g + 80)
              s = s + 1
            end
          end
          fe = fe + 12 + ns * 8
          f = f + 1
        end
        extra = __ld(extra)
      end
      # a frame whose return address is outside our code belongs to the host: stop
      child = found == 0 ? 0 : parent
    end
  end

  # ---- drain the worklist: scan copied objects' pointer fields
  while wtop > work
    wtop = wtop - 16
    obj = __ld(wtop)
    tid = __ld(wtop + 8)
    __st(g + 72, free)
    __st(g + 80, wtop)
    __gc_scan(obj, tid, from, from_end, bitmap, types)
    free = __ld(g + 72)
    wtop = __ld(g + 80)
  end

  # ---- swap spaces; the caller continues bumping in to-space
  to_end = __ld(g + 40)
  __st(g + 16, to)
  __st(g + 24, to_end)
  live = free - to
  cap = to_end - to
  if live * 2 > cap
    # more than half full after collecting: the next to-space is twice the size.
    # Hard cap (1 GB per semispace): past it, fail noisily rather than eat the machine.
    __trap if cap >= 1073741824
    # (the old from-space is abandoned; the bitmap must cover the new from-space
    # at the collection after next, so size it for the bigger space now)
    ncap = cap * 4 # a live set this big is growing: four times fewer collections of it
    nto = __mmap(ncap)
    __st(g + 32, nto)
    __st(g + 40, nto + ncap)
    __st(g + 48, __mmap(ncap / 128 + 4096))
  else
    __st(g + 32, from)
    __st(g + 40, from_end)
  end
  __st(g + 8, to_end - 1048576)
  __st(g + 64, __ld(g + 64) + 1)
  free
end

# size in bytes of the object at p (handle), by descriptor kind
def __gc_size(p, desc, types)
  kind = __ld32(desc)
  if kind == 0
    16 + __ld(p - 16)
  elsif kind == 1
    16 + __ld(p - 16) * 8
  elsif kind == 2
    16 + __ld(p - 16) * 24
  elsif kind == 3
    __ld32(desc + 4)
  else
    # poly: the tag in word 0 names the class
    tag = __ld(p)
    np = __ld32(desc + 4)
    n = 0
    size = 8
    while n < np
      cid = __ld32(desc + 8 + n * 8)
      if cid == tag
        size = __ld32(__gc_desc(types, __ld32(desc + 12 + n * 8)) + 4)
        n = np
      end
      n = n + 1
    end
    size
  end
end

def __gc_desc(types, tid)
  types + __ld32(types + 4 + tid * 4) * 4
end

# forward the pointer in slot `slot` (typed tid): copy its object to to-space
# if it is in from-space and not yet copied; update the slot. Communicates
# free / wtop through globals 72 / 80 (the subset has no multiple returns).
def __gc_forward(slot, tid, from, from_end, free, wtop, bitmap, types)
  g = __gbase
  p = __ld(slot)
  if p == 0
    __st(g + 72, free)
    __st(g + 80, wtop)
    return 0
  end
  desc0 = __gc_desc(types, tid)
  if __ld32(desc0) == 5
    # a tagged scalar: nil/fixnum/bool/symbol hold no pointer; otherwise strip
    # the tag, forward the bare handle through its real descriptor, re-tag.
    tag = p & 15
    if (tag & 1) == 1 || tag == 10 || tag == 12
      __st(g + 72, free)
      __st(g + 80, wtop)
      return 0
    end
    ctid = -1
    if tag == 2
      ctid = __ld32(desc0 + 4)
    elsif tag == 4
      ctid = __ld32(desc0 + 8)
    elsif tag == 6
      ctid = __ld32(desc0 + 12)
    elsif tag == 14
      ctid = __ld32(desc0 + 16)
    else
      # an object: word 0 is its class id -- unless it was already copied this collection,
      # in which case word 0 is the forwarding pointer; the bitmap says which
      base = p - tag
      if base >= from && base < from_end
        bit = (base - from) / 16
        if (__ld(bitmap + bit / 64 * 8) & (1 << (bit % 64))) != 0
          __st(slot, __ld(base) + tag)
          __st(g + 72, free)
          __st(g + 80, wtop)
          return 0
        end
      end
      cid = __ld(base)
      np = __ld32(desc0 + 20)
      n = 0
      while n < np
        if __ld32(desc0 + 24 + n * 8) == cid
          ctid = __ld32(desc0 + 28 + n * 8)
          n = np
        end
        n = n + 1
      end
    end
    __trap if ctid < 0
    __st(slot, p - tag)
    __gc_forward(slot, ctid, from, from_end, free, wtop, bitmap, types)
    __st(slot, __ld(slot) + tag)
    return 0
  end
  if p < from || p >= from_end
    __st(g + 72, free)
    __st(g + 80, wtop)
    # keeping a region survivor (__gc_keep): the region is the from-space; anything outside it is old
    return 0 if __ld(g + 120) != 0
    if p >= __ld(g + 32) && p < __ld(g + 40)
      # a pointer into to-space is either already updated this collection (an
      # in-place object reached twice: a stack object held by two frames) or a
      # stale address in a dead slot. In both cases: leave it, never follow it.
      return 0
    end
    # outside both spaces: a stack object or a large object. Scan in place.
    __gc_scan(p, tid, from, from_end, bitmap, types)
    return 0
  end
  desc = __gc_desc(types, tid)
  kind = __ld32(desc)
  # handles of strings/arrays/hashes point 16 bytes past their header
  base = kind <= 2 ? p - 16 : p
  bit = (base - from) / 16
  word = bitmap + bit / 64 * 8
  mask = 1 << (bit % 64)
  if (__ld(word) & mask) != 0
    # already copied: word 0 of the old object holds the new handle
    __st(slot, __ld(base))
    __st(g + 72, free)
    __st(g + 80, wtop)
    return 0
  end
  size = __gc_size(p, desc, types)
  total = (size + 15) / 16 * 16
  # copy base..base+total to free
  i = 0
  while i < total
    __st(free + i, __ld(base + i))
    i = i + 8
  end
  newp = kind <= 2 ? free + 16 : free
  free = free + total
  __st(base, newp)
  __st(word, __ld(word) | mask)
  __st(slot, newp)
  __st(wtop, newp)
  __st(wtop + 8, tid)
  wtop = wtop + 16
  __st(g + 72, free)
  __st(g + 80, wtop)
  0
end

# scan the pointer fields of obj (already in to-space, or a stack object)
def __gc_scan(obj, tid, from, from_end, bitmap, types)
  g = __gbase
  desc = __gc_desc(types, tid)
  kind = __ld32(desc)
  if kind == 1
    etid = __ld32(desc + 4)
    if etid >= 0 && etid < 1000000
      n = __ld(obj - 8)
      i = 0
      while i < n
        __gc_forward(obj + i * 8, etid, from, from_end, __ld(g + 72), __ld(g + 80), bitmap, types)
        i = i + 1
      end
    end
  elsif kind == 2
    ktid = __ld32(desc + 4)
    vtid = __ld32(desc + 8)
    cap = __ld(obj - 16)
    i = 0
    while i < cap
      if __ld(obj + i * 16) != 0
        if ktid >= 0 && ktid < 1000000
          __gc_forward(obj + i * 16, ktid, from, from_end, __ld(g + 72), __ld(g + 80), bitmap, types)
        end
        if vtid >= 0 && vtid < 1000000
          __gc_forward(obj + i * 16 + 8, vtid, from, from_end, __ld(g + 72), __ld(g + 80), bitmap, types)
        end
      end
      i = i + 1
    end
  elsif kind == 3
    nf = __ld32(desc + 8)
    i = 0
    while i < nf
      off = __ld32(desc + 12 + i * 8)
      ftid = __ld32(desc + 16 + i * 8)
      __gc_forward(obj + off, ftid, from, from_end, __ld(g + 72), __ld(g + 80), bitmap, types)
      i = i + 1
    end
  elsif kind == 4
    tag = __ld(obj)
    np = __ld32(desc + 4)
    n = 0
    while n < np
      cid = __ld32(desc + 8 + n * 8)
      if cid == tag
        __gc_scan(obj, __ld32(desc + 12 + n * 8), from, from_end, bitmap, types)
        n = np
      end
      n = n + 1
    end
  end
  0
end

# Keep one loop-region survivor (lib/indus/escape.rb, notes/65). The object in *slot and
# everything it owns inside the region [mark, top) are copied, packed, to `cursor`; the
# slot and the copied pointers are rewritten; returns the cursor after the copies. The
# idle to-space is the scratch area: a Cheney pass with the region as from-space, then one
# block move down. Nothing else points into the region (the compiler proved it), so the
# region's own words are free to hold forwarding pointers.
def __gc_keep(slot, tid, mark, cursor, top)
  g = __gbase
  return cursor if slot == 0
  p = __ld(slot)
  return cursor if p == 0
  to = __ld(g + 32)
  bitmap = __ld(g + 48)
  work = __ld(g + 56)
  types = __adr_tables + 4
  nbytes = (top - mark) / 128 + 8
  i = 0
  while i < nbytes
    __st(bitmap + i, 0)
    i = i + 8
  end
  __st(g + 120, 1)
  __gc_forward(slot, tid, mark, top, to, work, bitmap, types)
  free = __ld(g + 72)
  wtop = __ld(g + 80)
  while wtop > work
    wtop = wtop - 16
    obj = __ld(wtop)
    otid = __ld(wtop + 8)
    __st(g + 72, free)
    __st(g + 80, wtop)
    __gc_scan(obj, otid, mark, top, bitmap, types)
    free = __ld(g + 72)
    wtop = __ld(g + 80)
  end
  __st(g + 120, 0)
  # pointers into the scratch block become pointers into the final block
  __gc_reloc(slot, tid, to, free, cursor - to, types)
  len = free - to
  i = 0
  while i < len
    __st(cursor + i, __ld(to + i))
    i = i + 8
  end
  cursor + len
end

# shift every pointer in the copied subgraph that points into [to, free) by delta.
# A pointer already shifted lies outside that range, so sharing and cycles stop here.
def __gc_reloc(slot, tid, to, free, delta, types)
  p = __ld(slot)
  return 0 if p == 0
  desc = __gc_desc(types, tid)
  kind = __ld32(desc)
  tag = 0
  if kind == 5
    tag = p & 15
    return 0 if (tag & 1) == 1 || tag == 10 || tag == 12 || tag == 0
    p = p - tag
    if tag == 2
      tid = __ld32(desc + 4)
    elsif tag == 4
      tid = __ld32(desc + 8)
    elsif tag == 6
      tid = __ld32(desc + 12)
    elsif tag == 14
      tid = __ld32(desc + 16)
    else
      cid = __ld(p)
      np = __ld32(desc + 20)
      n = 0
      tid = -1
      while n < np
        if __ld32(desc + 24 + n * 8) == cid
          tid = __ld32(desc + 28 + n * 8)
          n = np
        end
        n = n + 1
      end
      return 0 if tid < 0
    end
    desc = __gc_desc(types, tid)
    kind = __ld32(desc)
  end
  return 0 if p < to || p >= free
  __st(slot, p + delta + tag)
  if kind == 1
    etid = __ld32(desc + 4)
    if etid >= 0 && etid < 1000000
      n = __ld(p - 8)
      i = 0
      while i < n
        __gc_reloc(p + i * 8, etid, to, free, delta, types)
        i = i + 1
      end
    end
  elsif kind == 2
    ktid = __ld32(desc + 4)
    vtid = __ld32(desc + 8)
    cap = __ld(p - 16)
    i = 0
    while i < cap
      if __ld(p + i * 16) != 0
        __gc_reloc(p + i * 16, ktid, to, free, delta, types) if ktid >= 0 && ktid < 1000000
        __gc_reloc(p + i * 16 + 8, vtid, to, free, delta, types) if vtid >= 0 && vtid < 1000000
      end
      i = i + 1
    end
  elsif kind == 3
    nf = __ld32(desc + 8)
    i = 0
    while i < nf
      __gc_reloc(p + __ld32(desc + 12 + i * 8), __ld32(desc + 16 + i * 8), to, free, delta, types)
      i = i + 1
    end
  elsif kind == 4
    ctag = __ld(p)
    np = __ld32(desc + 4)
    n = 0
    while n < np
      if __ld32(desc + 8 + n * 8) == ctag
        __st(slot, p) # scan as the concrete class, then re-shift once
        __gc_reloc(slot, __ld32(desc + 12 + n * 8), to, free, delta, types)
        n = np
      end
      n = n + 1
    end
  end
  0
end
