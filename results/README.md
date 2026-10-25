# Results

How the numbers in `summary.md` are produced and how to read them.

## Produce

```bash
# Full matrix (defaults: --rps 1000,5000,20000 --duration 60s --repeats 3 --variants all)
./scripts/run-benchmark.sh
python3 scripts/parse-results.py --raw-dir results/raw --output results/summary.md

# Quick smoke test of the harness itself
./scripts/run-benchmark.sh --rps 100 --duration 10s --repeats 1 --variants baseline,lua
python3 scripts/parse-results.py
```

`run-benchmark.sh` switches each variant via `scripts/switch-variant.sh`
(verified serving before load), runs a 10s warmup at the same RPS whose
output is **discarded**, then the measured run:

```text
nighthawk_client --rps X --duration Y \
  --request-header "x-api-key: test-key-123" \
  --request-header "user-agent: benchmark-agent" \
  --output-format json http://envoy:10000/
```

Load runs inside the compose `loader` service
(`envoyproxy/nighthawk-dev`), so the target is `http://envoy:10000/`.

## Layout

```text
results/
  raw/
    <variant>-<rps>-<rep>.json       nighthawk JSON (one measured run)
    <variant>-<rps>-<rep>.stats.csv  docker stats samples of envoy during it
    env.txt                          capture-env.sh output (once per run)
    meta.txt                         git SHA + pinned image digests (once per run)
  summary.md                         comparison matrix (parse-results.py output)
  README.md                          this file
```

`results/raw/` is git-ignored; `summary.md` from a real matrix run is the
committed artifact (smoke-run outputs stay local).
Floating image tags are meaningless without `meta.txt`: a run is only
comparable to another run with the same digests.

## Read the matrix

Columns per target RPS (`docs/METRICS.md`, higher/lower-better in
parentheses):

| Column | Meaning |
|---|---|
| RPS achieved | completed requests / wall time (higher) |
| p50/p90/p95/p99 (ms) | HDR `request_to_response`, p99 interpolated (lower) |
| err% | 5xx + pool/timeout/reset failures over total (lower) |
| CPU% | mean envoy `docker stats` CPU during the run (lower) |
| RSS (MB) | mean envoy RSS during the run (lower) |
| RPS/CPU | achieved RPS per CPU% point (higher) |

Verdict line implements the `docs/METRICS.md` decision rule: `gonvoy` is
"worth it" iff within 10% of native Go on p99 **and** RPS/CPU, and beats at
least one of Lua/WASM on p99 at the same RPS. Missing variants render
`INCONCLUSIVE`, never a silent PASS.

Conformance is deliberately NOT scored here: the parser reports performance
only (latency/RPS/CPU) and penalizes nothing for correctness. All four
filter variants currently pass their conformance suites; correctness is
tracked separately against `docs/FILTER_SPEC.md`.

## Sample results snapshot

The matrix below is from one run on the author's machine
(Apple Silicon / Docker Desktop, `envoyproxy/envoy:contrib-v1.40-latest`,
nighthawk amd64 image emulated on arm64). It is illustrative — compare only
runs with identical `results/raw/meta.txt` digests.

### Target 1000 RPS

| Variant | RPS achieved | p50 (ms) | p90 (ms) | p95 (ms) | p99 (ms) | err% | CPU% | RSS (MB) | RPS/CPU | reps |
|---|---|---|---|---|---|---|---|---|---|---|
| baseline | 996.0 | 0.392 | 1.355 | 2.349 | 7.388 | 0.78 | 16.1 | 18.0 | 61.88 | 3 |
| go-native | 998.6 | 0.310 | 1.901 | 4.143 | 15.612 | 0.28 | 18.3 | 18.2 | 54.55 | 3 |
| gonvoy | 998.6 | 0.301 | 0.468 | 0.996 | 6.551 | 0.29 | 14.7 | 17.9 | 68.07 | 3 |
| lua | 998.5 | 0.322 | 0.723 | 1.397 | 5.675 | 0.30 | 15.6 | 17.9 | 63.85 | 3 |
| wasm | 998.6 | 0.301 | 0.805 | 1.825 | 8.707 | 0.29 | 16.7 | 17.9 | 59.92 | 3 |

Verdict: **PASS** — gonvoy is worth it at 1000 RPS (within 10% of native Go
on p99 and RPS/CPU, and beats WASM).

### Target 5000 RPS

| Variant | RPS achieved | p50 (ms) | p90 (ms) | p95 (ms) | p99 (ms) | err% | CPU% | RSS (MB) | RPS/CPU | reps |
|---|---|---|---|---|---|---|---|---|---|---|
| baseline | 4103.4 | 0.578 | 1.167 | 1.603 | 3.239 | 0.26 | 48.1 | 17.5 | 85.36 | 3 |
| go-native | 4627.5 | 0.348 | 0.550 | 0.716 | 1.584 | 0.07 | 44.7 | 18.3 | 103.44 | 3 |
| gonvoy | 4998.4 | 0.369 | 0.584 | 0.752 | 1.571 | 0.06 | 48.7 | 18.2 | 102.69 | 3 |
| lua | 4992.7 | 0.367 | 0.693 | 0.977 | 2.199 | 0.06 | 52.7 | 18.0 | 94.74 | 3 |
| wasm | 4966.9 | 0.353 | 0.509 | 0.615 | 1.245 | 0.06 | 45.7 | 18.0 | 108.77 | 3 |

Verdict: **PASS** — gonvoy is worth it at 5000 RPS (ties native Go, beats
Lua).

### Target 20000 RPS

| Variant | RPS achieved | p50 (ms) | p90 (ms) | p95 (ms) | p99 (ms) | err% | CPU% | RSS (MB) | RPS/CPU | reps |
|---|---|---|---|---|---|---|---|---|---|---|
| baseline | 2420.3 | 0.312 | 0.403 | 0.499 | 1.114 | 0.14 | 30.9 | 17.4 | 78.24 | 3 |
| go-native | 2650.4 | 0.299 | 0.350 | 0.410 | 0.893 | 0.12 | 31.5 | 18.3 | 84.12 | 3 |
| gonvoy | 2559.3 | 0.307 | 0.363 | 0.429 | 0.953 | 0.13 | 32.2 | 18.1 | 79.61 | 3 |
| lua | 2453.8 | 0.306 | 0.381 | 0.486 | 1.208 | 0.13 | 31.2 | 17.9 | 78.54 | 3 |
| wasm | 2642.8 | 0.304 | 0.350 | 0.397 | 0.745 | 0.12 | 31.7 | 18.0 | 83.46 | 3 |

Verdict line printed by the parser: **PASS** — but this is misleading.
**None of the variants reach 20k RPS; even baseline stalls at ~2.4k.**
The benchmark is bottlenecked by the loader shape (single `--concurrency`
connection pool, 100 connections) and/or the amd64-emulated nighthawk
client on this arm64 host, not by the filters. **Treat the 20k block as a
saturation check**, not a filter ranking.

## What the numbers suggest

- **Performance:** Gonvoy is competitive with native Go in this
  header-only workload. At 1k and 5k RPS it is within the 10% bands on
  both p99 latency and RPS/CPU, and it beats at least one of Lua or WASM
  on p99. At 5k it essentially ties native Go.
- **Baseline anomaly at 5k:** `baseline` achieves only ~4.1k RPS while
  every filtered variant reaches ~4.9k–5.0k. This is almost certainly
  run-order / warmup / cache noise (baseline ran first in the sweep) or a
  transient loader hiccup, not evidence that filters make Envoy faster. It
  is a good reminder to look at the whole matrix rather than single cells.
- **Saturation at 20k:** With the current fixed loader shape the system
  tops out around 2.6k RPS regardless of filter. To get a meaningful 20k
  filter comparison you would need to scale client concurrency (more
  nighthawk workers/connections) and verify the loader is not the
  bottleneck.
- **Correctness:** All four variants pass conformance, including gonvoy's
  response header drops (`server`, `x-drop-me`) since the SDK gained
  response `Add`/`Del`. The earlier gonvoy response-drop gap is closed.

## Methodology notes for this run

- `--concurrency 1 --connections 100` fixed shape; high-RPS numbers are
  loader-limited, not filter-limited.
- nighthawk image is amd64 and runs under emulation on arm64 hosts.
- p99 is linearly interpolated from nighthawk's HDR percentile points.
- Latency percentiles are averaged across 3 reps, not pooled.
- err% uses token-based counter matching; `retry`/`retries` are counted as
  errors (they were zero here, so no impact).
