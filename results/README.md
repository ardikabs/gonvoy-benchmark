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

Conformance is deliberately NOT scored here: the known gonvoy response
`server`/`x-drop-me` leak (parked ruling, backend-echo artifact) is a
correctness issue tracked against `docs/FILTER_SPEC.md`, not a performance
penalty, so the parser reports it nowhere and penalizes nothing.
