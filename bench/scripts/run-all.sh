#!/usr/bin/env bash
#
# Run the full AI-gateway benchmark comparison: the baseline floor plus every
# engine, once each. Groups all cells under one RUN_ID and prints the
# comparison table.
#
# Engines are run SEQUENTIALLY (one stack up at a time) so each gets the full,
# uncontended resource budget — required for fair resource-footprint numbers.
#
# Usage:
#   bench/scripts/run-all.sh [run-id]
#
# Honors the same env knobs as run.sh (RATE, DURATION, CONNS, FORTIO_N, caps).

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# A stable run-id must be provided (Date.now is intentionally not used here so
# results are reproducible); default to "latest" if the caller gives none.
RUN_ID="${1:-latest}"
export RUN_ID

echo "=== AI Gateway Benchmark: run '${RUN_ID}' ==="

# Baseline floor first, so the engines that follow are measured under the same
# machine conditions as the floor they are compared against.
"${REPO_ROOT}/bench/scripts/run.sh" baseline
"${REPO_ROOT}/bench/scripts/run.sh" praxis
"${REPO_ROOT}/bench/scripts/run.sh" agentgateway
# Envoy AI Gateway: added after its standalone spike.
# "${REPO_ROOT}/bench/scripts/run.sh" envoy-ai-gateway

echo
"${REPO_ROOT}/bench/scripts/summarize.py" "${REPO_ROOT}/bench/results/${RUN_ID}" \
  | tee "${REPO_ROOT}/bench/results/${RUN_ID}/summary.md"
