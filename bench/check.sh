#!/bin/bash
# correctness: every bench against its CRuby .expected
cd "$(dirname "$0")/.."
# never leave a compiled program running behind us: generated code ignores SIGTERM
trap 'pkill -9 -P $$ 2>/dev/null' EXIT INT TERM
for f in bench/*.rb; do b=$(basename $f .rb); [ -f bench/$b.expected ] || continue
  if diff -q <(timeout -k 2 60 bin/indus $f 2>/dev/null) bench/$b.expected >/dev/null; then echo "ok   $b"; else echo "FAIL $b"; fi; done
