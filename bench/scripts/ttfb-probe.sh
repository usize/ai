#!/usr/bin/env bash
#
# Streaming TTFB fairness gate.
#
# Sends a streaming request with a per-chunk delay applied at the mock
# (x-mock-chunk-ms), and compares time-to-first-byte against full-completion
# time. An engine that streams incrementally releases the first SSE frame
# quickly (TTFB << completion). An engine that BUFFERS the stream shows
# TTFB ~= completion — in that case its streaming numbers are not fair to
# publish, and this gate flags it.
#
# Usage: ttfb-probe.sh <endpoint> <stream-body-file>
#
# Emits, per trial: ttfb_s and total_s. With N chunks each delayed CHUNK_MS,
# an incremental engine's total should be ~ (N-1)*CHUNK_MS while TTFB is a
# small fraction of that.

# Note: no `set -e` here. Individual trials use curl/read/awk whose non-zero
# exits (e.g. read hitting EOF on the process substitution) must not abort the
# probe; we handle failures per-trial instead.
set -uo pipefail
ENDPOINT="${1:?endpoint}"
BODY="${2:?stream body file}"

CHUNK_MS="${TTFB_CHUNK_MS:-20}"   # per-chunk delay applied at the mock
TRIALS="${TTFB_TRIALS:-5}"

echo "ttfb probe: chunk_delay=${CHUNK_MS}ms trials=${TRIALS}"
echo "trial,ttfb_s,total_s,verdict_ratio"

sum_ratio=0
for i in $(seq 1 "$TRIALS"); do
  # curl reports both time_starttransfer (TTFB) and time_total. We force the
  # per-chunk delay via header so the mock paces the stream identically for
  # every engine.
  timing=$(curl -s -o /dev/null \
    -w '%{time_starttransfer} %{time_total}' \
    -N -X POST "$ENDPOINT" \
    -H 'content-type: application/json' \
    -H "x-mock-chunk-ms: ${CHUNK_MS}" \
    --data-binary @"$BODY")
  ttfb=$(echo "$timing" | awk '{print $1}')
  total=$(echo "$timing" | awk '{print $2}')
  # ratio = ttfb / total; small ratio => incremental streaming.
  ratio=$(awk -v a="$ttfb" -v b="$total" 'BEGIN{ if (b>0) printf "%.3f", a/b; else print "nan" }')
  echo "${i},${ttfb},${total},${ratio}"
  sum_ratio=$(awk -v s="$sum_ratio" -v r="$ratio" 'BEGIN{printf "%.3f", s+r}')
done

avg_ratio=$(awk -v s="$sum_ratio" -v n="$TRIALS" 'BEGIN{printf "%.3f", s/n}')
echo "avg_ttfb_to_total_ratio: ${avg_ratio}"

# Heuristic gate: incremental streaming keeps TTFB well under half the total.
verdict=$(awk -v r="$avg_ratio" 'BEGIN{ print (r < 0.5) ? "PASS (incremental)" : "FAIL (looks buffered)" }')
echo "streaming_fairness_gate: ${verdict}"
