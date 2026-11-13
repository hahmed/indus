#!/bin/bash
# The extractor and the mspec shim are borrowed from the Spinel project (tools/rubyspec/, MIT); the runner here
# takes any compiler: BYOC. The reference is CRuby.
# tools/rubyspec/run-indus.sh EXTRACTED_DIR [RESULTS_TSV]
# Classify extracted ruby/spec examples (tools/rubyspec/extract.rb, Spinel's extractor, unchanged) against Indus,
# with Spinel's rules (run.sh): PASS / FAIL / REJECT (compile refused) / ERROR (ran but crashed or no MSPEC-DONE) /
# HARNESS-SKEW (CRuby itself does not pass the extracted program: excluded). One TSV row per example.
#   RUBYSPEC_JOBS=n  parallelism (default 2: the memory discipline)
set -u
DIR="${1:?usage: run-indus.sh EXTRACTED_DIR [out.tsv]}"
OUT="${2:-$DIR/results.tsv}"
JOBS="${RUBYSPEC_JOBS:-2}"
TDIR=$(mktemp -d /tmp/rubyspec-indus.XXXXXX)
trap 'rm -rf "$TDIR"; pkill -9 -P $$ 2>/dev/null' EXIT
INDUS="$(cd "$(dirname "$0")/../.." && pwd)/bin/indus"
classify_one() {
  local f="$1"; local bn; bn=$(basename "$f" .rb); local row="$TDIR/rows/$bn"
  local cr; cr=$(timeout -k 1 10 ruby --disable-gems "$f" 2>/dev/null | tail -1)
  if ! grep -q "fail=0" <<<"$cr"; then printf '%s\tHARNESS-SKEW\t%s\n' "$bn" "${cr:-crash}" > "$row"; return; fi
  local run_out="$TDIR/out-$bn"; local err_out="$TDIR/err-$bn"
  INDUS_HEAP_MB=64 timeout -k 1 15 "$INDUS" "$f" > "$run_out" 2> "$err_out"; local rc=$?
  local last; last=$(tail -c 4096 "$run_out" | tail -1)
  if ! grep -q "MSPEC-DONE\|MSPEC-FAIL" "$run_out" && grep -q "lib/indus/.*\.rb:[0-9]*:in" "$err_out"; then
    # the compiler refused (a Ruby exception in the compiler): the reason is its message
    local reason; reason=$(grep -m1 "lib/indus/.*\.rb:[0-9]*:in" "$err_out" | sed -E "s/^.*lib\/indus\/[a-z_]+\.rb:[0-9]+:in '[^']*': //; s/ \((RuntimeError|NoMethodError|KeyError|TypeError|ArgumentError)\)$//" | cut -c1-160)
    reason=${reason//$'\t'/ }
    printf '%s\tREJECT\t%s\n' "$bn" "${reason:-unknown}" > "$row"; rm -f "$run_out" "$err_out"; return
  fi
  if [ $rc -ne 0 ] || ! grep -q "MSPEC-DONE" <<<"$last"; then
    local el; el=$(tail -c 2048 "$err_out" | grep -v '^indus:' | tail -1); el=${el//$'\t'/ }
    printf '%s\tERROR\trc=%s %s\n' "$bn" "$rc" "${el:0:200}" > "$row"
  elif grep -q "fail=0" <<<"$last"; then printf '%s\tPASS\t%s\n' "$bn" "$last" > "$row"
  else printf '%s\tFAIL\t%s\n' "$bn" "$(grep -m1 MSPEC-FAIL "$run_out" | cut -c1-200)" > "$row"; fi
  rm -f "$run_out" "$err_out"
}
export -f classify_one; export TDIR INDUS
mkdir -p "$TDIR/rows"
ls "$DIR"/*.rb | xargs -P "$JOBS" -I{} bash -c 'classify_one "$@"' _ {}
: > "$OUT"; for row in $(ls "$TDIR/rows" | sort); do cat "$TDIR/rows/$row" >> "$OUT"; done
for s in PASS FAIL REJECT ERROR HARNESS-SKEW; do printf '%s=%s ' $s $(awk -F'\t' -v s=$s '$2==s' "$OUT" | wc -l | tr -d ' '); done; echo
echo "--- top reject reasons ---"; awk -F'\t' '$2=="REJECT"{print $3}' "$OUT" | sed 's/[0-9]\+/N/g' | sort | uniq -c | sort -rn | head -15
