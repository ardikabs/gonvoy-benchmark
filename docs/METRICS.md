# Metrics Comparison Matrix

Canonical metrics for comparing filter variants. Consumed by Task 7 (benchmark harness).

| Metric | Source | Higher/Lower better |
| --- | --- | --- |
| Achieved RPS | nighthawk `results` | Higher better |
| p50/p90/p95/p99 latency ms | HDR histogram | Lower better |
| Mean + stdev | nighthawk JSON | Lower better |
| Success rate % (2xx / total) | counters | Higher better |
| Error rate (5xx, pool failures, lua.errors) | counters | Lower better |
| Envoy CPU % avg | docker stats/pidstat | Lower better |
| Envoy RSS MB | docker stats | Lower better |
| RPS per CPU % (efficiency) | derived | Higher better |

## Decision rule

`gonvoy` is "worth it" if within 10% of native Go on p99 + RPS/CPU,
and beats at least one of Lua/WASM on p99 at same RPS.
