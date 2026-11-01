# Indus

Ruby to metal. Experiments.

```sh
bin/indus bench/fib.rb            # compile + run in process
bin/indus bench/fib.rb -o fib     # write a standalone arm64 Mach-O (no linker)
bench/run.sh                      # vs CRuby, YJIT, Spinel
```
