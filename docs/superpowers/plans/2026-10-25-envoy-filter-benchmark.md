# Envoy HTTP Filter Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Build a reproducible benchmark repo comparing Envoy HTTP header-manipulation filters (baseline, Lua, WASM Rust, native Go, gonvoy Go) on Envoy `contrib-v1.40`.

**Architecture:** Five identical Envoy configs differing only in `http_filters` block, sharing one tiny upstream; Docker Compose for envoy+backend+loader; shell harness runs fixed-RPS sweep + saturation, collects Nighthawk JSON + `docker stats`, Python parser emits markdown comparison matrix.

**Tech Stack:** Envoy `envoyproxy/envoy:contrib-v1.40-latest`, Lua (LuaJIT inline), Rust `proxy-wasm 0.2` → `wasm32-unknown-unknown` on `envoy.wasm.runtime.v8`, Go `1.26` (`github.com/envoyproxy/envoy v1.40.0` + `github.com/ardikabs/gonvoy` latest), Nighthawk client + `fortio` fallback, Docker Compose, Python 3.11 parser.

**Spec:** User request 2026-10-25: gateway-like header-only filter (Set/Add/Drop request + response headers, simple request-header conditional, no body/trailers); load test under machine constraints; higher-is-better / lower-is-better matrix to judge gonvoy production-readiness vs Lua/WASM and vs native Go.

## Global Constraints

- Envoy image MUST be `envoyproxy/envoy:contrib-v1.40-latest` for all variants (Go filter is contrib-only).
- Filter logic MUST be byte-identical behavior across all 4 filters (canonical spec in Task 1); no local replies, always `Continue`.
- No body/trailers access: Lua only `headers()`, WASM only `on_http_request/response_headers`, Go only `DecodeHeaders/EncodeHeaders`, gonvoy default (no `OpenBodyAccess`, no `Read/Write*Body`).
- Upstream MUST be identical for all runs (single `http-echo` or `direct_response`; chosen in Task 6 and reused).
- Each run MUST pin Envoy concurrency, warm up, fixed duration, 3 repeats.
- Every built artifact's build command MUST be in README (`.so` via `c-shared`, `.wasm` via `cargo build --release --target wasm32-unknown-unknown`); binaries themselves stay git-ignored while dependency lockfiles (`filters/*/go.sum`, `filters/wasm-rust/Cargo.lock`) ARE committed.
- Machine info (CPU, RAM, `nproc`, `docker info`) MUST be captured per run for comparability.

## Review Focus

- Lua `pairs()` mutation during iteration silently skips headers — expect test that iterates + mutates separately.
- WASM `get_http_request_header` returns `None` on missing key vs empty string — expect test for missing `x-api-key` path.
- Native Go `HeaderMap.Get` returns `(string,bool)`; ignoring `bool` misclassifies missing vs empty — expect test for both.
- gonvoy `c.Header()` vs `c.SetHeader()` naming confusion (request vs response context) — expect test asserting response header lands on encoded response, not request.
- Nighthawk vs upstream saturation misattributed to filter (upstream bottleneck looks like filter regression) — expect test that baseline RPS >> target RPS before comparing filters.

---

### Task 1: Repo scaffold + canonical filter spec

**Files:**
- Create: `README.md`
- Create: `docs/FILTER_SPEC.md`
- Create: `docs/METRICS.md`
- Create: `.gitignore`
- Create: `scripts/capture-env.sh`

**Interfaces:**
- Consumes: none (first task)
- Produces: `FILTER_SPEC.md` canonical header logic consumed by Tasks 2-5; `METRICS.md` matrix consumed by Task 7; `capture-env.sh` consumed by Task 7.

- [x] **Step 1: Write `docs/FILTER_SPEC.md` with canonical logic**

Canonical logic (exact values all filters must implement):

```markdown
Request (Decode / envoy_on_request / on_http_request_headers):
- IF x-api-key == "test-key-123": Set x-auth-status=authenticated
- ELSE: Set x-auth-status=unauthenticated + Add x-auth-retry=true
- IF user-agent contains "benchmark": Set x-bench-tag=<filter-name>
- ELSE: Add x-bench-tag=<filter-name>-default
- Set x-request-touched=true (replace)
- Set x-filter-type=<filter-name> (replace)
- Drop x-drop-me (remove)
- Always continue (no local reply)

Response (Encode / envoy_on_response / on_http_response_headers):
- Add x-resp-added=<filter-name>
- Set x-resp-version=v1 (replace)
- Set x-gateway=envoy-<filter-name> (replace)
- Drop server + Drop x-drop-me
- Always continue

where <filter-name> in {lua, wasm, go, gonvoy}
```

- [x] **Step 2: Write `docs/METRICS.md` comparison matrix**

Content must define table:

| Metric | Source | Higher/Lower better |
|---|---|---|
| Achieved RPS | nighthawk `results` | Higher better |
| p50/p90/p95/p99 latency ms | HDR histogram | Lower better |
| Mean + stdev | nighthawk JSON | Lower better |
| Success rate % (2xx / total) | counters | Higher better |
| Error rate (5xx, pool failures, lua.errors) | counters | Lower better |
| Envoy CPU % avg | docker stats/pidstat | Lower better |
| Envoy RSS MB | docker stats | Lower better |
| RPS per CPU % (efficiency) | derived | Higher better |

Plus decision rule: gonvoy is "worth it" if within 10% of native Go on p99 + RPS/CPU, and beats at least one of Lua/WASM on p99 at same RPS.

- [x] **Step 3: Write `scripts/capture-env.sh`**

```bash
#!/bin/bash
# prints: uname -a, nproc, free/total mem, docker info, envoy --version
```

- [x] **Step 4: Write `README.md` skeleton + `.gitignore`**

README sections: goal, variants (baseline/lua/wasm/go/gonvoy), quickstart (`docker compose up`, `./scripts/run-benchmark.sh`), results link. `.gitignore`: `*.so`, `*.wasm`, `target/`, `results/raw/`, `__pycache__/`.

- [x] **Step 5: Verify files exist**

Run: `ls -R . && cat docs/FILTER_SPEC.md | head -20`
Expected: PASS (all 5 files present, spec contains `x-auth-status`)

- [x] **Step 6: Commit**

```bash
git add README.md docs/FILTER_SPEC.md docs/METRICS.md .gitignore scripts/capture-env.sh
git commit -m "docs: add canonical filter spec and metrics matrix"
```

---

### Task 2: Lua filter + Envoy config

**Files:**
- Create: `filters/lua/filter.lua`
- Create: `envoy/envoy-lua.yaml`
- Create: `tests/test_lua.sh`

**Interfaces:**
- Consumes: `docs/FILTER_SPEC.md` canonical logic
- Produces: `envoy/envoy-lua.yaml` pattern consumed by Task 6 (baseline derived by stripping filter block)

- [x] **Step 1: Write failing smoke test `tests/test_lua.sh`**

```bash
#!/bin/bash
# starts envoy:contrib-v1.40-latest with envoy-lua.yaml, curls with/without x-api-key,
# asserts x-auth-status, x-resp-added=lua, no server header. Fails until filter.lua exists.
```

Assertions: `curl -H "x-api-key: test-key-123" → x-auth-status: authenticated`; without key → `unauthenticated`; response has `x-resp-added: lua`, no `server:`.

- [x] **Step 2: Run test to verify it fails**

Run: `bash tests/test_lua.sh`
Expected: FAIL ( envoy config or filter.lua missing)

- [x] **Step 3: Implement `filters/lua/filter.lua` per spec**

Exact function names: `envoy_on_request(request_handle)`, `envoy_on_response(response_handle)`. Use `headers():get/add/replace/remove` only. No body calls. Branch on `x-api-key == "test-key-123"` string equality + `string.find(user-agent, "benchmark", 1, true)` plain find.

- [x] **Step 4: Implement `envoy/envoy-lua.yaml`**

Listener `0.0.0.0:10000`, `HttpConnectionManager`, `http_filters: [envoy.filters.http.lua (inline_string from filter.lua), envoy.filters.http.router]`, route `prefix: /` → cluster `backend:8080` (placeholder; Task 6 wires real upstream). `stat_prefix: ingress_http`.

- [x] **Step 5: Run test to verify it passes**

Run: `bash tests/test_lua.sh`
Expected: PASS (all curl assertions green)

- [x] **Step 6: Commit**

```bash
git add filters/lua/filter.lua envoy/envoy-lua.yaml tests/test_lua.sh
git commit -m "feat: add Lua header filter and envoy config"
```

---

### Task 3: WASM Rust filter + Envoy config

**Files:**
- Create: `filters/wasm-rust/Cargo.toml`
- Create: `filters/wasm-rust/src/lib.rs`
- Create: `envoy/envoy-wasm.yaml`
- Create: `filters/wasm-rust/build.sh`
- Create: `tests/test_wasm.sh`

**Interfaces:**
- Consumes: `docs/FILTER_SPEC.md`
- Produces: `filters/wasm-rust/bench_header.wasm` artifact path `filters/wasm-rust/target/wasm32-unknown-unknown/release/bench_header.wasm` consumed by Task 6 compose mount.

- [x] **Step 1: Write failing test `tests/test_wasm.sh`**

Same curl assertions as Lua but `x-bench-tag: wasm`, `x-resp-added: wasm`. Fails until `.wasm` built.

- [x] **Step 2: Run test to verify it fails**

Run: `bash tests/test_wasm.sh`
Expected: FAIL

- [x] **Step 3: Implement `filters/wasm-rust/Cargo.toml` + `src/lib.rs`**

`Cargo.toml`: `crate-type = ["cdylib"]`, `proxy-wasm = "0.2"`. `lib.rs`: `RootContext → HttpContext`, `on_http_request_headers` / `on_http_response_headers` returning `Action::Continue`, using `get_/set_/add_/remove_http_request/response_header` only. Same branch logic as spec with `<filter-name>=wasm`.

- [x] **Step 4: Implement `filters/wasm-rust/build.sh` + `envoy/envoy-wasm.yaml`**

`build.sh`: `rustup target add wasm32-unknown-unknown; cargo build --release --target wasm32-unknown-unknown`. Envoy snippet: `envoy.filters.http.wasm` with `vm_config.runtime: envoy.wasm.runtime.v8`, `filename: /lib/bench_header.wasm`, `root_id: bench_root`.

- [x] **Step 5: Build + run test to verify it passes**

Run: `bash filters/wasm-rust/build.sh && bash tests/test_wasm.sh`
Expected: PASS

- [x] **Step 6: Commit**

```bash
git add filters/wasm-rust/Cargo.toml filters/wasm-rust/src/lib.rs filters/wasm-rust/build.sh envoy/envoy-wasm.yaml tests/test_wasm.sh
git commit -m "feat: add WASM Rust header filter and envoy config"
```

---

### Task 4: Native Go filter + Envoy config

**Files:**
- Create: `filters/go-native/go.mod`
- Create: `filters/go-native/filter.go`
- Create: `filters/go-native/build.sh`
- Create: `envoy/envoy-go-native.yaml`
- Create: `tests/test_go_native.sh`

**Interfaces:**
- Consumes: `docs/FILTER_SPEC.md`
- Produces: `filters/go-native/bench-go.so` + `plugin_name: bench-go` consumed by Task 6; establishes behavior baseline for Task 5 gonvoy comparison.

- [x] **Step 1: Write failing test `tests/test_go_native.sh`**

Same curl matrix, expects `x-resp-added: go`, `x-gateway: envoy-go`. Fails until `.so` built.

- [x] **Step 2: Run test to verify it fails**

Run: `bash tests/test_go_native.sh`
Expected: FAIL

- [x] **Step 3: Implement `filters/go-native/filter.go` with signature `func (f *filter) DecodeHeaders(h api.RequestHeaderMap, _ bool) api.StatusType` and `EncodeHeaders`**

Use `h.Get/Set/Add/Del` only, check `ok` bool for missing `x-api-key`, `strings.Contains(ua, "benchmark")`, return `api.Continue`. Register via `http.RegisterHttpFilterFactoryAndConfigParser("bench-go", ...)`. `go.mod`: `module bench-go-native`, `go 1.26`, `require github.com/envoyproxy/envoy v1.40.0`.

- [x] **Step 4: Implement `filters/go-native/build.sh` + `envoy/envoy-go-native.yaml`**

`build.sh`: `go build -buildmode=c-shared -o bench-go.so .`. Envoy: `envoy.filters.http.golang` with `library_id: bench-go-id`, `library_path: /lib/bench-go.so`, `plugin_name: bench-go`.

- [x] **Step 5: Build + run test to verify it passes**

Run: `bash filters/go-native/build.sh && bash tests/test_go_native.sh`
Expected: PASS

- [x] **Step 6: Commit**

```bash
git add filters/go-native/go.mod filters/go-native/filter.go filters/go-native/build.sh envoy/envoy-go-native.yaml tests/test_go_native.sh
git commit -m "feat: add native Go header filter and envoy config"
```

---

### Task 5: Gonvoy filter + Envoy config

**Files:**
- Create: `filters/gonvoy/go.mod`
- Create: `filters/gonvoy/main.go`
- Create: `filters/gonvoy/handler.go`
- Create: `filters/gonvoy/build.sh`
- Create: `envoy/envoy-gonvoy.yaml`
- Create: `tests/test_gonvoy.sh`

**Interfaces:**
- Consumes: `docs/FILTER_SPEC.md`; mirrors Task 4 behavior with `<filter-name>=gonvoy`
- Produces: `filters/gonvoy/gonvoy.so` + `plugin_name: bench-gonvoy` consumed by Task 6/7.

- [x] **Step 1: Write failing test `tests/test_gonvoy.sh`**

Same curl matrix, expects `x-resp-added: gonvoy`, `x-gateway: envoy-gonvoy`. Fails until implemented.

- [x] **Step 2: Run test to verify it fails**

Run: `bash tests/test_gonvoy.sh`
Expected: FAIL

- [x] **Step 3: Implement `filters/gonvoy/handler.go` as `func BenchHandler(c gonvoy.Context) error` + `main.go` with `envoy.Handle("bench-gonvoy", gonvoy.Use(BenchHandler))` in `init()`**

Use `c.Header/SetHeader` (check gonvoy Context API: request-header read, set/add/drop equivalents) only, no body APIs. Branch identical to spec. Return `nil` always (passthrough). `go.mod`: `module bench-gonvoy`, `go 1.26`, `require github.com/ardikabs/gonvoy latest`.

- [x] **Step 4: Implement `filters/gonvoy/build.sh` + `envoy/envoy-gonvoy.yaml`**

`build.sh`: `go build -o gonvoy.so -buildmode=c-shared .`. Envoy: same golang filter type, `library_id: bench-gonvoy-id`, `library_path: /lib/gonvoy.so`, `plugin_name: bench-gonvoy`.

- [x] **Step 5: Build + run test to verify it passes + diff vs native Go**

Run: `bash filters/gonvoy/build.sh && bash tests/test_gonvoy.sh && diff <(curl -s -D - ... go) <(curl -s -D - ... gonvoy) # headers equal except x-* filter name`
Expected: PASS + only filter-name values differ

- [x] **Step 6: Commit**

```bash
git add filters/gonvoy/go.mod filters/gonvoy/main.go filters/gonvoy/handler.go filters/gonvoy/build.sh envoy/envoy-gonvoy.yaml tests/test_gonvoy.sh
git commit -m "feat: add gonvoy header filter and envoy config"
```

---

### Task 6: Baseline + backend + Compose wiring

**Files:**
- Create: `envoy/envoy-baseline.yaml`
- Create: `docker-compose.yaml`
- Create: `Dockerfile.envoy` (or inline envoy service with per-variant config mount)
- Create: `scripts/switch-variant.sh`
- Modify: all `envoy/*.yaml` to point route → `backend:8080`

**Interfaces:**
- Consumes: all 5 envoy configs, both `.so` paths, `.wasm` path
- Produces: `docker compose --profile <variant>` or `FILTER_VARIANT=` switching consumed by Task 7 harness.

- [x] **Step 1: Write `envoy/envoy-baseline.yaml` (copy of lua config minus lua filter, only router)**

- [x] **Step 2: Write `docker-compose.yaml` with services `backend` (hashicorp/http-echo or mendhak/http-https-echo), `envoy` (image contrib-v1.40-latest, mounts `./envoy/envoy-${FILTER_VARIANT}.yaml:/etc/envoy.yaml`, `./filters/.../*.so:/lib/...`, `./filters/.../*.wasm:/lib/...`), `loader` (nighthawk client image)**

- [x] **Step 3: Write `scripts/switch-variant.sh`**

```bash
#!/bin/bash
# usage: ./scripts/switch-variant.sh [baseline|lua|wasm|go-native|gonvoy]
# sets FILTER_VARIANT, restarts envoy, curls health, prints active filter
```

- [x] **Step 4: Verify all variants boot**

Run: `for v in baseline lua wasm go-native gonvoy; do ./scripts/switch-variant.sh $v || exit 1; done`
Expected: PASS (each curl returns 200 + correct `x-resp-added` or absent for baseline)

- [x] **Step 5: Commit**

```bash
git add envoy/envoy-baseline.yaml docker-compose.yaml Dockerfile.envoy scripts/switch-variant.sh
git commit -m "feat: add baseline config and compose wiring"
```

---

### Task 7: Load harness + results parser + comparison matrix

**Files:**
- Create: `scripts/run-benchmark.sh`
- Create: `scripts/parse-results.py`
- Create: `results/README.md` (template output + how to read matrix)
- Create: `load/nighthawk-queries.yaml` (optional fixed header sets: with-key, without-key, mixed)

**Interfaces:**
- Consumes: `scripts/capture-env.sh`, `scripts/switch-variant.sh`, `docs/METRICS.md`
- Produces: `results/<timestamp>/summary.md` comparison table answering gonvoy-vs-native-Go + vs Lua/WASM.

- [x] **Step 1: Write `scripts/run-benchmark.sh`**

Behavior: args `--rps 1000,5000,20000 --duration 60s --repeats 3 --variants all`; per combo: warmup 10s discarded, `nighthawk_client --rps X --duration Y --request-header "x-api-key: test-key-123" --request-header "user-agent: benchmark-agent" --output-format json`, save `results/raw/<variant>-<rps>-<rep>.json`, capture `docker stats` snapshot + `capture-env.sh` output once per run.

- [x] **Step 2: Write `scripts/parse-results.py`**

Input: `results/raw/*.json` + docker stats CSV. Output: `results/summary.md` table with columns Variant | RPS achieved | p50 | p95 | p99 | err% | CPU% | RSS | RPS/CPU, plus verdict line per METRICS.md decision rule. Must compute HDR `p50/p90/p95/p99` from nighthawk `execution_duration` histogram.

- [x] **Step 3: Dry-run harness at low RPS to verify it works**

Run: `./scripts/run-benchmark.sh --rps 100 --duration 10s --repeats 1 --variants baseline,lua`
Expected: PASS (`results/raw/` has 2 JSONs, `results/summary.md` renders table)

- [x] **Step 4: Commit**

```bash
git add scripts/run-benchmark.sh scripts/parse-results.py results/README.md load/nighthawk-queries.yaml
git commit -m "feat: add load harness and results parser"
```

---

### Task 8: Full verification sweep + README runbook

**Files:**
- Modify: `README.md` (full runbook: build all, boot, smoke, benchmark, interpret matrix)
- Create: `results/.gitkeep` (keep raw out via gitignore, commit only summary template)

**Interfaces:**
- Consumes: everything above
- Produces: final repo ready for user to run full benchmark on their machine.

- [x] **Step 1: Run full smoke across all variants**

Run: `for t in tests/test_*.sh; do bash $t || exit 1; done`
Expected: PASS (5/5 incl. baseline curl)

- [x] **Step 2: Run mini benchmark sweep to prove harness end-to-end**

Run: `./scripts/run-benchmark.sh --rps 500 --duration 15s --repeats 1 --variants all`
Expected: PASS (5 JSONs + summary.md with all variants, no errors)

- [x] **Step 3: Update README with machine-constraint note + how to interpret higher/lower-better + gonvoy verdict rule + build commands for .so/.wasm**

- [x] **Step 4: Commit**

```bash
git add README.md results/.gitkeep
git commit -m "docs: add runbook and verification sweep"
```
