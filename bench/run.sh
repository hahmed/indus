#!/bin/bash
# head-to-head: wall-clock of the whole process, best of 5. Spinel binaries in ~/tmp/sp.
cd "$(dirname "$0")/.."
best() { local m=999999; for i in 1 2 3 4 5; do s=$(date +%s%N); "$@" >/dev/null 2>&1; e=$(date +%s%N); t=$(( (e-s)/1000000 )); (( t < m )) && m=$t; done; echo $m; }
printf "%-12s %8s %8s %8s %10s %10s\n" bench cruby yjit spinel indus-proc indus-code
for b in fib ackermann tak tarai nested_loop nqueens sieve matmul mandel_term object_new binary_trees nbody shapes seam str_concat str_build wordfreq template partial_sums; do
  c=$(best ruby --disable-gems bench/$b.rb)
  y=$(best ruby --disable-gems --yjit bench/$b.rb)
  s=$(best ~/tmp/sp/$b)
  i=$(best bin/indus bench/$b.rb)
  ic=$(for k in 1 2 3 4 5; do bin/indus bench/$b.rb 2>&1 >/dev/null | sed -n 's/.*, \(.*\) ms/\1/p'; done | sort -n | head -1)
  printf "%-12s %7dms %7dms %7dms %9dms %9sms\n" $b $c $y $s $i $ic
done
