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
- Captured with `perf record -F 999 -g --call-graph dwarf` for 25s
  overlapping the load window, inside a privileged Fedora container
  (`--pid=host`) targeting the live PID directly on the VM.

**Caveat:** userspace call-tree (DWARF) unwinding failed for this
binary — likely the known gap with musl-static Rust binaries — so
`flame.svg` is closer to a flat bar chart than a true call tree; no
caller chains could be recovered. The flat **self-time-by-symbol**
breakdown (`hotspots.txt`, `flame.svg`) is reliable: corroborated by
correctly-resolved jemalloc symbols (`_rjem_sdallocx`, `do_rallocx`)
matching the `tikv-jemallocator` dependency actually compiled in.

## Files

- [`flame.svg`](flame.svg) — the profile, rendered (flat, per unwinding caveat above)
- [`hotspots.txt`](hotspots.txt) — self-time by symbol, extracted from the raw `perf report`, ≥0.5% only

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
| `core::fmt::write` | 7.67% |
| `<core::fmt::Formatter>::pad_integral` (+ `write_prefix`) | 2.87% + 0.96% |
| `<u8 as core::fmt::LowerHex>::fmt` | 2.21% |
| `<alloc::string::String as core::fmt::Write>::write_str` (×2 call sites) | 1.37% + 1.20% |
| `praxis_ai_filters::token_usage::count::decode_hex` | 1.90% |
| **Total** | **~18.2%** |

Two call sites, two different cost shapes:

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

### 2. Residual formatting/logging cost (smaller than initially estimated)

`nu_ansi_term::Style::write_prefix` (0.76%) and `<str as
core::fmt::Debug>::fmt` (0.56%) are consistent with the default
ANSI-colored tracing-subscriber fmt layer (`core/src/logging.rs`) doing
per-request span field formatting. This is real but small (~1.3%) — most
of what looked like a logging cost in the initial read of this profile
is actually finding #1 above.

### 3. Unrelated: a config-watcher bug found via this same profiling session

Not a profiling result, but discovered while setting up this rig — the
process was rebuilding and swapping its pipeline every ~500ms
indefinitely with no config change, because `server/src/watcher.rs` has
no per-path event filter and no content-hash gate. Filed as
[praxis-proxy/ai#1015](https://github.com/praxis-proxy/ai/issues/1015).

## Not investigated further

- `__aarch64_cas4_acq`/`__aarch64_ldadd4_rel` family (~9.5% combined,
  atomic RMW) — plausibly `Arc` clone/drop traffic; not source-attributed.
- `memcpy` (3.92%) — expected for a proxying data path; not confirmed
  whether any of it is an avoidable copy per the data-ownership policy.
- Full call-tree attribution — blocked on the musl DWARF-unwind gap
  noted above.
