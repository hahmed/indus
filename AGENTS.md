# Indus — session brief (loaded automatically; keep it short and current)

Indus is an experimental Ruby → SSA → arm64 compiler written in Ruby. No C, no LLVM, no
assembler or linker in the user program's path. Thesis proven: Ruby at Rust speed where
lifetimes and types are provable (7 of 8 shared benchmarks faster than Rust, 8 of 8 than Go,
everything measured faster than Spinel). Now in the breadth phase: make ordinary Ruby
compile without giving the speed back.

## Read first, in this order
1. `~/src/github.com/Shopify/second-brain/my-notes/Resources/Ruby-Native-Performance/What-We-Learned.md`
   — the design and every lesson, cumulative.
2. `.../Memory-Without-A-Generational-GC.md` — the memory story and its honest limits.
3. `.../Two-Days-Of-Breadth-Log.md` — recent commits annotated with their numbers.
4. `~/src/github.com/Shopify/second-brain/my-notes/Resources/Unix-Philosophy.md` — how the
   user wants code and prose: parsimony, separation, repair (fail noisily; never return a
   value that means something else), clarity, measure before tuning.
5. `notes/` in this repo (git-ignored): one file per experiment, numbered. `notes/64` is the
   latest. Read the last three before touching the compiler.

## Design rules that are not negotiable
- Correctness over refusal over wrong answer. The reference is CRuby: every test is a program and its CRuby output.
- Zero runtime boxes; objects are their fields; the collector is told the type of every
  slot (no headers, no conservative scanning). Dynamism (`:dyn` tags, cells, handler
  records, closures as objects) costs only where used.
- Irreversible by-type rewrites wait for the settled round; a rewrite on a provisional type
  is a silent wrong answer. Record what each assumed (`Inst#assumed`).
- Dead code is still typed: give `raise` a bottom type, cut folded branches at once, choose
  prelude variants at the type level, never with runtime tests in prelude code.
- Prelude Ruby: host-test under CRuby first; never rebind a parameter to its unboxed self;
  never grow a container through a parameter inside a helper; tables are computed, not
  literal (literals land in main's frame).
- Measure the ceiling before building the thing (the 1 GB heap run cancelled the
  generational GC). A pass that pays nothing is deleted with its finding written down.

## Before every commit
```
test/check                    # test/programs, plain + INDUS_HEAP_MB=2
test/check bench/*.rb         # the 78 benchmarks the same way
bench/quick                   # fib / binary_trees / tree_walker timings
```
Never commit a lower pass count or a timing up more than 5%. `test/fuzz 100 --seed N`
after any change to type decisions. `test/standalone` needs `podman machine start`.
Commit messages: what changed and the number; no "N of M done".

## Memory discipline (the machine is shared)
One program per command; `timeout -k 2 N`; `pgrep -fl 'bin/indus'` after a batch;
`trap 'pkill -9 -P $$' EXIT` in scripts. Use codemode to run independent checks in parallel.

## Where things are
`lib/indus/{lower,types,escape,ranges,regalloc,codegen,asm}.rb` compiler ·
`lib/indus/rt/*.rb` the runtime, in Ruby, compiled into every program · `test/programs/`
programs with CRuby as truth · `test/host/` prelude tests under CRuby · `test/fuzz` ·
`bench/` + `bench/REPORT.md` · `tools/{dis,sieve,census}` · `DUMP=1` prints IR,
`HEAP=1` prints collector stats, `INDUS_HEAP_MB=n` sets the semispace.

## The ordered list (next work)
1. Loop regions with named survivors (escape.rb tier 1): csv_build 262 → ~185 ms floor.
2. Probe rounds (three realistic programs, diff, fix) and `test/fuzz` — still finding one
   or two real bugs per round at falling cost.
3. Codegen: expand div/mod-by-constant into IR so invariants hoist; coalesce phi copies.
4. World-age / OSR (parked; the only item that could still change the design).
Open known gaps: `frozen?`/`freeze` have no bit; singleton methods and `extend` on an
instance refuse; no finalizers/ObjectSpace/WeakRef by design; pauses ∝ live set (no
barrier); memory not returned to the OS on shrink.
