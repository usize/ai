# agentgateway — engine notes (fairness ledger)

Pinned image:
`ghcr.io/agentgateway/agentgateway@sha256:bf2f339ef326d32def2aaeb44b1b4549801293c19b89e764a4228667d97d9896`
(tag `latest` at capture time = **v1.5.0**, git `fe673247`).

## Processing path

agentgateway's `llm:` mode is a single LLM data path that **always** parses
the request body, routes by `model`, and reconciles token usage. There is
no configuration switch to route-by-model *without* metering tokens: the
schema's telemetry/metrics config (`RawMetrics`, `TracingConfig`,
`LoggingPolicy`) only controls **where** counts are emitted, not whether
they are computed.

That path is exactly the work the benchmark measures — parse, route by
`model`, count tokens — so the engine's natural mode is the measured mode
here, with no benchmark-only configuration bending it into a shape it does
not ship with. The Praxis config
([`../praxis/gateway.yaml`](../praxis/gateway.yaml)) is composed to do the
same three units of work and no more.

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
