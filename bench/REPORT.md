# AI Gateway Benchmark — Results

> **Disclosure: these numbers were captured on a developer laptop running containers inside a podman VM, not a quiet dedicated Linux host. Latency medians and their stddevs are stable enough to compare; the throughput column is not — see "Reading the results".**

Run `v2` — **5 repeats**, each a fresh stack-up / measure / tear-down cycle. Every number below is the median across repeats; `±` is the sample standard deviation.

## What this measures

The per-request cost of **AI request processing** — parse the JSON body, route by `model`, and count tokens — across AI gateways, all proxying to one byte-identical mock upstream. This is a narrower, AI-gateway-specific companion to the core-proxy overhead benchmark; here every engine does real AI work and we measure who does it more efficiently, not raw byte forwarding.

Full methodology and the fairness contract:

- [`docs/proposals/00075_ai-gateway-benchmark-methodology.md`](../docs/proposals/00075_ai-gateway-benchmark-methodology.md)

### The measured processing path

Every engine performs the same three units of work on every request:

1. Parse the JSON request body.
2. Route to an upstream based on the `model` field.
3. Count tokens from the provider-returned `usage` object.

Nothing more, nothing less — no auth, no rate limiting, no prompt rewriting, no local tokenization. Both engines were verified to return the same token counts for the same request (prompt 22 / completion 256 / total 278, matching the mock's known values), so they are doing the same work, not different amounts of it.

### Configurations under test (proof)

Each cell runs a checked-in config doing exactly that work:

| Cell | Engine | Config | Key knobs |
|---|---|---|---|
| baseline | mock only | [`engines/baseline/compose.yaml`](engines/baseline/compose.yaml) | mock published direct to host, no gateway in path |
| Praxis AI | Praxis AI | [`engines/praxis/gateway.yaml`](engines/praxis/gateway.yaml) | `model_to_header` + `router` + `token_count` (`provider: openai`) |
| agentgateway | agentgateway | [`engines/agentgateway/gateway.yaml`](engines/agentgateway/gateway.yaml) | `llm:` mode, `tokenize: false` (provider usage only) |

Fairness rules enforced: byte-identical mock for every engine; the harness consumes SSE incrementally; token counting is **provider-usage-only** on all engines (no local tokenizer enabled); identical CPU/memory caps and load parameters. See the per-engine processing ledger in the methodology for what each engine does to the body, row by row.

## Results

_Baseline floor (mock, no gateway): unary P50 0.79ms, stream P50 41.81ms. **added P50** subtracts this floor to isolate the gateway's own overhead._

| Cell | unary P50 | added P50 | unary mean | P90 | P95 | P99 | max qps | peak CPU% | peak mem MB | stream P50 | stream gate | success |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| baseline (mock, no gateway) | 0.79±0.01ms | — | 0.71ms | 0.95ms | 1.05ms | 1.42ms | 20785±609 | 13.09 | 2.48 | 41.81ms | PASS (5/5) | 100.00% |
| Praxis AI | 1.32±0.00ms | 0.54ms | 1.14ms | 1.55ms | 1.71ms | 2.19ms | 21907±302 | 19.80 | 17.78 | 42.84ms | PASS (5/5) | 100.00% |
| agentgateway | 1.41±0.02ms | 0.63ms | 1.25ms | 1.73ms | 1.89ms | 2.44ms | 23735±337 | 20.43 | 16.22 | 42.86ms | PASS (5/5) | 100.00% |

### Reading the results

- **Added latency:** Praxis AI has the lower added latency — Praxis AI **0.54ms** vs agentgateway **0.63ms** of gateway-imposed overhead per request (~15% difference, an absolute gap of 0.09ms). Both are well under a millisecond of added P50, and the per-repeat stddevs are far smaller than the gap between them, so the ordering is a real effect rather than run-to-run noise. It is still a close race in absolute terms.
- **Streaming:** every cell streams incrementally — TTFB is a negligible fraction of stream-completion time under a per-chunk mock delay, and the fairness gate passed on all 5 repeats for every engine. No engine is buffering the stream, so the streaming columns are fair to compare.
- **Throughput is not comparable on this host.** Under closed-loop saturation, **Praxis AI** and **agentgateway** record a higher max qps (21907, 23735) than the no-gateway baseline (20785). A gateway cannot serve more requests than the upstream it proxies to, so this is an artifact of the saturation measurement — differences in connection handling and keep-alive behaviour between the engines and the bare mock, amplified by running containers in a VM — not an engine result. **Do not rank the engines on the qps column.** A stepped rate sweep on a dedicated Linux host is required before publishing any throughput claim.

### Streaming fairness (TTFB) evidence

With a per-chunk delay applied at the mock, an engine that streams incrementally releases the first byte long before the stream completes. A buffering engine would show TTFB ≈ completion. Median over repeats:

| Cell | median TTFB | median completion | TTFB/total | verdict |
|---|---|---|---|---|
| baseline (mock, no gateway) | 2.71ms | 6228.70ms | 0.000 | PASS |
| Praxis AI | 2.66ms | 6290.92ms | 0.000 | PASS |
| agentgateway | 2.43ms | 6338.87ms | 0.000 | PASS |

## Provenance & reproducibility

- **Host:** Apple M-series laptop (macOS 25.6, arm64), podman machine VM, 5 repeats
- **Load parameters:** rate 200 req/s, duration 30s, fortio 20000 reqs @ 50 conns, 5 repeats
- **Resource caps (gateway):** 2.0 CPU / 1g (mock: 4 CPU / 2g)
- **Load generators:** vegeta 12.13.0, fortio 1.75.1
- **Images (digest-pinned where from a registry):**
    - baseline (mock, no gateway): `localhost/bench-mock-llm:latest` — `localhost/bench-mock-llm@sha256:fd3621e65cfbd34d81c4e72ab94f50a3799f90119a80a22fc65be342e4dc7a7d`
    - Praxis AI: `localhost/praxis-ai:0.3.0` — `localhost/praxis-ai@sha256:00b4d3e9c3573344213556d55f61b87c1003a9e06aa57ff00ef1b835ac4112d5`
    - agentgateway: `ghcr.io/agentgateway/agentgateway:latest` — `ghcr.io/agentgateway/agentgateway@sha256:bf2f339ef326d32def2aaeb44b1b4549801293c19b89e764a4228667d97d9896`

One-command reproduction (requires podman, ideally a quiet dedicated Linux host):

```console
make bench BENCH_RUN_ID=<id> BENCH_REPEATS=5
```

_Raw per-repeat artifacts live under `bench/results/<id>/` and are gitignored — the harness, methodology, and this generated report are the committed deliverables, not one machine's raw numbers. Regenerate this report with `bench/scripts/report.py`._
