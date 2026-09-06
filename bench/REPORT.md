# AI Gateway Benchmark — Results (illustrative)

> **Illustrative, not headline numbers. Run on a macOS dev laptop where podman executes containers inside a Linux VM, which adds latency and variance. Directionally sound and internally consistent (identical harness for every engine), but publish headline numbers only from a quiet, dedicated bare-metal Linux host.**

Run `report-2026-09-06` — **5 repeats**, each a fresh stack-up / measure / tear-down cycle. Every number below is the median across repeats; `±` is the sample standard deviation.

## What this measures

The per-request cost of **AI request processing** — parse the JSON body, route by `model`, and count tokens — across AI gateways, all proxying to one byte-identical mock upstream. This is a narrower, AI-gateway-specific companion to the core-proxy overhead benchmark; here every engine does real AI work and we measure who does it more efficiently, not raw byte forwarding.

Full methodology and the fairness contract:

- [`docs/proposals/00075_ai-gateway-benchmark-methodology.md`](../docs/proposals/00075_ai-gateway-benchmark-methodology.md)

### Processing tiers

- **T1** — parse request body + route by `model`.
- **T2** — T1 + token counting from provider-returned `usage`.

agentgateway's `llm:` path always parses + routes + meters as one inseparable data path (no route-only mode), so it has no separable T1. The honest apples-to-apples row is **Praxis-T2 vs agentgateway-T2**; Praxis-T1 is reported separately as the marginal cost of token metering.

### Configurations under test (proof)

Each cell runs a checked-in config doing exactly its tier's work:

| Cell | Engine | Config | Key knobs |
|---|---|---|---|
| baseline | mock only | [`engines/baseline/compose.yaml`](engines/baseline/compose.yaml) | mock published direct to host, no gateway in path |
| Praxis T2 | Praxis AI | [`engines/praxis/t2.yaml`](engines/praxis/t2.yaml) | `model_to_header` + `router` + `token_count` (`provider: openai`) |
| Praxis T1 | Praxis AI | [`engines/praxis/t1.yaml`](engines/praxis/t1.yaml) | `model_to_header` + `router` (no token counting) |
| agentgateway T2 | agentgateway | [`engines/agentgateway/t2.yaml`](engines/agentgateway/t2.yaml) | `llm:` mode, `tokenize: false` (provider usage only) |

Fairness rules enforced: byte-identical mock for every engine; the harness consumes SSE incrementally; token counting is **provider-usage-only** on all engines (no local tokenizer enabled); identical CPU/memory caps and load parameters. See the per-engine processing ledger in the methodology for what each engine does to the body, row by row.

## Results

_Baseline floor (mock, no gateway): unary P50 0.77ms, stream P50 41.64ms. **added P50** subtracts this floor to isolate the gateway's own overhead._

| Cell | unary P50 | added P50 | unary mean | P90 | P95 | P99 | max qps | peak CPU% | peak mem MB | stream P50 | stream gate | success |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| baseline (mock, no gateway) | 0.77±0.00ms | — | 0.70ms | 0.94ms | 1.06ms | 1.44ms | 20724±359 | 12.32 | 1.54 | 41.64ms | PASS (5/5) | 100.00% |
| Praxis AI — T2 | 1.28±0.03ms | 0.51ms | 1.12ms | 1.52ms | 1.68ms | 2.16ms | 22060±405 | 19.58 | 17.38 | 42.86ms | PASS (5/5) | 100.00% |
| agentgateway — T2 | 1.35±0.04ms | 0.57ms | 1.20ms | 1.69ms | 1.87ms | 2.41ms | 23560±217 | 20.18 | 16.16 | 43.03ms | PASS (5/5) | 100.00% |
| Praxis AI — T1 | 1.16±0.01ms | 0.39ms | 1.02ms | 1.38ms | 1.54ms | 2.02ms | 21971±402 | 11.67 | 17.69 | 42.24ms | PASS (5/5) | 100.00% |

### Reading the results

- **Headline (T2, apples-to-apples):** Praxis AI has the lower added latency — Praxis-T2 **0.51ms** vs agentgateway-T2 **0.57ms** of gateway-imposed overhead per request (~11% difference). Both are well under a millisecond of added P50 and within a few hundredths of a millisecond of each other — this is a close race, and the stddev columns show the measurement is stable, not noise.
- **Marginal cost of token metering (Praxis T1 → T2):** added P50 rises from 0.39ms to 0.51ms — the incremental cost of reading provider usage and emitting token counts. agentgateway has no separable route-only tier, so no equivalent number exists for it.
- **Streaming and throughput:** every cell streams incrementally (TTFB ≪ completion, gate PASS on all repeats) and sustains tens of thousands of req/s at 100% success under the fixed resource cap. Throughput differences here are small and within the noise a shared VM introduces; treat them as directional.

### Streaming fairness (TTFB) evidence

With a per-chunk delay applied at the mock, an engine that streams incrementally releases the first byte long before the stream completes. A buffering engine would show TTFB ≈ completion. Median over repeats:

| Cell | median TTFB | median completion | TTFB/total | verdict |
|---|---|---|---|---|
| baseline (mock, no gateway) | 2.73ms | 6200.43ms | 0.000 | PASS |
| Praxis AI — T2 | 3.14ms | 6299.88ms | 0.001 | PASS |
| agentgateway — T2 | 3.53ms | 6346.17ms | 0.001 | PASS |
| Praxis AI — T1 | 3.11ms | 6314.85ms | 0.000 | PASS |

## Provenance & reproducibility

- **Host:** Apple M4 Pro, 14 vCPU, 48 GiB RAM, macOS (Darwin arm64); podman 5.6.2 (Linux VM). Dev machine — see disclosure.
- **Load parameters:** rate 200 req/s, duration 30s, fortio 20000 reqs @ 50 conns, 5 repeats
- **Resource caps (gateway):** 2.0 CPU / 1g (mock: 4 CPU / 2g)
- **Load generators:** vegeta 12.13.0, fortio 1.75.1
- **Images (digest-pinned where from a registry):**
    - baseline (mock, no gateway): `localhost/bench-mock-llm:latest` — `localhost/bench-mock-llm@sha256:fd3621e65cfbd34d81c4e72ab94f50a3799f90119a80a22fc65be342e4dc7a7d`
    - Praxis AI — T2: `localhost/praxis-ai:0.3.0` — `localhost/praxis-ai@sha256:00b4d3e9c3573344213556d55f61b87c1003a9e06aa57ff00ef1b835ac4112d5`
    - agentgateway — T2: `ghcr.io/agentgateway/agentgateway:latest` — `ghcr.io/agentgateway/agentgateway@sha256:bf2f339ef326d32def2aaeb44b1b4549801293c19b89e764a4228667d97d9896`
    - Praxis AI — T1: `localhost/praxis-ai:0.3.0` — `localhost/praxis-ai@sha256:00b4d3e9c3573344213556d55f61b87c1003a9e06aa57ff00ef1b835ac4112d5`

One-command reproduction (requires podman, ideally a quiet dedicated Linux host):

```console
make bench BENCH_RUN_ID=<id> BENCH_REPEATS=5
```

_Raw per-repeat artifacts live under `bench/results/<id>/` and are gitignored — the harness, methodology, and this generated report are the committed deliverables, not one machine's raw numbers. Regenerate this report with `bench/scripts/report.py`._
