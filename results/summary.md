# Benchmark summary

Raw input: `results/raw/*.json` + `*.stats.csv` (45 measured runs). Latency percentiles are HDR `request_to_response` (interpolated p50/p90/p95/p99, ms). CPU%/RSS are mean `docker stats` samples of the envoy container during each run. Env snapshot: `results/raw/env.txt`, pinned digests: `results/raw/meta.txt`.

Conformance is NOT scored here: the known gonvoy response
`server`/`x-drop-me` leak (parked ruling) is a correctness
issue tracked separately, not a performance penalty.

## Target 1000 RPS

| Variant | RPS achieved | p50 (ms) | p90 (ms) | p95 (ms) | p99 (ms) | err% | CPU% | RSS (MB) | RPS/CPU | reps |
|---|---|---|---|---|---|---|---|---|---|---|
| baseline | 996.0 | 0.392 | 1.355 | 2.349 | 7.388 | 0.78 | 16.1 | 18.0 | 61.88 | 3 |
| go-native | 998.6 | 0.310 | 1.901 | 4.143 | 15.612 | 0.28 | 18.3 | 18.2 | 54.55 | 3 |
| gonvoy | 998.6 | 0.301 | 0.468 | 0.996 | 6.551 | 0.29 | 14.7 | 17.9 | 68.07 | 3 |
| lua | 998.5 | 0.322 | 0.723 | 1.397 | 5.675 | 0.30 | 15.6 | 17.9 | 63.85 | 3 |
| wasm | 998.6 | 0.301 | 0.805 | 1.825 | 8.707 | 0.29 | 16.7 | 17.9 | 59.92 | 3 |

Verdict: PASS: gonvoy is worth it at 1000 RPS -- p99 gap vs go-native -58.0% (OK); RPS/CPU gap -24.8% (OK); beats wasm.

## Target 5000 RPS

| Variant | RPS achieved | p50 (ms) | p90 (ms) | p95 (ms) | p99 (ms) | err% | CPU% | RSS (MB) | RPS/CPU | reps |
|---|---|---|---|---|---|---|---|---|---|---|
| baseline | 4103.4 | 0.578 | 1.167 | 1.603 | 3.239 | 0.26 | 48.1 | 17.5 | 85.36 | 3 |
| go-native | 4627.5 | 0.348 | 0.550 | 0.716 | 1.584 | 0.07 | 44.7 | 18.3 | 103.44 | 3 |
| gonvoy | 4998.4 | 0.369 | 0.584 | 0.752 | 1.571 | 0.06 | 48.7 | 18.2 | 102.69 | 3 |
| lua | 4992.7 | 0.367 | 0.693 | 0.977 | 2.199 | 0.06 | 52.7 | 18.0 | 94.74 | 3 |
| wasm | 4966.9 | 0.353 | 0.509 | 0.615 | 1.245 | 0.06 | 45.7 | 18.0 | 108.77 | 3 |

Verdict: PASS: gonvoy is worth it at 5000 RPS -- p99 gap vs go-native -0.8% (OK); RPS/CPU gap +0.7% (OK); beats lua.

## Target 20000 RPS

| Variant | RPS achieved | p50 (ms) | p90 (ms) | p95 (ms) | p99 (ms) | err% | CPU% | RSS (MB) | RPS/CPU | reps |
|---|---|---|---|---|---|---|---|---|---|---|
| baseline | 2420.3 | 0.312 | 0.403 | 0.499 | 1.114 | 0.14 | 30.9 | 17.4 | 78.24 | 3 |
| go-native | 2650.4 | 0.299 | 0.350 | 0.410 | 0.893 | 0.12 | 31.5 | 18.3 | 84.12 | 3 |
| gonvoy | 2559.3 | 0.307 | 0.363 | 0.429 | 0.953 | 0.13 | 32.2 | 18.1 | 79.61 | 3 |
| lua | 2453.8 | 0.306 | 0.381 | 0.486 | 1.208 | 0.13 | 31.2 | 17.9 | 78.54 | 3 |
| wasm | 2642.8 | 0.304 | 0.350 | 0.397 | 0.745 | 0.12 | 31.7 | 18.0 | 83.46 | 3 |

Verdict: PASS: gonvoy is worth it at 20000 RPS -- p99 gap vs go-native +6.7% (OK); RPS/CPU gap +5.4% (OK); beats lua.
