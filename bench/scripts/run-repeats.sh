#!/usr/bin/env bash
#
# Run the full AI-gateway comparison N times and aggregate to median + stddev.
#
# A single measurement on a shared machine is noise. This runs the whole set of
# cells (baseline floor + every engine) once per repeat, each repeat with a
# fresh stack-up/measure/tear-down cycle, into
# its own rep-<n>/ sub-directory. aggregate.py then reports the median and
# sample stddev of each metric across repeats, and subtracts the baseline floor
# to show each engine's *added* latency.
#
# Cells are run SEQUENTIALLY within a repeat (one stack up at a time) so each
# gets the full, uncontended resource budget.
#
# Usage:
#   bench/scripts/run-repeats.sh [run-id] [repeats]
#
# Env: REPEATS (default 5) overrides the positional; all run.sh knobs pass
# through (RATE, DURATION, CONNS, FORTIO_N, caps).

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

BASE_RUN_ID="${1:-latest}"
REPEATS="${2:-${REPEATS:-5}}"

echo "=== AI Gateway Benchmark: run '${BASE_RUN_ID}', ${REPEATS} repeats ==="

# Cells, in order. Baseline first each repeat so the floor is measured under the
# same machine conditions as the engines that follow it.
CELLS=(
  baseline
  praxis
  agentgateway
  # envoy-ai-gateway   # added after its standalone spike
)

for rep in $(seq 1 "$REPEATS"); do
  echo
  echo "--- repeat ${rep}/${REPEATS} ---"
  # Each repeat writes under results/<run-id>/rep-<n>/<engine>/ by
  # pointing run.sh's RUN_ID at the per-repeat sub-path.
  export RUN_ID="${BASE_RUN_ID}/rep-${rep}"
  for cell in "${CELLS[@]}"; do
    "${REPO_ROOT}/bench/scripts/run.sh" "$cell"
  done
done

echo
echo "=== aggregating ${REPEATS} repeats ==="
"${REPO_ROOT}/bench/scripts/aggregate.py" "${REPO_ROOT}/bench/results/${BASE_RUN_ID}" \
  | tee "${REPO_ROOT}/bench/results/${BASE_RUN_ID}/summary.md"
