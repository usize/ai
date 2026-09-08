# AI Gateway Benchmark Harness

Measures the per-request cost of **AI request processing** — parse the
JSON body, route by `model`, count tokens from provider-returned `usage`
— across AI gateways, all proxying to one byte-identical mock upstream.
Narrower than the core-proxy overhead benchmark in
praxis-proxy/praxis#1082: every engine here does real AI work, and we
measure who does it more efficiently, not raw byte forwarding.

Full design rationale (engine selection, open questions, sources):
[`docs/proposals/00075_ai-gateway-benchmark-methodology.md`](../docs/proposals/00075_ai-gateway-benchmark-methodology.md).

**Results are dated instances, not a living document.** Each benchmarking
run produces a new file under [`bench/reports/`](reports/) — see that
directory for the most recent one. Nothing here claims to be "current";
every report stands on its own with its own date, host, and caveats.

## Engines under test

| Engine | Runtime | Status |
|---|---|---|
| Praxis AI | Rust (Pingora) | built |
| agentgateway | Rust (Tokio + Hyper) | built |
| Envoy AI Gateway | Envoy (C++) + ext_proc | planned |

All OSS and freely publishable (Kong AI Gateway dropped — Enterprise-tier;
see methodology for rationale).

## Fairness rules (do not break these)

1. Every engine proxies to a **byte-identical** mock instance.
2. **TTFB is measured with a non-buffering reader** (`ttfb-probe.sh`,
   `curl -N`). vegeta reads whole bodies, so its streaming figure is
   end-to-end completion — never relabelled as TTFB.
3. Token counting uses **provider-returned usage only** (no engine's local
   tokenizer enabled), so all engines do the same work.
4. Every result is published with the **per-engine processing ledger**
   (methodology) so readers can see exactly what each engine does to the
   body.
5. Pin exact image tags **and digests** for every engine + the mock.
6. An engine cannot sustain more qps than the **no-gateway baseline**. If
   it appears to, the saturation run is measuring the harness/host, not
   the engine — `report.py` flags this and blocks the throughput claim.

## Layout

```
bench/
  mock-llm/     deterministic OpenAI-shaped mock upstream (unary + SSE)
  engines/      per-engine compose stacks + configs
    baseline/   mock published with NO gateway — the added-latency floor
    praxis/     gateway.yaml, compose.yaml, Dockerfile (bench-only build)
    agentgateway/  gateway.yaml, compose.yaml, NOTES.md (pinned digest)
  load/         vegeta/fortio request bodies (chat-unary.json, chat-stream.json)
  scripts/      runner + results processing
  reports/      dated, generated report instances (committed)
  profiling/    dated, one-off profiling investigations (committed)
  results/      raw artifacts (gitignored except .gitkeep)
```

## Running

Requires **podman** (`podman compose`/`stats`/`inspect`).

```console
make bench BENCH_RUN_ID=<run-id> BENCH_REPEATS=5   # full, hardened comparison
make bench-quick BENCH_RUN_ID=<run-id>             # single pass, not publishable
make bench-images                                   # build mock + bench Praxis only
make bench-summary BENCH_RUN_ID=<run-id>            # re-aggregate an existing run
```

> The bench-only Praxis Dockerfile pins `rust:1.97-alpine` to sidestep a
> cargo parse bug in the shipped `Containerfile`'s `rust:1.98-alpine`
> base. Drop it once the top-level image builds cleanly.

Or drive the scripts directly (same knobs: `RATE`, `DURATION`, `WARMUP`,
`CONNS`, `FORTIO_N`, `GATEWAY_CPUS`, `GATEWAY_MEM`, `REPEATS`):

```console
bench/scripts/run-repeats.sh <run-id> 5      # full comparison, 5 repeats
bench/scripts/run.sh praxis                  # one engine
bench/scripts/run.sh baseline                # the floor cell
bench/scripts/aggregate.py bench/results/<run-id>
```

### Generating a dated report

```console
bench/scripts/report.py bench/results/<run-id> \
  --title "AI Gateway Benchmark — Results" \
  --host "<cpu, ram, os, container engine>" \
  --caveat "<disclosure if not a clean dedicated host>" \
  > bench/reports/<YYYY-MM-DD>.md
```

The report is generated from the run's raw artifacts, so it never drifts
from the measurements — but it is a snapshot. Write it to a new dated
file; never overwrite an existing one.

## Before publishing a number

1. Run on a **quiet, dedicated Linux host**, not a dev laptop or shared CI
   runner — macOS runs containers in a VM, adding latency/variance.
2. Use **`run-repeats.sh` with ≥5 repeats**; a wide stddev means the host
   was contended — re-run.
3. Confirm the **stream gate reads PASS on every repeat**.
4. Keep **CPU/memory caps identical** across engines and record them
   (`meta.yaml` per cell has versions, digests, caps).
5. Publish alongside the **per-engine processing ledger** (methodology).

## Mock upstream

`bench/mock-llm` is a standalone Rust crate (own workspace root). Speaks
`POST /v1/chat/completions` in unary and SSE, emits real `usage` computed
from the tokens it produces (token-count parity is checkable).

| Knob | Env | Header | Effect |
|---|---|---|---|
| Think latency | `MOCK_THINK_MS` | `x-mock-think-ms` | fixed delay before responding |
| Inter-chunk delay (streaming) | `MOCK_CHUNK_MS` | `x-mock-chunk-ms` | delay between SSE frames |
| Bind address | `MOCK_ADDR` | — | default `0.0.0.0:9000` |

Completion length comes from `max_tokens`/`max_completion_tokens`
(clamped); prompt tokens are estimated from message word counts.
Per-request header overrides mean one instance serves the whole matrix.

```console
cargo run --manifest-path bench/mock-llm/Cargo.toml
```
