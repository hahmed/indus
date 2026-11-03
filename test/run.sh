#!/bin/bash
# Differential tests: every test/programs/*.rb must print exactly what CRuby prints.
# Add a program; the expectation is CRuby, generated on the fly.
cd "$(dirname "$0")/.."
# never leave a compiled program running behind us: generated code ignores SIGTERM
trap 'pkill -9 -P $$ 2>/dev/null' EXIT INT TERM
pass=0; fail=0
for f in test/programs/*.rb; do
  want=$(ruby --disable-gems "$f" 2>&1); got=$(timeout -k 2 20 bin/indus "$f" 2>/dev/null)
  if [ "$want" == "$got" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $f"; diff <(echo "$want") <(echo "$got") | head -6; fi
  # and under the collector with tiny semispaces, so it actually runs
  got=$(INDUS_HEAP_MB=2 timeout -k 2 20 bin/indus "$f" 2>/dev/null)
  if [ "$want" == "$got" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $f (gc)"; diff <(echo "$want") <(echo "$got") | head -6; fi
done
echo "$pass passed, $fail failed"
