# Praxis AI processing-path profile — 2026-09-08

Ad hoc CPU profile of `praxis-ai-proxy`, requested to direct performance
work following the [AI Gateway benchmark](../../reports/2026-09-08.md).
Not part of the regular bench harness — a one-off investigation, kept
here dated for traceability.

## Method

- Binary: `praxis-ai-proxy` built with the workspace's `profiling` cargo
  profile (release optimizations, debug symbols, unstripped — no
  benchmark-only flags).
- Run directly (not containerized) on the podman machine's Linux VM
  (Fedora CoreOS 42, aarch64, kernel 6.15.10) — closer to how Praxis
  actually ships than profiling on macOS.
- Config: the bench's own `bench/engines/praxis/gateway.yaml` (upstream
  address adjusted to the mock's VM-local port), same processing path as
  the benchmark: parse → route by `model` → count tokens.
- Load: `ab -k -c 50 -n 400000` against `bench/load/chat-unary.json`
  (same payload the bench uses), sustaining ~19k req/s.
- Captured with `perf record -F 999 -g --call-graph fp` for 25s
  overlapping the load window, inside a privileged Fedora container
  (`--pid=host`) targeting the live PID directly on the VM. Binary
  rebuilt with `RUSTFLAGS=-Cforce-frame-pointers=yes`.

**Revision note:** the first capture used `--call-graph dwarf`, which
failed to unwind userspace frames for this musl-static binary (a known
gap) — `flame.svg` was a flat bar with no caller chains. Re-captured with
frame-pointer unwinding instead (the standard fix), which resolved real
call trees up to 87 frames deep and let the findings below move from
"inferred from source" to "confirmed from an actual sampled stack" (see
Finding 1). The flat self-time percentages barely moved between captures
(e.g. `core::fmt::write` 7.67% → 7.34%), consistent with run-to-run noise
on the same workload, not a different measurement.

`flame.svg`'s time unit is **milliseconds of `task-clock` CPU time**
attributed to each call stack, aggregated across all threads over the
25s window (not wall-clock time) — labelled on every frame directly (not
just on hover): `name (P%)`, with the full `(N ms, P%)` in the tooltip.

## Files

- [`flame.svg`](flame.svg) — the profile, real call tree, percentages
  labelled on-frame
- [`hotspots.txt`](hotspots.txt) — self-time by symbol, extracted from
  the raw `perf report`, ≥0.4% only

## Findings

### 1. A confirmed, source-located hotspot: hex round-tripping response bytes through `core::fmt`

**~18% of total self-CPU** traces to one mechanism in
`filters/src/token_usage/count.rs`: response bytes are hex-encoded into
a `String` (stored in `filter_metadata` so state survives across filter
invocations between chunks) and later hex-decoded back to bytes — and
both directions go through `core::fmt`'s general Display/Write machinery
**one byte at a time**, not a dedicated hex codec:

```rust
// count.rs:685 (accumulate_response_hex) and :727 (set_hex_metadata)
for byte in chunk {
    _ = write!(hex_buf, "{byte:02x}");
}
```

This one pattern accounts for:

| Symbol | Self % |
|---|---|
| `core::fmt::write` | 7.34% |
| `<core::fmt::Formatter>::pad_integral` (+ `write_prefix`) | 2.84% + 1.08% |
| `<u8 as core::fmt::LowerHex>::fmt` | 2.29% |
| `<alloc::string::String as core::fmt::Write>::write_str` (×2 call sites) | 1.26% + 1.07% |
| `praxis_ai_filters::token_usage::count::decode_hex` | 1.85% |
| **Total (self-time)** | **~17.7%** |

**Confirmed, not inferred** — the frame-pointer capture resolved the real
call stack for this exact cluster. A representative sampled stack (top
frame first):

```
memcpy
<u8 as core::fmt::LowerHex>::fmt
core::fmt::write
<TokenCountFilter as HttpFilter>::on_response_body   <- filters/src/token_usage/count.rs
FilterPipeline::execute_http_response_body_with_response_header
PingoraHttpHandler::response_body_filter
...pingora_proxy internals...
```

`flame.svg`'s single largest labelled block is exactly this cluster: one
`core::fmt::write` node (with `pad_integral`/`LowerHex::fmt`/`memcpy`
nested inside it as child frames in the same branch) accounts for
**13.75% of all sampled CPU time by itself**, all under
`TokenCountFilter::on_response_body`. That single number is the cleanest
one to hand to whoever picks this up: nearly a seventh of total CPU time
in this benchmark is one filter's hex round-trip.

Two call sites within that filter, two different cost shapes:

- **Unary** (`accumulate_response_hex`, count.rs:666): appends only the
  new chunk's bytes to a persistent, growing hex string — O(total
  response bytes) overall, but each byte pays the slow `write!` path
  instead of a bulk hex-encode.
- **SSE streaming** (`save_sse_scan_state`/`load_sse_scan_state` via
  `set_hex_metadata`/`decode_hex`, count.rs:600-731): **fully re-encodes
  the scanner's pending `line_buf`/`data_buf` from scratch on every
  chunk** (`set_hex_metadata` builds a new `String` each call, it does
  not append). Bounded by roughly one SSE line/event, not the whole
  stream, so not quadratic in total response size — but still a full
  hex round-trip of live buffer state on every chunk boundary of every
  streaming response.

This directly contradicts this repo's own `AGENTS.md` data-ownership
principle ("Do not clone streaming chunks or provider payloads just to
satisfy local control flow"). The reason for hex-encoding at all is
documented in the code (`accumulate_response_hex`'s doc comment: "avoid
corruption when chunk boundaries split multibyte UTF-8 code points") —
`filter_metadata` is presumably `HashMap<String, String>`, so raw bytes
can't be stored directly. The fix is either a faster hex codec (bulk
encode/decode instead of per-byte `write!`, e.g. a lookup-table
implementation or the `hex` crate), or — better — carrying scanner state
as bytes through a typed extension rather than serializing through a
string map at all.

Not yet filed as an issue — flagging here first since it's a much more
precise and larger finding than what was reported verbally before this
profile's `hotspots.txt` was cross-referenced against source.

### 2. Residual formatting/logging cost (smaller than finding #1)

`nu_ansi_term::Style::write_prefix` (0.86%) and `<str as
core::fmt::Debug>::fmt` are consistent with the default ANSI-colored
tracing-subscriber fmt layer (`core/src/logging.rs`) doing per-request
span field formatting. This is real but small (~1%) — most of what
looked like a logging cost in the first read of this profile is actually
finding #1 above.

### 3. Unrelated: a config-watcher bug found via this same profiling session

Not a profiling result, but discovered while setting up this rig — the
process was rebuilding and swapping its pipeline every ~500ms
indefinitely with no config change, because `server/src/watcher.rs` has
no per-path event filter and no content-hash gate. Filed as
[praxis-proxy/ai#1015](https://github.com/praxis-proxy/ai/issues/1015).

## Not investigated further

- `__aarch64_cas4_acq`/`__aarch64_ldadd4_rel` family (~7% combined,
  atomic RMW) — the call tree is now available (`flame.svg`) to trace
  this to specific call sites; not yet done.
- `memcpy` (3.95%) — partly the hex-decode path in finding #1 (visible as
  a child frame under it in `flame.svg`), partly elsewhere; not fully
  broken down.
