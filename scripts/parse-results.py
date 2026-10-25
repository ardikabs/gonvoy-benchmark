#!/usr/bin/env python3
"""Parse Task 7 benchmark raw output into results/summary.md.

Input:  <raw-dir>/<variant>-<rps>-<rep>.json  (nighthawk --output-format json)
        <raw-dir>/<variant>-<rps>-<rep>.stats.csv (docker stats samples)
Output: markdown table Variant | RPS target | RPS achieved | p50 | p90 | p95
        | p99 | err% | CPU% | RSS MB | RPS/CPU plus a verdict line per target
        RPS implementing the docs/METRICS.md decision rule.

Latency p50/p90/p95/p99 are computed from the nighthawk HDR histogram
statistic `benchmark_http_client.request_to_response` by linear
interpolation over its reported percentile points (nighthawk 0.3.0 does not
emit an exact p99 point, hence interpolation).

Conformance note (parked ruling): the gonvoy variant is known to leak the
`server` / `x-drop-me` response headers (backend echo artifact). This parser
deliberately does NOT penalize that here -- it reports performance only
(latency/RPS/CPU). Conformance is tracked separately per FILTER_SPEC.

Usage:
  python3 scripts/parse-results.py [--raw-dir results/raw]
      [--output results/summary.md]
"""
import argparse
import csv
import glob
import json
import os
import re
import sys
from collections import defaultdict

LAT_STAT = "benchmark_http_client.request_to_response"

DUR_RE = re.compile(r"^\s*([\d.]+)\s*([a-zµu]*s?)?\s*$", re.IGNORECASE)


def parse_duration(x):
    """Parse nighthawk duration strings ('0.0025s', '0s') or numbers to sec."""
    if isinstance(x, (int, float)):
        return float(x)
    m = DUR_RE.match(str(x))
    if not m:
        raise ValueError(f"unparseable duration: {x!r}")
    v, unit = float(m.group(1)), (m.group(2) or "s").lower()
    mult = {"s": 1.0, "ms": 1e-3, "us": 1e-6, "µs": 1e-6, "ns": 1e-9}
    if unit not in mult:
        raise ValueError(f"unknown duration unit: {x!r}")
    return v * mult[unit]


def quantile(points, q):
    """Linear interpolation over sorted (quantile, value_secs) points."""
    pts = sorted(points)
    if q <= pts[0][0]:
        return pts[0][1]
    if q >= pts[-1][0]:
        return pts[-1][1]
    for (q0, v0), (q1, v1) in zip(pts, pts[1:]):
        if q0 <= q <= q1:
            if q1 == q0:
                return v0
            t = (q - q0) / (q1 - q0)
            return v0 + t * (v1 - v0)
    return pts[-1][1]


# Token-based (split on . and _) so that e.g. "default.total_match_count"
# (which contains the substring "fault" in "default") is NOT an error.
FAIL_TOKENS = frozenset({
    "5xx", "overflow", "reset", "resets", "timeout", "timeouts",
    "failure", "failures", "failed", "aborted", "faults", "errors",
    "unhealthy", "excluded", "retry", "retries",
})
OK_NAMES = frozenset({"runtime.load_success"})


def split_counters(counters):
    """Return (ok_2xx, err_5xx, fail_other, total) from nighthawk counters."""
    vals = {}
    for c in counters:
        try:
            vals[c["name"]] = int(c["value"])
        except (KeyError, ValueError, TypeError):
            continue
    http_status = {k: v for k, v in vals.items()
                   if re.search(r"http_[234]xx", k) or re.search(r"upstream_rq_[234]xx", k)}
    ok = sum(v for k, v in http_status.items() if "_2xx" in k)
    err5 = sum(v for k, v in http_status.items() if "_5xx" in k)
    fails = 0
    for k, v in vals.items():
        if k in OK_NAMES or "_2xx" in k or "_3xx" in k or "_4xx" in k:
            continue
        tokens = set(re.split(r"[._]", k.lower()))
        if tokens & FAIL_TOKENS:
            fails += v
    if http_status:
        total = sum(http_status.values())
    elif "upstream_rq_total" in vals:
        total = vals["upstream_rq_total"]
    else:
        total = ok + err5
    return ok, err5, fails, total


def parse_nighthawk(path):
    with open(path) as f:
        doc = json.load(f)
    results = doc.get("results", [])
    g = next((r for r in results if r.get("name") == "global"), None)
    if g is None:
        raise ValueError(f"{path}: no 'global' result")
    stats = {s["id"]: s for s in g.get("statistics", [])}
    if LAT_STAT not in stats:
        raise ValueError(f"{path}: missing statistic {LAT_STAT}")
    st = stats[LAT_STAT]
    pts = [(float(p["percentile"]), parse_duration(p["duration"]))
           for p in st.get("percentiles", [])]
    if not pts:
        raise ValueError(f"{path}: empty percentiles in {LAT_STAT}")
    lat = {f"p{int(q*100)}": quantile(pts, q) * 1000.0
           for q in (0.50, 0.90, 0.95, 0.99)}
    lat["mean_ms"] = parse_duration(st.get("mean", 0)) * 1000.0
    lat["stdev_ms"] = parse_duration(st.get("pstdev", 0)) * 1000.0
    lat["count"] = int(st.get("count", 0))
    ok, err5, fails, total = split_counters(g.get("counters", []))
    if total == 0:
        total = lat["count"]
    dur_s = parse_duration(g.get("execution_duration", 0))
    achieved = (total / dur_s) if dur_s > 0 else 0.0
    err_pct = ((err5 + fails) / total * 100.0) if total > 0 else 0.0
    return {
        **lat,
        "ok_2xx": ok, "err_5xx": err5, "fail_other": fails,
        "total": total, "achieved_rps": achieved,
        "err_pct": err_pct, "duration_s": dur_s,
    }


def parse_stats_csv(path):
    """Mean CPU% and RSS MiB from a sampler CSV; (None, None, 0) if absent."""
    if not os.path.exists(path):
        return None, None, 0
    cpus, mems = [], []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            try:
                if row.get("cpu_pct") not in (None, ""):
                    cpus.append(float(row["cpu_pct"]))
                if row.get("mem_used_mib") not in (None, ""):
                    mems.append(float(row["mem_used_mib"]))
            except ValueError:
                continue
    n = max(len(cpus), len(mems))
    cpu = sum(cpus) / len(cpus) if cpus else None
    mem = sum(mems) / len(mems) if mems else None
    return cpu, mem, n


def parse_filename(path):
    base = os.path.basename(path)
    m = re.match(r"^(.*)-(\d+)-(\d+)\.json$", base)
    if not m:
        raise ValueError(f"unexpected filename (want <variant>-<rps>-<rep>.json): {base}")
    return m.group(1), int(m.group(2)), int(m.group(3))


def mean(xs):
    xs = [x for x in xs if x is not None]
    return (sum(xs) / len(xs)) if xs else None


def fmt(x, digits=3):
    return f"{x:.{digits}f}" if x is not None else "n/a"


def verdict_for_rps(rows_by_variant, rps):
    """Implement docs/METRICS.md: gonvoy 'worth it' iff within 10% of native
    Go on p99 + RPS/CPU, and beats at least one of Lua/WASM on p99."""
    need = ("gonvoy", "go-native")
    if any(v not in rows_by_variant for v in need):
        return "INCONCLUSIVE (missing gonvoy or go-native data)"
    g, n = rows_by_variant["gonvoy"], rows_by_variant["go-native"]
    if g["p99"] is None or n["p99"] is None:
        return "INCONCLUSIVE (missing p99)"
    p99_gap = (g["p99"] - n["p99"]) / n["p99"] if n["p99"] else float("inf")
    eff_txt, eff_ok = "n/a", None
    if g["rps_cpu"] is not None and n["rps_cpu"] not in (None, 0):
        gap = (n["rps_cpu"] - g["rps_cpu"]) / n["rps_cpu"]
        eff_txt = f"{gap:+.1%}"
        eff_ok = gap <= 0.10
    p99_ok = p99_gap <= 0.10
    contenders = {v: rows_by_variant[v]["p99"] for v in ("lua", "wasm")
                  if v in rows_by_variant and rows_by_variant[v]["p99"] is not None}
    if not contenders:
        beat_txt = "no lua/wasm data"
        beat_ok = None
    else:
        beaten = sorted(v for v, p in contenders.items() if g["p99"] < p)
        beat_txt = ("beats " + "+".join(beaten)) if beaten else \
            f"beats none (gonvoy {g['p99']:.3f}ms vs " + \
            ", ".join(f"{v} {p:.3f}ms" for v, p in sorted(contenders.items())) + ")"
        beat_ok = bool(beaten)
    parts = [f"p99 gap vs go-native {p99_gap:+.1%} ({'OK' if p99_ok else 'MISS'})",
             f"RPS/CPU gap {eff_txt}" + (f" ({'OK' if eff_ok else 'MISS'})" if eff_ok is not None else ""),
             beat_txt]
    oks = [o for o in (p99_ok, eff_ok, beat_ok) if o is not None]
    if not oks:
        verdict = "INCONCLUSIVE"
    elif all(oks):
        verdict = "PASS: gonvoy is worth it"
    else:
        verdict = "FAIL: gonvoy is not worth it"
    return f"{verdict} at {rps} RPS -- " + "; ".join(parts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw-dir", default="results/raw")
    ap.add_argument("--output", default="results/summary.md")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.raw_dir, "*-*.json")))
    if not files:
        print(f"no raw JSON found in {args.raw_dir}", file=sys.stderr)
        sys.exit(1)

    # (variant, target_rps) -> list of per-rep dicts
    runs = defaultdict(list)
    for path in files:
        try:
            variant, rps, rep = parse_filename(path)
        except ValueError as e:
            print(f"skip: {e}", file=sys.stderr)
            continue
        try:
            m = parse_nighthawk(path)
        except (ValueError, KeyError, json.JSONDecodeError) as e:
            print(f"skip {path}: {e}", file=sys.stderr)
            continue
        cpu, mem, n = parse_stats_csv(os.path.splitext(path)[0] + ".stats.csv")
        m.update({"rep": rep, "cpu_pct": cpu, "rss_mib": mem, "stats_n": n})
        runs[(variant, rps)].append(m)

    # aggregate reps by mean
    agg = {}
    for (variant, rps), reps in sorted(runs.items()):
        a = {
            "variant": variant, "target_rps": rps, "reps": len(reps),
            "achieved_rps": mean([r["achieved_rps"] for r in reps]),
            "p50": mean([r["p50"] for r in reps]),
            "p90": mean([r["p90"] for r in reps]),
            "p95": mean([r["p95"] for r in reps]),
            "p99": mean([r["p99"] for r in reps]),
            "err_pct": mean([r["err_pct"] for r in reps]),
            "cpu_pct": mean([r["cpu_pct"] for r in reps]),
            "rss_mib": mean([r["rss_mib"] for r in reps]),
        }
        a["rps_cpu"] = (a["achieved_rps"] / a["cpu_pct"]
                        if a["achieved_rps"] is not None and a["cpu_pct"] else None)
        agg[(variant, rps)] = a

    rps_levels = sorted({r for _, r in agg})
    lines = []
    lines.append("# Benchmark summary")
    lines.append("")
    lines.append(f"Raw input: `{args.raw_dir}/*.json` + `*.stats.csv` "
                 f"({sum(len(v) for v in runs.values())} measured runs). "
                 "Latency percentiles are HDR `request_to_response` "
                 "(interpolated p50/p90/p95/p99, ms). "
                 "CPU%/RSS are mean `docker stats` samples of the envoy "
                 "container during each run. "
                 "Env snapshot: `results/raw/env.txt`, pinned digests: "
                 "`results/raw/meta.txt`.")
    lines.append("")
    lines.append("Conformance is NOT scored here: the known gonvoy response")
    lines.append("`server`/`x-drop-me` leak (parked ruling) is a correctness")
    lines.append("issue tracked separately, not a performance penalty.")
    lines.append("")
    for rps in rps_levels:
        lines.append(f"## Target {rps} RPS")
        lines.append("")
        lines.append("| Variant | RPS achieved | p50 (ms) | p90 (ms) | p95 (ms) | "
                     "p99 (ms) | err% | CPU% | RSS (MB) | RPS/CPU | reps |")
        lines.append("|---|---|---|---|---|---|---|---|---|---|---|")
        for (variant, r), a in sorted(agg.items()):
            if r != rps:
                continue
            lines.append(
                f"| {variant} | {fmt(a['achieved_rps'], 1)} | {fmt(a['p50'])} | "
                f"{fmt(a['p90'])} | {fmt(a['p95'])} | {fmt(a['p99'])} | "
                f"{fmt(a['err_pct'], 2)} | {fmt(a['cpu_pct'], 1)} | "
                f"{fmt(a['rss_mib'], 1)} | {fmt(a['rps_cpu'], 2)} | {a['reps']} |")
        by_variant = {v: a for (v, r), a in agg.items() if r == rps}
        lines.append("")
        lines.append(f"Verdict: {verdict_for_rps(by_variant, rps)}.")
        lines.append("")
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w") as f:
        f.write("\n".join(lines))
    print(f"wrote {args.output} ({len(agg)} variant@rps cells)")


if __name__ == "__main__":
    main()
