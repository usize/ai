# AI Gateway Benchmark Harness

A fair, reproducible comparison of the per-request cost of **AI request
processing** (parse body → route by model → count tokens) across AI
gateways. See the methodology for the full design and fairness contract:

- [`docs/proposals/00075_ai-gateway-benchmark-methodology.md`](../docs/proposals/00075_ai-gateway-benchmark-methodology.md)

This is a *separate, narrower* effort than the core-proxy overhead benchmark
in praxis-proxy/praxis#1082: here every engine does real AI work, and we
measure who does it more efficiently — not raw byte forwarding.

**[→ Latest results report (`REPORT.md`)](REPORT.md)** — methodology summary,
proof via config links, and a median±stddev results table. Generated from a
run with `bench/scripts/report.py`; regenerate after any run.

## Engines under test

| Engine | Runtime | Status |
|---|---|---|
| Praxis AI | Rust (Pingora) | built |
| agentgateway | Rust (Tokio + Hyper) | built |
| Envoy AI Gateway | Envoy (C++) + ext_proc | planned (added after the two Rust engines) |

All three are OSS and freely publishable. Kong AI Gateway was considered
and dropped for v1 (`ai-proxy` is Enterprise-tier; benchmark-publication
terms unverified). Rationale is documented in the methodology.

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
  results/      raw artifacts + summaries (gitignored except .gitkeep)
```

## Running

Requires **podman** (the runner uses `podman compose`/`stats`/`inspect`).

One command builds the images and runs the full, hardened comparison —
every cell repeated N times, with median + stddev and baseline-subtracted
*added* latency:

```console
make bench BENCH_RUN_ID=<run-id> BENCH_REPEATS=5
```

Fast smoke (single pass per cell — not publishable):

```console
make bench-quick BENCH_RUN_ID=<run-id>
```

Other Make targets: `make bench-images` (build the mock + bench Praxis
images only), `make bench-summary BENCH_RUN_ID=<run-id>` (re-aggregate an
existing run without re-measuring).

> The bench-only Praxis Dockerfile (`bench/engines/praxis/Dockerfile`) pins
> `rust:1.97-alpine` to sidestep a cargo parse bug in the shipped
> `Containerfile`'s `rust:1.98-alpine` base (brotli-decompressor). Drop it
> once the top-level image builds cleanly. agentgateway pulls a digest-pinned
> image on first run.

### Running the scripts directly

The Make targets are thin wrappers over `bench/scripts/`. To drive them
yourself — e.g. one cell in isolation, or custom load knobs:

```console
bench/scripts/run-repeats.sh <run-id> 5      # full comparison, 5 repeats
bench/scripts/run-all.sh <run-id>            # single pass
bench/scripts/run.sh praxis                  # one engine
bench/scripts/run.sh baseline                # the floor cell
bench/scripts/aggregate.py bench/results/<run-id>   # re-aggregate
```

Shared knobs (identical across every engine, so numbers stay comparable):
`RATE`, `DURATION`, `WARMUP`, `CONNS`, `FORTIO_N`, `GATEWAY_CPUS`,
`GATEWAY_MEM`, `REPEATS`.

### Generating the report

`REPORT.md` is generated from a run's raw artifacts, so it never drifts from
the measurements:

```console
bench/scripts/report.py bench/results/<run-id> \
  --title "AI Gateway Benchmark — Results" \
  --host "<cpu, ram, os, container engine>" \
  --caveat "<disclosure if not a clean dedicated host>" \
  > bench/REPORT.md
```

### The baseline (added-latency floor)

The `baseline` cell publishes the mock **directly to the host with no gateway
in the path**, under the same host, load, and payloads as the engine cells.
`aggregate.py` subtracts its median latency from each engine cell to report
*added* latency — the cost the gateway itself imposes, which is the number AI-
Gateway buyers care about. It also confirms the mock is never the bottleneck at
the rates we drive the engines.

### Publishable-numbers checklist

Single-shot numbers on a shared laptop are noise. Before quoting results:

1. Run on a **quiet, dedicated Linux host** (bare metal or a pinned VM), not a
   dev laptop or a noisy CI shared runner. macOS runs containers in a VM, which
   adds latency and variance — fine for harness development, not for headline
   numbers.
2. Use **`run-repeats.sh` with ≥5 repeats** and report the median ± stddev the
   aggregator prints; a wide stddev means the host was contended — re-run.
3. Confirm the **stream gate reads PASS on every repeat** before publishing any
   streaming column.
4. Keep the **CPU/memory caps identical** across engines (defaults: 2 CPU / 1 GB
   for the gateway, 4 CPU / 2 GB for the mock) and record them (the runner
   writes `meta.yaml` per cell with versions, image digests, and caps).
5. Publish alongside the **per-engine processing ledger** from the methodology.
6. Sanity-check throughput against the floor: an engine cannot sustain more
   qps than the **no-gateway baseline**. If it appears to, the saturation run
   is measuring the harness/host, not the engine — do not publish the qps
   column until a stepped rate sweep on a dedicated host puts the baseline on
   top. `report.py` flags this automatically.

## The measured processing path

Every engine does the same three units of work on every request, and
nothing else:

1. Parse the JSON request body.
2. Route by `model`.
3. Count tokens from the provider-returned `usage`.

That path runs in **unary** and **SSE streaming** modes. Auth, rate
limiting, prompt rewriting, guardrails, and local tokenization are all off
(see methodology).

## Fairness rules (do not break these)

1. Every engine proxies to a **byte-identical** mock instance.
2. **TTFB is measured with a non-buffering reader** (`ttfb-probe.sh`, `curl
   -N`). vegeta reads whole bodies, so its streaming figure is reported as
   end-to-end completion — never relabelled as TTFB.
3. Token counting uses **provider-returned usage only** in v1 (no engine's
   local tokenizer is enabled), so all engines do the same work.
4. Every result is published with the **per-engine processing ledger** so
   readers can see exactly what each engine does to the body.
5. Pin exact image tags **and digests** for every engine + the mock.

## Mock upstream

`bench/mock-llm` is a standalone Rust crate (its own workspace root, so it
does not affect the main build/lint/audit). It speaks
`POST /v1/chat/completions` in unary and SSE modes and emits a real `usage`
block computed from the tokens it produces, so token-count parity can be
checked.

Tuning knobs (env, overridable per-request by header):

| Knob | Env | Header | Effect |
|---|---|---|---|
| Think latency (pre-first-byte) | `MOCK_THINK_MS` | `x-mock-think-ms` | fixed delay before responding |
| Inter-chunk delay (streaming) | `MOCK_CHUNK_MS` | `x-mock-chunk-ms` | delay between SSE frames |
| Bind address | `MOCK_ADDR` | — | default `0.0.0.0:9000` |

Completion length comes from the request `max_tokens` /
`max_completion_tokens` (clamped); prompt tokens are estimated from message
word counts. Per-request header overrides mean one running instance serves
the whole latency matrix.

Run locally:

```console
cargo run --manifest-path bench/mock-llm/Cargo.toml
```
