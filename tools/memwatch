#!/usr/bin/env bash
# Watch memory growth and hard-kill runaway children before jetsam kills Terminal.
#
#   tools/memwatch.sh            # watch ruby/indus, cap 4 GB RSS
#   LIMIT_MB=2000 PATTERN=ruby tools/memwatch.sh
#
set -uo pipefail

PATTERN="${PATTERN:-ruby|indus}"
LIMIT_MB="${LIMIT_MB:-4096}"
INTERVAL="${INTERVAL:-1}"
LOG="${LOG:-/tmp/memwatch-$(date +%Y%m%d-%H%M%S).log}"

echo "watching /$PATTERN/  limit=${LIMIT_MB}MB  log=$LOG"
printf '%-8s %-7s %-9s %-9s %-6s %s\n' TIME PID RSS_MB VSZ_MB FREE% CMD | tee "$LOG"

while :; do
  free_pct=$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/{print $2}')

  ps -axo pid=,rss=,vsz=,comm=,args= |
  grep -E "$PATTERN" | grep -v memwatch | grep -v grep |
  while read -r pid rss vsz comm args; do
    rss_mb=$(( rss / 1024 ))
    vsz_mb=$(( vsz / 1024 ))
    [ "$rss_mb" -lt 100 ] && continue
    printf '%-8s %-7s %-9s %-9s %-6s %s\n' \
      "$(date +%H:%M:%S)" "$pid" "$rss_mb" "$vsz_mb" "${free_pct:-?}" "${args:0:70}" | tee -a "$LOG"

    if [ "$rss_mb" -gt "$LIMIT_MB" ]; then
      echo ">>> KILLING $pid (${rss_mb}MB > ${LIMIT_MB}MB): $args" | tee -a "$LOG"
      # snapshot before killing so you can see WHERE it allocated
      sample "$pid" 2 -file "/tmp/memwatch-sample-$pid.txt" 2>/dev/null
      vmmap --summary "$pid" > "/tmp/memwatch-vmmap-$pid.txt" 2>/dev/null
      kill -9 "$pid"
      echo ">>> sample: /tmp/memwatch-sample-$pid.txt  vmmap: /tmp/memwatch-vmmap-$pid.txt" | tee -a "$LOG"
    fi
  done

  sleep "$INTERVAL"
done
