# agentgateway — engine notes (fairness ledger)

Pinned image:
`ghcr.io/agentgateway/agentgateway@sha256:bf2f339ef326d32def2aaeb44b1b4549801293c19b89e764a4228667d97d9896`
(tag `latest` at capture time = **v1.5.0**, git `fe673247`).

## Tier separability: T1 and T2 are NOT separable

agentgateway's `llm:` mode is a single LLM data path that **always** parses
the request body, routes by `model`, and reconciles token usage. There is
no configuration switch to route-by-model *without* metering tokens: the
schema's telemetry/metrics config (`RawMetrics`, `TracingConfig`,
`LoggingPolicy`) only controls **where** counts are emitted, not whether
they are computed.

**Fairness consequence:** agentgateway has no true T1 (route-only) cell.
Its single config therefore represents **T2** (parse + route + token
count). When comparing against Praxis's T1 (which genuinely does route-only
via `model_to_header` + `router` with no token counting), this asymmetry
must be stated: agentgateway's "T1" number necessarily includes token
metering work Praxis's T1 does not do. Per the methodology's rule, we do
not fake a T1 cell for agentgateway — we disclose that T1 is not
separately measurable and compare its T2 against Praxis T2 as the honest
apples-to-apples row.

## Token counting

- `tokenize: false` (default) → **no local tiktoken**; usage comes from the
  provider-returned `usage` block, reconciled against a request-time
  estimate. This matches the v1 provider-usage-only rule.
- Setting `tokenize: true` would enable agentgateway's local tiktoken-rs
  path (documented as "expensive"). Left OFF for v1; a labeled
  local-tokenization variant is deferred.
- agentgateway forces `stream_options.include_usage=true` upstream for
  streaming, so the mock must emit a terminal usage frame (it does).

## Upstream host

`params.baseUrl: http://mock-llm:9000` — `baseUrl` expands to
`hostOverride` + `pathPrefix` + `tls`; an `http://` scheme selects plaintext
to the upstream. (`hostOverride`/`pathOverride` exist but are deprecated in
favor of `baseUrl`.)

## Ports (not part of the data path, but present)

Admin/UI `:15000`, stats `:15020`, readiness `:15021`. Only `:3000` (the
`llm.port`) carries benchmark traffic. Keep the others off the measured
path.
