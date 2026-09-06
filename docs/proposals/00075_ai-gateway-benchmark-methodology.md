# AI Gateway Benchmark Methodology

Status: Draft
Related: praxis-proxy/praxis#1082 (core proxy overhead — separate effort)

## Purpose

Produce a **fair, reproducible, evidence-backed** comparison of the
per-request cost of *AI request processing* across AI gateways, for an
audience of AI Gateway buyers. The claim we want to be able to make is
about the overhead of doing the AI-specific work an AI gateway exists to
do — parsing inference requests, routing by model, and metering tokens —
not about raw byte forwarding.

This is deliberately **narrower** than issue #1082. That issue benchmarks
Praxis *core* against dumb L7 proxies (Envoy/NGINX/HAProxy) to measure raw
forwarding overhead. This methodology benchmarks *AI gateways doing AI
work*. Every engine under test parses the request body; the only question
is how efficiently. Framing it this way removes the most common objection
to AI-gateway benchmarks ("you benchmarked a passthrough proxy and called
it an AI gateway").

## Non-goals

- Raw L7 forwarding overhead (covered by #1082).
- Guardrails / content inspection / prompt-injection scanning. These are
  heavier and vary enormously by implementation; deferred to a later
  phase so the first published numbers stay defensible. (Streaming *is*
  in scope — see the response-mode axis.)
- Correctness/accuracy of token counts as a headline metric. We record it
  as a fairness check (see "Token-count parity"), not as a ranked result.
- Real-provider latency. We proxy to a mock upstream (see "Upstream").

## The fairness problem, stated plainly

"AI Gateway" is not one workload. A gateway that reverse-proxies bytes
will beat one that JSON-decodes every body, and comparing the two is
meaningless unless you are explicit that they are doing different work.
Our methodology controls this two ways:

1. **Matched processing tiers.** Every engine is configured to do the
   *same* AI work at each tier. We do not let one engine skip parsing
   while another parses.
2. **A per-engine processing ledger.** For every engine × tier × response
   mode we publish exactly what the engine does to the body (buffer the
   full body? parse incrementally? provider-usage vs local tokenization?
   buffer the SSE stream?). This is the fairness contract: any "they're
   not doing the same work" objection is answered with a table, not an
   assertion. Where an engine *cannot* be configured to match a tier, we
   say so and exclude that cell rather than pretending parity.

## Engines under test

| Engine | Runtime | AI logic location | Standalone? | Notes |
|---|---|---|---|---|
| **Praxis AI** | Rust (Pingora) | in-process filters | yes (container) | subject under test |
| **agentgateway** | Rust (Tokio + Hyper) | in-process, native | yes (container) | solo.io's *current* OSS AI data plane; also the AI data plane for kgateway ≥2.3 |
| **Envoy AI Gateway** | Envoy (C++) | ext_proc | yes (standalone) | OSS (Apache-2.0, CNCF/Envoy); Envoy-architecture data point |

All three engines are OSS and freely publishable.

### Why Envoy AI Gateway and not Kong AI Gateway

Kong AI Gateway was considered and dropped for this run. Kong's `ai-proxy`
/ `ai-proxy-advanced` plugins are **Enterprise-tier**: benchmarking them
requires a Kong Enterprise license, and — more importantly — publishing
results may be restricted by the Enterprise EULA (vendor benchmark /
"DeWitt" clauses are common). Rather than block publication on legal
review, we substitute **Envoy AI Gateway**: OSS (Apache-2.0, CNCF/Envoy),
standalone-runnable, and freely publishable. It also happens to be the
stronger competitive choice — a serious, architecturally-distinct engine
(Envoy/C++ + `ext_proc`) rather than an interpreted point that could read
as a strawman next to two Rust engines. Kong can be added to a later run
if licensing and benchmark-publication terms are cleared.

### Why agentgateway and not Gloo AI Gateway

Solo.io has two architecturally opposite AI data planes:

- **agentgateway** — Rust, Tokio+Hyper, AI logic in-process, standalone
  container, OSS. As of kgateway 2.3.0 this is the AI/LLM/MCP data plane
  for kgateway too.
- **Gloo AI Gateway** — Envoy (C++) + a **Python** `ai-extension` invoked
  out-of-process via Envoy `ext_proc` gRPC (one bidirectional stream per
  HTTP transaction). Kubernetes-only, enterprise-licensed.

For a fair *standalone container* benchmark, agentgateway is the correct
solo.io competitor: OSS, containerized, in-process — the closest
architectural peer to Praxis. Gloo AI Gateway's K8s + enterprise-license +
out-of-process-Python model makes an apples-to-apples standalone run
impossible without introducing confounds (K8s scheduling, gRPC hop,
Python GC). If we later want the Envoy+ext_proc architecture on the chart,
it is a separate, clearly-labeled configuration — not substituted for
agentgateway. This choice, and its rationale, is published.

## Processing tiers

Guardrails deferred. Two tiers, each subsuming the previous.

- **T1 — Parse + model-based routing.** Parse the JSON request body,
  extract the `model` field, route to the correct upstream cluster/model.
  This is the floor of any AI gateway; all three engines support it.
- **T2 — T1 + token counting / usage metering.** In addition to T1, count
  prompt + completion tokens and emit usage (headers and/or metadata),
  from the provider-returned `usage` where available.

Each tier is run in both response modes (below). We report per-tier so the
*marginal* cost of token metering (T2 − T1) is attributable, and the cost
of parse+route (T1 − mock-baseline) is isolated.

**Tier separability is engine-dependent (disclosed, not faked).** Not
every engine can be configured to do T1 *without* T2. Verified against
pinned images:

- **Praxis AI** — separable. `model_to_header` + `router` gives a genuine
  route-only T1; `token_count` adds T2. Both configs validated.
- **agentgateway** — **not separable**. Its `llm:` data path always parses,
  routes, *and* meters tokens; there is no route-only mode (telemetry
  config only controls where counts go, not whether they are computed).
  Its single config is therefore **T2**, and we do **not** publish a T1
  number for it. The honest apples-to-apples row is Praxis-T2 vs
  agentgateway-T2. (Verified against agentgateway v1.5.0.)
- **Envoy AI Gateway** — to be determined during its spike.

Where an engine lacks a separable T1, its T1 cell is left empty in the
results with this reason, rather than reporting a T2 number as if it were
T1.

## Response-mode axis (cross-cutting)

Every tier runs in both modes:

- **Unary** — single JSON response body.
- **SSE streaming** — `text/event-stream`, chunked, with a terminal usage
  event / `[DONE]`.

Streaming is where buffering honesty matters most. A harness that buffers
a streamed response before releasing it would unfairly penalize whichever
engine streams incrementally, and would flatter one that already buffers.
So in streaming mode we measure **time-to-first-byte (TTFB)** and
inter-chunk latency in addition to end-to-end, and the harness itself must
consume the stream incrementally (never buffer-then-forward).

## Per-engine processing ledger (fairness contract)

Grounded in source/docs review. This table is the heart of the
methodology; it is published alongside results and any cell that cannot be
matched is called out.

### Request body (T1, model routing) — all engines BUFFER the request body

| Engine | Request body handling |
|---|---|
| Praxis AI | Bounded buffer (`BodyMode::StreamBuffer`). `model_to_header`/`json_body_field` parses incrementally within the buffer with **early-exit** once `model` is found; classifier / `model_rewrite` do a full `serde_json` decode at end-of-stream. Native Rust parse, in-process. |
| agentgateway | Full buffer in-process (`read_body_with_limit`), native JSON parse to read `model`, apply aliases, inject `stream_options`. Source explicitly notes it buffers "just due to how our interface works." Rust, in-process. |
| Envoy AI Gateway | Envoy buffers the request body and hands it to the AI ext_proc processor to read/route on `model`. Body-parse work happens out-of-process relative to the Envoy worker (in the ext_proc processor). C++ core + ext_proc. |

Verdict: **request-body buffering is comparable across all three** — this
tier is fair. The differentiators are parse implementation (Rust vs Rust
vs Envoy/ext_proc) and *where* the parse runs (in the proxy worker for the
two Rust engines vs an ext_proc processor for Envoy AI Gateway). The
Envoy ext_proc hop is inherent to that engine's architecture, not a
handicap we impose; we disclose it in the ledger rather than hide it.

### Non-streaming response (T2, token counting)

| Engine | Non-streaming response handling |
|---|---|
| Praxis AI | Buffers the full JSON response (bounded, default 1 MiB) to locate `usage`, extracts **provider-returned** counts. No local tokenization. Overflow past cap → status header, extraction abandoned. |
| agentgateway | Buffered path (`buffer_response`) for non-streaming; provider `usage` reconciled against a request-time estimate. Optional local **tiktoken-rs** prompt tokenization gated by `tokenize` flag (default off; documented "expensive"). |
| Envoy AI Gateway | ext_proc processor reads the response body to extract provider `usage` and emit token metadata. Provider usage; buffered response body mode for non-streaming. |

Fairness lever: agentgateway's `tokenize` flag is a **local tokenization**
path that does more work than reading provider usage. To keep T2 matched,
the default T2 config uses **provider-returned usage only** on all three
(Praxis has no local tokenizer, so this is its only mode; agentgateway
`tokenize` is left off). A local-tokenization variant is deferred to a
later run (out of scope for v1 per the tight-scope decision).

### Streaming (SSE) response (T2, token counting) — all engines INCREMENTAL

| Engine | Streaming response handling |
|---|---|
| Praxis AI | `BodyMode::Stream`. Bounded incremental SSE scanner parses one completed event at a time; oversized events **dropped, not buffered**; provider usage read from the terminal event; counts finalized at end-of-stream. Never buffers the stream. |
| agentgateway | Incremental `SseDecoder` over chunks (`process_streaming`), forces `stream_options.include_usage=true`, parses usage from streamed events, finalizes at stream end. Never buffers the stream. |
| Envoy AI Gateway | ext_proc streamed response-body mode: the processor sees SSE chunks incrementally and tallies usage from streamed events / terminal frame. **Verify empirically** that the streamed (not buffered) ext_proc response-body mode is in effect — measure TTFB to confirm chunks are not withheld. |

Verdict: **all three stream incrementally** — this cell is fair *provided
the harness does not buffer* and *provided Envoy AI Gateway's ext_proc is
in streamed response-body mode* (confirm via TTFB). Disclosed asymmetry:
all three inject/require `include_usage` on the upstream request, so the
mock must emit a terminal usage event. The Envoy ext_proc streamed-mode
verification is an explicit gate before publishing streaming numbers.

### Known version/config hazards (must be pinned)

- **Envoy AI Gateway ext_proc response-body mode** must be *streamed*, not
  buffered, for the SSE cell — a buffered mode would make us measure
  buffering, not streaming. Gate publication of streaming numbers on a
  TTFB check that confirms incremental delivery.
- **agentgateway `tokenize`**: off for the matched T2 (v1 is
  provider-usage-only across all engines).
- Record each engine's exact image tag + **digest**, and the Envoy AI
  Gateway + ext_proc-processor versions.

## Upstream: deterministic mock LLM server

A single mock upstream isolates gateway overhead from provider variance
and makes results reproducible. Requirements:

- Speaks OpenAI Chat Completions request/response shapes (v1 is
  OpenAI-only; Anthropic Messages deferred to a later run).
- **Unary** and **SSE streaming** responses; streaming emits a terminal
  event carrying a `usage` object (so token metering has something real to
  read) followed by `[DONE]`.
- **Configurable fixed server-think latency** (e.g. 0 ms and a realistic
  fixed value) and **configurable per-token inter-chunk delay** for
  streaming, so TTFB and streaming overhead are measurable against a known
  baseline.
- Deterministic bodies across a small **payload-size matrix** (e.g. small
  / medium / large prompt, small / large completion) so body-parse cost
  scales visibly. Include a ~1000-token prompt point (a common size in
  published AI-gateway benchmarks, useful for cross-reference).
- Returns a valid, size-appropriate `usage` block matching the emitted
  content, so **token-count parity** can be checked.

The mock must be byte-identical for every engine. Its own baseline
(load generator → mock, no gateway) is measured and published as the
zero-overhead reference; all "added latency" numbers are relative to it.

## Load generation

- Primary: **vegeta** for open-loop, fixed-rate latency measurement, and
  **fortio** for throughput/concurrency sweeps — the same generators
  praxis-bench uses, so this harness aligns with the existing tooling and
  can fold into `praxis-bench` later. Used identically against every
  engine; the harness treats the generator as pluggable behind one runner.
- Fixed, published parameters: concurrency levels (a small sweep),
  duration, warmup, and target request rate(s). Same values for every
  engine.
- **Connection reuse on** (keep-alive) as the headline; a cold-connection
  variant as a secondary axis (per #1082's matrix vocabulary).
- TLS: terminate at the gateway in one variant, plaintext in another; hold
  constant across engines within a variant.

## Metrics

Aligned with #1082's vocabulary so both efforts speak the same language:

- **Added latency** P50 / P90 / P99 — end-to-end minus the mock baseline,
  per tier per mode.
- **TTFB** (streaming) P50 / P90 / P99.
- **Max sustained throughput** (RPS) at a fixed error-rate ceiling.
- **Resource footprint** — CPU and RSS of the gateway container at a
  target load (cgroup-measured, gateway container only).
- **Token-count parity** (fairness check, not a ranking): does each
  engine's reported usage match the mock's known values, unary and
  streaming? Divergence is disclosed, not scored.

## Reproducibility deliverables

Modeled on #1082's requirements:

1. Exact image tag **and digest** for every engine + the mock.
2. Harness version/commit, load-generator version, full parameter set.
3. Hardware profile (instance type, vCPU, RAM, kernel).
4. Every engine config file, checked in, doing exactly its tier's work.
5. Raw result artifacts + the generated charts.
6. The processing ledger above, published with the results.
7. A one-command reproduction (`make bench` or equivalent).

## Settled decisions (v1)

- **Engines:** Praxis AI, agentgateway, Envoy AI Gateway (Kong dropped for
  licensing/publication risk; all three engines OSS and publishable).
- **Fairness model:** matched processing tiers + published per-engine ledger.
- **Tiers:** T1 (parse+route), T2 (+token count); guardrails deferred.
- **Response modes:** unary + SSE streaming.
- **Upstream:** deterministic mock LLM (OpenAI shape).
- **Load gen:** vegeta + fortio (aligns with praxis-bench).
- **Scope:** tight v1 — OpenAI shape, provider-usage-only token counting.
  Local tokenization and Anthropic Messages deferred.
- **Harness home:** `praxis-proxy/ai`, harness under `bench/`, engine
  configs under `examples/configs/` (or `bench/engines/`), this doc under
  `docs/proposals/`. Designed to fold into `praxis-bench` later.

## Open questions for review

1. **Envoy AI Gateway standalone footprint:** confirm it runs cleanly as a
   standalone container (Envoy + ext_proc processor) without Kubernetes for
   the benchmark; capture exact image tags for both components.
2. **Envoy ext_proc streamed response-body mode:** verify empirically (TTFB
   check) before publishing streaming numbers — see hazards.
3. **Concurrency sweep + target rates:** pick the specific vegeta rate steps
   and fortio concurrency levels for the headline profile.
4. **Fold into praxis-bench:** timing of migrating this harness into the
   shared benchmarks repo once v1 is stable.

## Appendix: primary sources

- Praxis processing: source review of `apis/src/classifier/`,
  `apis/src/openai/responses/model_rewrite/`,
  `filters/src/inference/model_to_header.rs`,
  `filters/src/token_usage/{count,streaming,providers,headers}.rs`;
  design principle `AGENTS.md` ("Do not buffer full streaming responses").
- agentgateway / solo.io: agentgateway.dev, github.com/agentgateway
  (`crates/agentgateway/src/llm/`, `crates/llm/src/tokenizer.rs`),
  kgateway README (2.3.0 dual-data-plane migration), docs.solo.io (Gloo AI
  Gateway ext_proc + Python ai-extension — the *rejected* alternative).
- Envoy AI Gateway: aigateway.envoyproxy.io / github.com/envoyproxy/ai-gateway
  (ext_proc-based AI routing + token metering; confirm streamed ext_proc
  response-body mode and standalone deployment).
- Kong (considered, dropped): developer.konghq.com (ai-proxy is
  Enterprise-tier), Kong/kong #12680 (stream-buffering bug fixed post-3.6),
  Kong's public AI Gateway benchmark (WireMock upstream, k6, 400 VUs,
  1000-token prompts) — retained as a methodology cross-reference.
