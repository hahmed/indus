#!/bin/bash
# What stops Indus from compiling each program? One line per program, then the
# refusals ranked by how many programs they block. Drives library/syntax work.
#   tools/triage.sh file.rb ...
cd "$(dirname "$0")/.."
for f in "$@"; do
  msg=$(timeout -k 2 60 bin/indus "$f" --check 2>&1 >/dev/null | head -1 | sed 's/^indus: //; s/ (RuntimeError)$//; s/ (NoMethodError)$//')
  [ -z "$msg" ] && msg="OK"
  printf "%-28s %s\n" "$(basename "$f" .rb)" "$msg"
done | tee /tmp/triage.txt
echo
echo "-- refusals ranked (construct, programs blocked):"
grep -v ' OK$' /tmp/triage.txt | cut -c30- | sed -E 's/#[0-9]+//g; s/v[0-9]+//g; s/[0-9]+//g' | sort | uniq -c | sort -rn | head -20
