# Envoy Filter Benchmark

Goal: compare Envoy header-filter mechanisms on contrib-v1.40 —
request/response header mutation cost across Lua, WASM, native Go, and Gonvoy.

## Variants

- `baseline` — no filter (reference)
- `lua` — Lua `envoy_on_request` / `envoy_on_response`
- `wasm` — WASM `on_http_request_headers` / `on_http_response_headers`
- `go` — native Go `on_http_request_headers` / `on_http_response_headers`
  (variant name `go-native` in scripts, filter name `go` on the wire)
- `gonvoy` — Gonvoy SDK filter

All variants implement the canonical logic in [docs/FILTER_SPEC.md](docs/FILTER_SPEC.md).
Metrics are defined in [docs/METRICS.md](docs/METRICS.md).
Results layout and matrix reading guide: [results/README.md](results/README.md).

## Prerequisites

- Docker + `docker compose` (Envoy, backend, nighthawk loader all run in containers)
- Host ports free: `10000` (Envoy listener), `9901` (Envoy admin),
  `8081` (direct-backend debug), and **`8080`** (the per-variant smoke tests
  start a stub upstream on host `127.0.0.1:8080`)
- For rebuilding filters: Go 1.26 toolchain (note: if your shell exports a
  stale `GOROOT`, run go as `env -u GOROOT go ...`), Rust with the
  `wasm32-unknown-unknown` target for the WASM filter
- Pinned images (re-pinned at every bench run into `results/raw/meta.txt`):
  `envoyproxy/envoy:contrib-v1.40-latest`,
  `mendhak/http-https-echo:latest`, `envoyproxy/nighthawk-dev:latest`

## Build all filter artifacts

Lua needs no build (`filters/lua/filter.lua` is inlined into
`envoy/envoy-lua.yaml`; the smoke test asserts they match). The rest:

```bash
# Native Go (.so loaded by Envoy at /lib/bench-go.so)
cd filters/go-native && go build -buildmode=c-shared -o bench-go.so .

# Gonvoy (.so loaded by Envoy at /lib/gonvoy.so).
# -buildmode=c-shared needs a Linux C toolchain: on macOS without a cross
# compiler, build inside the golang image instead:
cd filters/gonvoy && go build -o gonvoy.so -buildmode=c-shared .
docker run --rm -v "$PWD:/src" -w /src golang:1.26-bookworm \
  go build -o gonvoy.so -buildmode=c-shared .

# WASM (.wasm loaded by Envoy at /lib/bench_header.wasm)
bash filters/wasm-rust/build.sh
# (= rustup target add wasm32-unknown-unknown, then
#   cargo build --release --target wasm32-unknown-unknown)
```

`*.so`, `*.wasm`, and `target/` are git-ignored build products: they must
exist locally (the smoke tests fail static checks without them) but are never
committed. Fresh checkouts also need network for `go mod download`
(`filters/*/go.sum` are untracked by convention).

## Boot and switch variants

```bash
docker compose up -d backend            # echo backend (also on host :8081)
./scripts/switch-variant.sh lua         # baseline|lua|wasm|go-native|gonvoy
```

`switch-variant.sh` recreates the `envoy` service with
`envoy/envoy-${FILTER_VARIANT}.yaml`, waits for admin `/ready`, then curls
the data path and asserts the `x-resp-added` marker for the active filter
(absent for `baseline`). It prints `PASS: <variant>` on success.
No custom Envoy image is used: the stock `contrib-v1.40` image (contrib, not
distroless — the golang filter is absent from the standard build) bind-mounts
the configs and plugin artifacts.

## Smoke: conformance tests

```bash
for t in tests/test_*.sh; do bash "$t" || exit 1; done
```

Each suite runs static checks (no docker needed: source patterns, artifact
presence, YAML structure, `envoy --mode validate`) plus a live curl matrix
(docker needed: stub upstream on host `:8080`, per-variant Envoy on host
`:10000`). Expected results:

| Suite | Result |
|---|---|
| `test_lua.sh` | PASS 35/35 |
| `test_wasm.sh` | PASS 43/43 |
| `test_go_native.sh` | PASS 46/46 |
| `test_gonvoy.sh` | 46/50 — the 4 failures are the **known parked gonvoy response-drop leak** (cases A/B `response omits server` + `response omits x-drop-me`), so the loop exits nonzero at gonvoy by design |

There is no `test_baseline.sh`; baseline serving is covered by
`./scripts/switch-variant.sh baseline` (HTTP 200, no `x-resp-added`).

Port-conflict note: the suites each bind host `:10000` for their own Envoy
and `:8080` for the stub. Bring the compose stack down first
(`docker compose down`) and make sure nothing else holds those ports —
a stale test container or an unrelated service on `:8080` fails the run
with `bind: address already in use` (or, worse, curls hitting the wrong
backend). Each suite cleans up its containers on exit.

## Benchmark

```bash
# Full matrix (defaults: --rps 1000,5000,20000 --duration 60s --repeats 3
# --variants all --warmup 10s --results-dir results/raw)
./scripts/run-benchmark.sh
python3 scripts/parse-results.py --raw-dir results/raw --output results/summary.md

# Mini end-to-end proof (small sweep, all variants)
./scripts/run-benchmark.sh --rps 500 --duration 15s --repeats 1 --variants all
python3 scripts/parse-results.py --raw-dir results/raw --output results/summary.md
```

Per `<variant, rps, rep>` combo the harness switches the variant (serving
verified before load), runs a 10s warmup at the same RPS whose output is
**discarded**, then the measured `nighthawk_client` run
(`x-api-key: test-key-123`, `user-agent: benchmark-agent`,
`--output-format json`, target `http://envoy:10000/`) while sampling envoy
`docker stats` to `<variant>-<rps>-<rep>.stats.csv`. Once per invocation it
captures `env.txt` (`capture-env.sh`) plus git SHA and pinned image digests
(`meta.txt`). `results/raw/` is git-ignored; only `results/summary.md` from a
real matrix run is committed (mini-sweep outputs stay local).

## Interpret the matrix

Per target RPS (`docs/METRICS.md`):

| Column | Meaning | Better |
|---|---|---|
| RPS achieved | completed requests / wall time | Higher |
| p50/p90/p95/p99 (ms) | HDR `request_to_response` (p99 interpolated — nighthawk emits no exact p99 point) | Lower |
| err% | 5xx + pool/timeout/reset failures over total | Lower |
| CPU% | mean envoy `docker stats` CPU during the run | Lower |
| RSS (MB) | mean envoy RSS during the run | Lower |
| RPS/CPU | achieved RPS per CPU% point | Higher |

**Gonvoy verdict rule** (`docs/METRICS.md`): `gonvoy` is "worth it" iff it is
within 10% of native Go on p99 **and** RPS/CPU, and beats at least one of
Lua/WASM on p99 at the same RPS. The parser prints a verdict line per target
RPS; missing variants render `INCONCLUSIVE`, never a silent PASS. Conformance
is deliberately not scored in the matrix (see known limitations).

## Machine constraints (runs are only comparable on the same machine)

- Compare variants only within a single matrix run on one host. Cross-machine
  or cross-day comparisons are meaningless without identical `meta.txt`
  digests — floating tags (`:latest`) must be pinned/digested at bench time.
- The nighthawk image is amd64-only and runs emulated on arm64 hosts. At low
  RPS this is fine; before trusting high-RPS numbers (e.g. 20k), sanity-check
  loader-side CPU to rule out the loader as the bottleneck.
- Close noisy neighbors, keep the compose stack as the only load on the box,
  and keep the 10s warmup (discarded) so JIT/warm caches don't skew rep 1.

## Known limitations (parked, not fixed)

- **Gonvoy response-drop leak.** `gonvoy.Context` (pinned main-branch
  pseudo-version `v0.4.1-0.20261025063629-248bc5dacb81`) exposes only
  `SetHeader` for responses — no response Add/Del — so the spec's response
  drops (`server`, `x-drop-me`) cannot conform. Request-side Add/Del work.
  Fix needs a gonvoy upstream `DelHeader`/`AddHeader` on `Context`. The
  benchmark parser deliberately reports performance only and penalizes
  nothing for this; `test_gonvoy.sh` documents it as 4/50 expected failures.
- **Vacuous `server` assertion in lua/wasm/go suites.** Those suites assert
  `nohdr <case> ^server`, which greps for the literal pattern `^^server:`
  and can never match — the `server` omission check passes trivially there
  (only `test_gonvoy.sh` uses the corrected `nohdr <case> server`).
  Backport pending; response-drop conformance for lua/wasm/go therefore rests
  on config inspection, not on a live assertion.
- **Task 7 minors (future work).** Single-connection load (`--concurrency`
  not raised with RPS, so high-RPS runs may serialize on one connection);
  parser approximations (linear p99 interpolation, token-based error-counter
  matching). Adequate for relative comparison, revisit before publishing
  absolute numbers.

## Results

See `results/` (raw nighthawk JSON under `results/raw/`, summary in
`results/summary.md`, method in `results/README.md`).
