#!/usr/bin/env python3
"""Summarize an AI-gateway benchmark run into a comparison table.

Reads the per-engine artifacts under bench/results/<run-id>/ and prints a
Markdown table of the headline metrics (added latency percentiles, throughput,
resource footprint, streaming-fairness verdict). This is the machine-readable
bridge from raw vegeta/fortio output to published results — it does not invent
numbers, only aggregates what the runner recorded.

Usage:
  bench/scripts/summarize.py bench/results/<run-id>
"""
import json
import pathlib
import sys


def load_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def ms(seconds):
    """vegeta reports latency in nanoseconds; fortio in seconds. Callers pass
    the already-correct unit — this just formats."""
    return f"{seconds:.2f}"


def vegeta_latencies_ms(doc):
    """vegeta JSON latencies are in nanoseconds, keyed as 50th/90th/99th."""
    lat = doc.get("latencies", {})
    out = {}
    for pct, key in (("50", "50th"), ("90", "90th"), ("99", "99th")):
        if key in lat:
            out[pct] = lat[key] / 1e6
    return out


def fortio_qps(doc):
    return doc.get("ActualQPS")


def parse_resources(path):
    """Return (peak_cpu_perc, peak_mem_mb) from the sampler CSV."""
    if not path.exists():
        return None, None
    peak_cpu = 0.0
    peak_mem = 0.0
    for line in path.read_text().splitlines()[1:]:
        parts = line.split(",")
        if len(parts) < 2:
            continue
        try:
            cpu = float(parts[0])
        except ValueError:
            cpu = 0.0
        # mem field looks like "7.455MB / 1.074GB"
        mem_str = parts[1].split("/")[0].strip()
        mem_mb = to_mb(mem_str)
        peak_cpu = max(peak_cpu, cpu)
        peak_mem = max(peak_mem, mem_mb)
    return peak_cpu, peak_mem


def to_mb(s):
    s = s.strip()
    for unit, mult in (("GB", 1024), ("MB", 1), ("kB", 1 / 1024), ("B", 1 / 1024 / 1024)):
        if s.endswith(unit):
            try:
                return float(s[: -len(unit)]) * mult
            except ValueError:
                return 0.0
    return 0.0


def ttfb_verdict(path):
    if not path.exists():
        return "n/a"
    for line in path.read_text().splitlines():
        if line.startswith("streaming_fairness_gate:"):
            return line.split(":", 1)[1].strip()
    return "n/a"


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    run_dir = pathlib.Path(sys.argv[1])
    if not run_dir.is_dir():
        print(f"no such run dir: {run_dir}", file=sys.stderr)
        sys.exit(1)

    rows = []
    for cell in sorted(run_dir.iterdir()):
        if not cell.is_dir():
            continue
        unary = load_json(cell / "vegeta-unary.json") or {}
        stream = load_json(cell / "vegeta-stream.json") or {}
        fortio = load_json(cell / "fortio-unary.json") or {}
        cpu, mem = parse_resources(cell / "resources.csv")
        u = vegeta_latencies_ms(unary)
        s = vegeta_latencies_ms(stream)
        rows.append(
            {
                "cell": cell.name,
                "u50": u.get("50"),
                "u90": u.get("90"),
                "u99": u.get("99"),
                "s50": s.get("50"),
                "s99": s.get("99"),
                "qps": fortio_qps(fortio),
                "cpu": cpu,
                "mem": mem,
                "stream_gate": ttfb_verdict(cell / "ttfb.txt"),
                "u_success": unary.get("success"),
            }
        )

    print(f"# Benchmark summary: {run_dir.name}\n")
    print(
        "| engine-tier | unary P50 | unary P90 | unary P99 | stream P50 | "
        "stream P99 | max qps | peak CPU% | peak mem MB | stream gate | unary success |"
    )
    print("|" + "---|" * 12)
    for r in rows:
        def fmt(v, suffix=""):
            return f"{v:.2f}{suffix}" if isinstance(v, (int, float)) else "—"

        print(
            f"| {r['cell']} "
            f"| {fmt(r['u50'],'ms')} | {fmt(r['u90'],'ms')} | {fmt(r['u99'],'ms')} "
            f"| {fmt(r['s50'],'ms')} | {fmt(r['s99'],'ms')} "
            f"| {fmt(r['qps'])} | {fmt(r['cpu'])} | {fmt(r['mem'])} "
            f"| {r['stream_gate']} "
            f"| {fmt((r['u_success'] or 0)*100,'%') if r['u_success'] is not None else '—'} |"
        )

    print(
        "\n_Latencies are end-to-end through the gateway to the mock upstream. "
        "Subtract the mock baseline cell (if measured) for added latency. "
        "Streaming gate must read PASS for streaming numbers to be fair to "
        "publish. See docs/proposals/00075 for methodology._"
    )


if __name__ == "__main__":
    main()
