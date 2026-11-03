#!/bin/bash
# head-to-head: wall-clock of the whole process, best of 5. Spinel binaries in ~/tmp/sp.
#
# Guard rails (override via env):
#   BENCH_TIMEOUT=30     wall-clock seconds per run; runaway runs are killed
#   BENCH_MEM_MB=4096    per-run address-space cap; runaway runs die instead of OOMing the Mac
#   BENCH_ONLY="fib tak" run a subset
cd "$(dirname "$0")/.."

BENCH_TIMEOUT="${BENCH_TIMEOUT:-30}"
BENCH_MEM_MB="${BENCH_MEM_MB:-4096}"

TIMEOUT_BIN="$(command -v gtimeout || command -v timeout)"
if [ -z "$TIMEOUT_BIN" ]; then
  echo "warn: no gtimeout/timeout found (brew install coreutils); running without a wall-clock cap" >&2
fi

# run CMD... capped at BENCH_TIMEOUT seconds and BENCH_MEM_MB of address space.
capped() {
  (
    ulimit -v $(( BENCH_MEM_MB * 1024 )) 2>/dev/null || ulimit -d $(( BENCH_MEM_MB * 1024 )) 2>/dev/null
    if [ -n "$TIMEOUT_BIN" ]; then
      exec "$TIMEOUT_BIN" -k 2 "$BENCH_TIMEOUT" "$@"
    else
      exec "$@"
    fi
  )
}

# best-of-5 wall clock in ms. Prints -1 if every attempt timed out / blew the cap.
best() {
  local m=999999 ok=0 i s e t rc
  for i in 1 2 3 4 5; do
    s=$(date +%s%N)
    capped "$@" >/dev/null 2>&1
    rc=$?
    e=$(date +%s%N)
    # 124/137 = timeout, >128 = killed by signal (segv, oom)
    if [ $rc -ne 0 ]; then
      echo "  ! $* -> exit $rc (run $i)" >&2
      continue
    fi
    ok=1
    t=$(( (e-s)/1000000 ))
    (( t < m )) && m=$t
  done
  (( ok )) && echo $m || echo -1
}

BENCHES="${BENCH_ONLY:-fib ackermann tak tarai nested_loop nqueens sieve matmul mandel_term object_new binary_trees nbody shapes seam str_concat str_build wordfreq template partial_sums loops_times range_each dynamic server}"

printf "%-12s %8s %8s %8s %10s %10s\n" bench cruby yjit spinel indus-proc indus-code
for b in $BENCHES; do
  c=$(best ruby --disable-gems bench/$b.rb)
  y=$(best ruby --disable-gems --yjit bench/$b.rb)
  if [ -x ~/tmp/sp/$b ]; then s="$(best ~/tmp/sp/$b)ms"; else s="refused"; fi
  i=$(best bin/indus bench/$b.rb)
  ic=$(for k in 1 2 3 4 5; do capped bin/indus bench/$b.rb 2>&1 >/dev/null | sed -n 's/.*, \(.*\) ms/\1/p'; done | sort -n | head -1)
  printf "%-12s %7sms %7sms %9s %9sms %9sms\n" $b "$c" "$y" "$s" "$i" "${ic:-n/a}"
done
