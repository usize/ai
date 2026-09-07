#!/usr/bin/env python3
"""Aggregate a multi-repeat AI-gateway benchmark run.

Given a run directory that contains repeat sub-directories (rep-1/, rep-2/, ...),
each holding the per-cell artifacts that run.sh produces, this computes the
median and standard deviation of each headline metric ACROSS repeats, for each
engine. Single-shot numbers are noise on a shared machine; the median of N
independent stack-up/measure/tear-down cycles is what we publish, with the
stddev disclosed so readers can judge stability.

If a "baseline" cell is present (the mock published with no gateway, see
bench/engines/baseline), its median latency is subtracted from every engine
cell to report *added* latency — the cost the gateway itself imposes.

Usage:
  bench/scripts/aggregate.py bench/results/<run-id>

Reuses the raw-artifact readers from summarize.py so there is a single source
of truth for how vegeta/fortio/resources are parsed.
"""
import pathlib
import statistics
import sys

import summarize

BASELINE_CELL = "baseline"


def median(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return statistics.median(xs) if xs else None


def stddev(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return statistics.stdev(xs) if len(xs) > 1 else 0.0


def collect_cell(rep_dirs, cell_name):
    """Gather each metric across all repeats for one cell. Returns a dict of
    metric -> list-of-per-repeat-values (missing repeats simply contribute
    fewer samples; we never invent a value)."""
    acc = {k: [] for k in (
        "u50", "u90", "u99", "s50", "s99", "qps", "cpu", "mem", "u_success",
    )}
    gates = []
    for rep in rep_dirs:
        cell = rep / cell_name
        if not cell.is_dir():
            continue
        unary = summarize.load_json(cell / "vegeta-unary.json") or {}
        stream = summarize.load_json(cell / "vegeta-stream.json") or {}
        fortio = summarize.load_json(cell / "fortio-unary.json") or {}
        cpu, mem = summarize.parse_resources(cell / "resources.csv")
        u = summarize.vegeta_latencies_ms(unary)
        s = summarize.vegeta_latencies_ms(stream)
        acc["u50"].append(u.get("50"))
        acc["u90"].append(u.get("90"))
        acc["u99"].append(u.get("99"))
        acc["s50"].append(s.get("50"))
        acc["s99"].append(s.get("99"))
        acc["qps"].append(summarize.fortio_qps(fortio))
        acc["cpu"].append(cpu)
        acc["mem"].append(mem)
        su = unary.get("success")
        if su is not None:
            acc["u_success"].append(su * 100)
        gates.append(summarize.ttfb_verdict(cell / "ttfb.txt"))
    return acc, gates


def gate_summary(gates):
    """PASS only if EVERY repeat passed; otherwise surface the failure."""
    gates = [g for g in gates if g and g != "n/a"]
    if not gates:
        return "n/a"
    passed = sum(1 for g in gates if g.startswith("PASS"))
    if passed == len(gates):
        return f"PASS ({passed}/{len(gates)})"
    return f"FAIL ({passed}/{len(gates)} passed)"


def cell_names(rep_dirs):
    names = set()
    for rep in rep_dirs:
        for c in rep.iterdir():
            if c.is_dir():
                names.add(c.name)
    return sorted(names)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    run_dir = pathlib.Path(sys.argv[1])
    if not run_dir.is_dir():
        print(f"no such run dir: {run_dir}", file=sys.stderr)
        sys.exit(1)

    rep_dirs = sorted(
        d for d in run_dir.iterdir() if d.is_dir() and d.name.startswith("rep-")
    )
    if not rep_dirs:
        print(
            f"no rep-* sub-directories in {run_dir}; is this a multi-repeat run?",
            file=sys.stderr,
        )
        sys.exit(1)

    names = cell_names(rep_dirs)

    # Baseline latency floor (median across repeats), if the baseline cell ran.
    base_u50 = base_s50 = None
    if BASELINE_CELL in names:
        acc, _ = collect_cell(rep_dirs, BASELINE_CELL)
        base_u50 = median(acc["u50"])
        base_s50 = median(acc["s50"])

    print(f"# Benchmark summary: {run_dir.name} ({len(rep_dirs)} repeats)\n")
    if base_u50 is not None:
        print(
            f"_Baseline (mock, no gateway) median unary P50 = {base_u50:.2f}ms, "
            f"stream P50 = {base_s50:.2f}ms. \"added\" columns subtract this floor._\n"
        )
    hdr = (
        "| engine | unary P50 (±sd) | added P50 | unary P99 | "
        "stream P50 | max qps | peak CPU% | peak mem MB | stream gate | success |"
    )
    print(hdr)
    print("|" + "---|" * 10)

    def cell(v, suffix="", sd=None):
        if not isinstance(v, (int, float)):
            return "—"
        if sd is not None and sd > 0:
            return f"{v:.2f}±{sd:.2f}{suffix}"
        return f"{v:.2f}{suffix}"

    for name in names:
        acc, gates = collect_cell(rep_dirs, name)
        u50 = median(acc["u50"])
        added = (
            u50 - base_u50
            if (u50 is not None and base_u50 is not None and name != BASELINE_CELL)
            else None
        )
        print(
            f"| {name} "
            f"| {cell(u50, 'ms', stddev(acc['u50']))} "
            f"| {cell(added, 'ms') if added is not None else '—'} "
            f"| {cell(median(acc['u99']), 'ms')} "
            f"| {cell(median(acc['s50']), 'ms')} "
            f"| {cell(median(acc['qps']))} "
            f"| {cell(median(acc['cpu']))} "
            f"| {cell(median(acc['mem']))} "
            f"| {gate_summary(gates)} "
            f"| {cell(median(acc['u_success']), '%')} |"
        )

    print(
        "\n_Medians across independent repeats (fresh stack per repeat); ±sd is "
        "the sample standard deviation. \"added P50\" = this cell's median unary "
        "P50 minus the baseline floor. Stream gate must be PASS on every repeat "
        "to publish streaming numbers. See docs/proposals/00075 for methodology._"
    )


if __name__ == "__main__":
    main()
