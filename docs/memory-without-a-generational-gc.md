# Memory without a generational GC

*Why Indus does not need the collector everyone assumes it needs, in the order the
reasoning actually went. Written for a conversation with someone who knows GCs well.*

## The three brackets

Every runtime frees memory one of three ways. The interesting design question is how much
work you can push leftward.

1. **Statically, from structure.** The compiler knows when a value dies and emits the
   free (or never allocates on the heap at all). Rust gets this from ownership: every value
   has one owner, dies with it, the programmer proves it to the borrow checker. Zero cost at
   run time.
2. **Dynamically, by tracing.** The runtime finds what is reachable from the roots and
   reclaims the rest. Go, Java, CRuby. The cost shape depends on the algorithm: copying is
   proportional to *live* data, mark-sweep to *all* data, and generational schemes trade a
   write barrier on every pointer store for collecting the young often and the old rarely.
3. **Statically, by proof of lifetime.** Escape analysis: the compiler proves a value does
   not outlive its function or its loop iteration and keeps it off the heap (stack object)
   or reclaims it wholesale at the loop's back edge (region). Zero cost where proven; falls
   back to bracket 2 elsewhere. The JVM does some of this; the BEAM gets the same effect
   from per-process heaps thrown away at process death; Phoenix's per-request discipline is
   the same idea done by hand.

Ruby has no ownership, so bracket 1 is not available as such. The Indus bet is that most
Ruby values have *provable lifetimes* anyway (bracket 3), and the collector only has to
handle what is genuinely shared or long-lived.

## What Indus has

- **No object headers.** A pointer is followed with the *type of the slot that holds it*
  (the collector is given the field types per class, the element type per array, the
  key/value types per hash). The collector never guesses what a word is. This is the
  opposite of a conservative collector, and it is what makes everything else cheap:
  objects are exactly their fields, an Integer is a machine word, a Float is a register.
- **A copying (Cheney) collector**, two semispaces, in ~330 lines of Ruby compiled by the
  same compiler. Cost proportional to live data. The old space is freed by swapping, not
  per object: no fragmentation, no free lists, no sweep.
- **Stack objects** (tier 0): an object that never escapes its function lives in the frame.
- **Loop regions** (tier 1): when nothing allocated in a loop iteration survives the back
  edge, the bump pointer is reset there. A per-request arena, derived rather than written.
  The `server` benchmark runs in 4 MB this way where Spinel takes 67.
- **Stable handles** for the one case that defeats "a value is where it was made": a
  container grown through a parameter gets a one-word cell, so growth is visible to every
  holder (notes/32, notes/53). Only functions that grow pay.

## Why not generational, measured

The plan was a nursery, a remembered set, and write barriers, for csv_build (400k rows
kept, 276 ms). Before building it, two measurements:

- Run csv_build with a 1 GB heap so the collector never fires: **276 -> 185 ms**. That is
  the *ceiling* of any collector change -- 90 ms on one benchmark, and zero on
  template_render and tree_walker, which allocate heavily but keep little (copying is
  already free for them).
- A pure-retention probe (400k strings kept, five collections): the collector moves data at
  **~7 GB/s**, near memcpy. A smarter collector cannot take much back from that.

Against that: a write barrier is a compare on every pointer store in every program,
forever -- paid by fib, nbody and tree_walker, which currently pay nothing for the GC at
all. The design rule is "dynamism and memory management cost only where used"; a barrier
violates it to recover at most 90 ms on one program. Not built.

## Where the time actually was

The same 1 GB run showed csv_build allocating **477 MB for 400k rows**: 1.2 KB a row for
~40 bytes of content. Not a collection problem; an *allocation rate* problem, spread over
ten small allocations per row that Ruby semantics mostly require (fresh literals in an
array, to_s, interpolations, `* 2`, gsub, the row buffer growing from empty, its cell).

Rust wins this benchmark by allocating ~100 bytes a row -- not by collecting better, by
*knowing when each temporary dies* and reusing the buffer. The Indus equivalent is the
loop region. csv_build defeats the current region rule because one value escapes each
iteration (`rows << line`). The extension -- allow named survivors, copy them out at the
back edge, reset everything else -- is compile-time ownership inference for the common loop
shape. It reaches the 185 ms floor with no runtime cost outside such loops. That is the
next memory project; the collector is not.

Two cheap fixes fell out of the measurement: a string growing from empty now starts at 32
bytes (exact fit from zero reallocated on every append: 477 -> 429 MB), and gsub with a
string pattern sizes its result once instead of concatenating per match.

## Honest limitations, for the committer conversation

- **Pauses are proportional to live data.** No concurrent or incremental collection,
  because there is no barrier. A 500 MB live set means tens of milliseconds per collection.
  For a long-running server with a large resident set this is the real cost of the design,
  and the honest answer is: regions keep most request work out of the heap entirely, so
  the live set is the genuinely long-lived state, and collections are rare -- but when one
  runs, it runs over all of it.
- **Memory is not returned to the OS** when the live set shrinks: the abandoned semispace
  stays mapped. RSS tracks the high-water mark. Fixable (munmap on shrink), not done.
- **Semispaces mean 2x address space** for the live set. Address space, not RSS: pages are
  touched only as they are used.
- **Large live sets double the space on growth** (a quarter-full-after-collection rule);
  a run that grows its live set steadily pays log(n) extra copies. Measured on csv_build:
  28 collections, and growing faster cost RSS for nothing.
- **Typed slots need whole-program types.** Code compiled later (a seam) must agree with
  the layouts already chosen; a class whose layout changes at run time is the world-age
  problem (notes/37), still parked.

## How this compares

| | CRuby | Spinel | Go | Rust | Indus |
|---|---|---|---|---|---|
| value representation | tagged VALUE + 40 B RVALUE | 16 B box + 48 B header | typed, unboxed | typed, unboxed | typed, unboxed, 1-word tag only where polymorphic |
| collector | mark-sweep + compaction, incremental | mark-sweep | concurrent mark-sweep, barrier | none (ownership) | copying, typed slots, no barrier |
| cost scales with | all objects | all objects | all objects + barrier | 0 | live objects only |
| short-lived work | heap | heap | heap (some escape analysis) | stack/arena by ownership | stack objects + loop regions, proved |
| csv_build-shaped code | — | 410 ms | — | ~100 B/row | 262 ms, 185 floor without regions-with-survivors |

The one-sentence version: *Spinel and CRuby pay per object, Go pays per store, Rust makes
the programmer pay, Indus pays per live object and only where a lifetime cannot be
proved.*

## What I would ask a Ruby core committer

- How much of CRuby's object header is load-bearing for semantics (frozen, object_id,
  singleton class, flags) versus for the collector? Indus has none of it and has not
  needed `object_id` or `freeze` in 240 oracle programs; `frozen?` is the one thing it
  cannot answer truthfully.
- Variable Width Allocation moved CRuby towards "objects are their fields"; is there
  appetite for the typed-slot idea (the collector told the field types) in CRuby's GC, or
  does the C extension API make that impossible?
- The YJIT view of escape analysis: how much of a typical Rails request's allocation is
  provably request-local? If it is most of it, regions beat a better collector there too.

*Numbers from 2026-11-05/06; see indus notes/64, bench/REPORT.md.*
