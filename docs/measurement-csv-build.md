# Generational GC: measured, and not the answer

The plan was a nursery + remembered set + write barriers for csv_build's retained rows.
Measured first, with a 1 GB heap so no collection ever runs: csv_build 276 -> 185 ms.
That is the whole ceiling of any collector change -- 90 ms on one benchmark, zero on
template_render and tree_walker -- against a write barrier on every pointer store in every
program. A pure-retention probe (400k strings kept, 5 collections) put the collector at
~7 GB/s: it is already near memcpy. Not built.

What csv_build actually is: 477 MB allocated for 400k rows, 1.2 KB a row for ~40 bytes of
content, spread over ten small allocations that are each "reasonable" (fresh literals in
the fields array, to_s, two interpolations, `* 2`, gsub's rebuild, the +"" line growing from
nothing, the cell). Ruby semantics make most of them real.

Done this morning, each measured:
- a string that grows from capacity 0 starts at 32 bytes (exact fit from 0 reallocated on
  every append): 477 -> 429 MB.
- gsub with a string pattern counts matches, sizes the result once, writes it once (it was
  concatenating per match: 260 bytes of garbage a call; the no-match case is a copy).
- the attempt to grow the semispace to 8x the live set: 276 -> 266 but RSS 336 -> 506 MB.
  Reverted; the x4 rule stays.
csv_build 276 -> 262 ms. The remaining 80 ms over the zero-GC run is allocation rate, and
the lever for that is finer loop regions: let an iteration's region reset when only named
values survive it (copy them out at the back edge), instead of refusing the region because
`rows << line` escapes. That is a real escape-analysis extension, a day, with csv_build's
185 ms as the number it would reach.
