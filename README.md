# Indus

Ruby to metal. Experiments.

```sh
bin/indus bench/fib.rb            # compile + run in process
bin/indus bench/fib.rb -o fib            # standalone arm64 Mach-O (no linker)
bin/indus bench/fib.rb -o fib --linux    # standalone arm64 Linux ELF, 376 bytes
bench/run.sh                      # vs CRuby, YJIT, Spinel
tools/dis.sh bench/fib.rb         # disassemble
HEAP=1 bin/indus bench/sieve.rb   # report heap use; NOESCAPE=1 disables the memory tiers
test/run.sh                       # differential tests vs CRuby (test/programs/*.rb)
bench/check.sh                    # every benchmark vs its CRuby .expected
```
