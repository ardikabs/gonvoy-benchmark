# Envoy Filter Benchmark

Goal: compare Envoy header-filter mechanisms on contrib-v1.40 —
request/response header mutation cost across Lua, WASM, native Go, and Gonvoy.

## Variants

- `baseline` — no filter (reference)
- `lua` — Lua `envoy_on_request` / `envoy_on_response`
- `wasm` — WASM `on_http_request_headers` / `on_http_response_headers`
- `go` — native Go `on_http_request_headers` / `on_http_response_headers`
- `gonvoy` — Gonvoy SDK filter

All variants implement the canonical logic in [docs/FILTER_SPEC.md](docs/FILTER_SPEC.md).
Metrics are defined in [docs/METRICS.md](docs/METRICS.md).

## Quickstart

```bash
docker compose up
./scripts/run-benchmark.sh
```

## Results

See `results/` (raw nighthawk JSON under `results/raw/`, summary in `results/SUMMARY.md`).
