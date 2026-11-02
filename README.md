# Indus

Indus is an experiment in finding a more direct path from Ruby to machine code.

The ambition is simple: push Ruby performance as far as it will go. The
method is to question every piece of work along the way — what must happen
at runtime, what can happen earlier, and what can disappear entirely.

```
Ruby source  →  SSA  →  arm64
```

No C, no LLVM, no assembler, no linker, no runtime library. The compiler is
written in Ruby and produces standalone executables for macOS and Linux.

Named after the Indus Valley: source, flow, execution.

## Try it

```sh
bin/indus bench/fib.rb                   # compile and run in-process
bin/indus bench/fib.rb -o fib --linux    # a standalone ELF executable
bench/run.sh                             # against CRuby, YJIT and Spinel
test/run.sh                              # differential tests vs CRuby
```

Early days. Expect the subset of Ruby it accepts to grow experiment by
experiment; `tools/census.rb file.rb` shows what a program uses that Indus
doesn't yet.
