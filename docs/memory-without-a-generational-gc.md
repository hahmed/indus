# Memory without a generational GC

Decision: Indus does not get a generational collector. Measured 2026-11-06.

## Three ways to free memory

1. **Static, from structure.** Rust: one owner per value, freed when the owner dies.
   Zero runtime cost. Ruby has no ownership, so this is not available.
2. **Tracing GC.** Copying costs ∝ live data. Mark-sweep costs ∝ all data.
   Generational adds a write barrier on every pointer store to collect young objects
   often and old ones rarely.
3. **Escape analysis.** The compiler proves a value dies before its function or loop
   iteration ends. Stack object, or reset the bump pointer at the back edge. Zero cost
   where proven, GC elsewhere.

Indus: 3 where provable, 2 for the rest.

## What Indus has

- No object headers. The collector is told the type of every slot (field types per class,
  element type per array, key/value per hash). Never guesses what a word is.
- Copying collector, two semispaces, ~330 lines of Ruby. Cost ∝ live data. Old space
  freed by one swap. No fragmentation, no sweep.
- Stack objects: an object that never escapes its function lives in the frame.
- Loop regions: if nothing allocated in an iteration survives the back edge, the bump
  pointer resets there. `server` benchmark runs in 4 MB; Spinel 67 MB.
- Cells for containers grown through a parameter ([notes/32](https://github.com/hahmed/indus/blob/main/docs/notes/32_stable_handles.md), [notes/53](https://github.com/hahmed/indus/blob/main/docs/notes/53_array_cells.md)).

## The measurement

csv_build keeps 400k rows. 276 ms.

- 1 GB heap, collector never runs: **185 ms**. Ceiling of any GC change: 90 ms, one
  benchmark. template_render, tree_walker: 0 gain.
- 400k strings kept, 5 collections: collector moves ~7 GB/s. Near memcpy.
- Cost of generational: a compare on every pointer store, in every program. fib, nbody,
  tree_walker pay 0 for GC today.

Not built.

## Where the time is

Same 1 GB run: csv_build allocates **477 MB** for 400k rows. 1.2 KB per row, ~40 bytes of
content. Ten small allocations per row, most required by Ruby semantics (`"a" + "b"`
makes a new string).

Rust: ~100 bytes per row. Not better collection; knows when temporaries die, reuses the
buffer.

Indus equivalent: loop regions. csv_build defeats the current rule because `rows << line`
escapes. Extension: allow named survivors, copy them out at the back edge, reset the rest.
Reaches 185 ms. No runtime cost elsewhere. Next memory project.

Fixed from the same measurement:
- strings growing from empty start at 32 bytes (was exact fit from 0, realloc every
  append): 477 → 429 MB.
- gsub(string) sizes result once (was concatenating per match, 260 B garbage per call).
- csv_build 276 → 262 ms.

## Limitations

- Pauses ∝ live set. No barrier → no concurrent/incremental collection. 500 MB live set:
  tens of ms per collection.
- Memory not returned to OS on shrink. RSS tracks high-water mark. Fixable (munmap).
- Semispaces: 2× address space for the live set. Address space, not RSS.
- Typed slots need whole-program types. Runtime class-layout change = world-age problem
  ([notes/37](https://github.com/hahmed/indus/blob/main/docs/notes/37_prior_art_cruby.md)), parked.
- No finalizers, ObjectSpace, WeakRef. No headers → cannot enumerate objects.
- No `frozen?` bit, no `object_id`, no singleton methods.

## Strengths to name

- Precise roots (typed homes per safepoint). CRuby scans the C stack conservatively,
  cannot move most objects, compacts partially. Indus moves everything.
- Bump allocation: 3 instructions. Rust's Box goes through malloc size classes. Part of
  binary_trees 1.0 ms vs Rust 2.5.
- CRuby's Variable Width Allocation (3.2+) already moves toward "objects are their
  fields". Typed slots are the end of that road.

## Comparison

| | CRuby | Spinel | Go | Rust | Indus |
|---|---|---|---|---|---|
| value | tagged VALUE + 40 B RVALUE | 16 B box + 48 B header | typed | typed | typed, 1-word tag only where polymorphic |
| collector | mark-sweep, incremental | mark-sweep | concurrent mark-sweep + barrier | none | copying, typed slots, no barrier |
| cost ∝ | all objects | all objects | all objects + barrier | 0 | live objects |
| short-lived work | heap | heap | heap, some escape analysis | stack by ownership | stack objects + regions, proved |

One sentence: Spinel and CRuby pay per object, Go pays per store, Rust makes the
programmer pay, Indus pays per live object and only where a lifetime cannot be proved.

## Where Rust stays ahead

Allocation volume forced by Ruby semantics. Compute: parity (fib 14.5 vs 14.8). Memory
traffic: often ahead (binary_trees 1.0 vs 2.5). Allocation: behind by exactly what the
compiler cannot prove away. A Ruby that allocates like Rust is not Ruby.

## Spinel vs Indus

Different question, not different ability. Spinel: a compiler the Ruby community can own
in C for twenty years, close to full Ruby. Every conservative choice serves that. Indus:
an experiment on how much of Ruby's cost is representation. Allowed to refuse programs,
whole-program, written in Ruby. Experiments beat products on benchmarks; that is their
job. What Indus has is findings. The ask to a committer: which of these survives contact
with full Ruby?

## Questions for a core committer

- How much of CRuby's object header is semantics (frozen, object_id, singleton) vs
  collector? Indus has none; 238 oracle programs have not needed object_id or freeze.
- Is there appetite for typed slots in CRuby's GC, or does the C extension API prevent it?
- How much of a Rails request's allocation is provably request-local? If most, regions
  beat a better collector.

*Numbers: indus [notes/64](https://github.com/hahmed/indus/blob/main/docs/notes/64_generational_gc_not_needed.md), bench/REPORT.md.*
