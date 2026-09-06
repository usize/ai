# AI Gateway Benchmark Harness

A fair, reproducible comparison of the per-request cost of **AI request
processing** (parse body → route by model → count tokens) across AI
gateways. See the methodology for the full design and fairness contract:

- [`docs/proposals/00075_ai-gateway-benchmark-methodology.md`](../docs/proposals/00075_ai-gateway-benchmark-methodology.md)

This is a *separate, narrower* effort than the core-proxy overhead benchmark
in praxis-proxy/praxis#1082: here every engine does real AI work, and we
measure who does it more efficiently — not raw byte forwarding.

## Engines under test

| Engine | Runtime | Status |
|---|---|---|
| Praxis AI | Rust (Pingora) | planned (this repo) |
| agentgateway | Rust (Tokio + Hyper) | planned |
| Envoy AI Gateway | Envoy (C++) + ext_proc | planned (added after the two Rust engines) |

All three are OSS and freely publishable. Kong AI Gateway was considered
and dropped for v1 (`ai-proxy` is Enterprise-tier; benchmark-publication
terms unverified). Rationale is documented in the methodology.

## Layout

```
bench/
  mock-llm/     deterministic OpenAI-shaped mock upstream (unary + SSE)
  engines/      per-engine, per-tier configs (praxis/, agentgateway/, envoy-ai-gateway/)
  load/         vegeta targets / fortio parameters
  scripts/      runner + results processing
  results/      raw artifacts + generated charts (gitignored except .gitkeep)
```

## Processing tiers

- **T1** — parse request body + route by `model`.
- **T2** — T1 + token counting from provider-returned `usage`.

Each tier runs in **unary** and **SSE streaming** modes. Guardrails and
local tokenization are deferred (see methodology).

## Fairness rules (do not break these)

1. Every engine proxies to a **byte-identical** mock instance.
2. The harness **consumes SSE incrementally** — it must never buffer a
   streamed response before forwarding, or streaming numbers are invalid.
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
