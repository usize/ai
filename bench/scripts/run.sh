#!/usr/bin/env bash
#
# AI Gateway benchmark runner.
#
# Brings up one engine's compose stack (engine + mock, CPU/mem-capped),
# warms it, then drives identical load with vegeta (fixed-rate latency, unary
# and streaming) and fortio (throughput sweep), captures the gateway
# container's CPU/RSS, and runs the streaming TTFB fairness gate. Results are
# written under bench/results/<run-id>/<engine>/.
#
# Every engine is measured with the SAME parameters and the SAME published
# host endpoint, so the numbers are comparable. See the methodology:
# docs/proposals/00075_ai-gateway-benchmark-methodology.md
#
# Usage:
#   bench/scripts/run.sh <engine>
#   engine: baseline | praxis | agentgateway
#
# Env knobs (same defaults across engines):
#   RATE       vegeta requests/sec for the latency test   (default 200)
#   DURATION   vegeta test duration                        (default 30s)
#   WARMUP     warmup duration                             (default 10s)
#   CONNS      fortio concurrent connections (throughput)  (default 50)
#   FORTIO_N   fortio total requests for throughput run    (default 20000)
#   GATEWAY_CPUS / GATEWAY_MEM  engine resource caps       (default 2.0 / 1g)
#   RUN_ID     shared id to group engines in one comparison (default: caller sets)

set -euo pipefail

ENGINE="${1:?usage: run.sh <engine>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE="${REPO_ROOT}/bench/engines/${ENGINE}/compose.yaml"
LOAD_DIR="${REPO_ROOT}/bench/load"

[ -f "$COMPOSE" ] || { echo "no compose for engine '${ENGINE}': $COMPOSE" >&2; exit 1; }

# Fixed, identical-across-engines parameters.
RATE="${RATE:-200}"
DURATION="${DURATION:-30s}"
WARMUP="${WARMUP:-10s}"
CONNS="${CONNS:-50}"
FORTIO_N="${FORTIO_N:-20000}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
export GATEWAY_PORT
export GATEWAY_CPUS="${GATEWAY_CPUS:-2.0}"
export GATEWAY_MEM="${GATEWAY_MEM:-1g}"

RUN_ID="${RUN_ID:-manual}"
OUT="${REPO_ROOT}/bench/results/${RUN_ID}/${ENGINE}"
mkdir -p "$OUT"

ENDPOINT="http://127.0.0.1:${GATEWAY_PORT}/v1/chat/completions"
COMPOSE_CMD=(podman compose -f "$COMPOSE")

cleanup() { "${COMPOSE_CMD[@]}" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo ">>> [${ENGINE}] bringing up stack"
"${COMPOSE_CMD[@]}" up -d >/dev/null 2>&1

# ---- readiness: poll until the gateway returns 200 through the mock --------
echo ">>> waiting for readiness"
ready=0
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ENDPOINT" \
    -H 'content-type: application/json' --data-binary @"${LOAD_DIR}/chat-unary.json" 2>/dev/null || true)
  if [ "$code" = "200" ]; then ready=1; break; fi
  sleep 1
done
[ "$ready" = "1" ] || { echo "gateway never became ready" >&2; "${COMPOSE_CMD[@]}" logs >&2; exit 1; }

record_meta() {
  {
    echo "captured_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "engine: ${ENGINE}"
    echo "rate: ${RATE}"
    echo "duration: ${DURATION}"
    echo "conns: ${CONNS}"
    echo "fortio_n: ${FORTIO_N}"
    echo "gateway_cpus: ${GATEWAY_CPUS}"
    echo "gateway_mem: ${GATEWAY_MEM}"
    echo "endpoint: ${ENDPOINT}"
    echo "vegeta: $(vegeta -version 2>&1 | head -1)"
    echo "fortio: $(fortio version 2>&1 | head -1)"
    # exact image the gateway is running (digest where available)
    cid=$("${COMPOSE_CMD[@]}" ps -q gateway 2>/dev/null | head -1)
    if [ -n "${cid:-}" ]; then
      img=$(podman inspect "$cid" --format '{{.ImageName}}' 2>/dev/null)
      echo "gateway_image: ${img}"
      echo "gateway_image_id: $(podman inspect "$cid" --format '{{.Image}}' 2>/dev/null)"
      # Registry digest (reproducible pin) where the image came from a registry.
      echo "gateway_image_digest: $(podman inspect "$img" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null)"
    fi
  } > "${OUT}/meta.yaml"
}
record_meta

# ---- warmup ---------------------------------------------------------------
echo ">>> warmup ${WARMUP}"
echo "POST ${ENDPOINT}" | vegeta attack -rate="$RATE" -duration="$WARMUP" \
  -header 'Content-Type: application/json' -body "${LOAD_DIR}/chat-unary.json" \
  > /dev/null 2>&1 || true

# ---- background resource sampler (gateway container only) -----------------
sample_resources() {
  local cid="$1" out="$2"
  echo "cpu_perc,mem_bytes" > "$out"
  while podman container exists "$cid" >/dev/null 2>&1; do
    # --no-stream one-shot; strip unit suffixes downstream in analysis.
    podman stats --no-stream --format '{{.CPU}},{{.MemUsage}}' "$cid" 2>/dev/null \
      | head -1 >> "$out" || true
    sleep 1
  done
}
GW_CID=$("${COMPOSE_CMD[@]}" ps -q gateway | head -1)
sample_resources "$GW_CID" "${OUT}/resources.csv" &
SAMPLER_PID=$!

# ---- vegeta: unary latency at fixed rate ----------------------------------
echo ">>> vegeta unary latency @ ${RATE}rps for ${DURATION}"
echo "POST ${ENDPOINT}" | vegeta attack -rate="$RATE" -duration="$DURATION" \
  -header 'Content-Type: application/json' -body "${LOAD_DIR}/chat-unary.json" \
  | tee "${OUT}/vegeta-unary.bin" \
  | vegeta report -type=text > "${OUT}/vegeta-unary.txt"
vegeta report -type=json < "${OUT}/vegeta-unary.bin" > "${OUT}/vegeta-unary.json"

# ---- vegeta: streaming latency (end-to-end) -------------------------------
# vegeta reads the full body, so this is end-to-end stream completion latency,
# not TTFB. TTFB is measured separately below with an incremental reader.
echo ">>> vegeta streaming latency @ ${RATE}rps for ${DURATION}"
echo "POST ${ENDPOINT}" | vegeta attack -rate="$RATE" -duration="$DURATION" \
  -header 'Content-Type: application/json' -body "${LOAD_DIR}/chat-stream.json" \
  | tee "${OUT}/vegeta-stream.bin" \
  | vegeta report -type=text > "${OUT}/vegeta-stream.txt"
vegeta report -type=json < "${OUT}/vegeta-stream.bin" > "${OUT}/vegeta-stream.json"

# ---- fortio: throughput sweep (unary) -------------------------------------
echo ">>> fortio throughput: ${CONNS} conns, ${FORTIO_N} reqs (qps=max)"
fortio load -c "$CONNS" -n "$FORTIO_N" -qps 0 -content-type application/json \
  -payload-file "${LOAD_DIR}/chat-unary.json" -json "${OUT}/fortio-unary.json" \
  "$ENDPOINT" > "${OUT}/fortio-unary.txt" 2>&1 || true

# ---- streaming TTFB fairness gate -----------------------------------------
# Confirm the engine streams incrementally: TTFB should be much smaller than
# full-body completion time when the mock adds a per-chunk delay. If TTFB ~=
# completion time, the engine is buffering the stream and streaming numbers
# must not be published for it.
echo ">>> streaming TTFB fairness probe"
"${REPO_ROOT}/bench/scripts/ttfb-probe.sh" "$ENDPOINT" "${LOAD_DIR}/chat-stream.json" \
  > "${OUT}/ttfb.txt" 2>&1 || true
cat "${OUT}/ttfb.txt"

kill "$SAMPLER_PID" >/dev/null 2>&1 || true
wait "$SAMPLER_PID" 2>/dev/null || true

echo ">>> [${ENGINE}] done -> ${OUT}"
