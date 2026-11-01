#!/bin/bash
# correctness: every bench against its CRuby .expected
cd "$(dirname "$0")/.."
for f in bench/*.rb; do b=$(basename $f .rb); [ -f bench/$b.expected ] || continue
  if diff -q <(bin/indus $f 2>/dev/null) bench/$b.expected >/dev/null; then echo "ok   $b"; else echo "FAIL $b"; fi; done
