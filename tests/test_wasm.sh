#!/bin/bash
# Smoke test for the WASM Rust header filter (Task 3).
#
# What it does:
#   1. Static checks (always run, no docker needed):
#      - filters/wasm-rust/Cargo.toml exists, crate-type cdylib,
#        depends on proxy-wasm 0.2.
#      - filters/wasm-rust/src/lib.rs exists, defines RootContext ->
#        HttpContext, on_http_request_headers/on_http_response_headers
#        returning Action::Continue, uses only get_/set_/add_/remove_
#        http_request/response_header APIs (no body calls).
#      - filters/wasm-rust/target/wasm32-unknown-unknown/release/
#        bench_header.wasm exists (built artifact; FAILS until built).
#      - envoy/envoy-wasm.yaml exists, parses as YAML, has listener
#        0.0.0.0:10000, wasm filter (runtime envoy.wasm.runtime.v8,
#        filename /lib/wasm/bench_header.wasm, root_id bench_root) before
#        router, route prefix / to cluster backend:8080.
#      - envoy --mode validate on the config (via docker image if present).
#   2. End-to-end checks (needs docker + envoyproxy/envoy:contrib-v1.40-latest
#      + the built .wasm artifact):
#      - starts a stub backend on host :8080 that echoes request headers back
#        as x-echo-* response headers,
#      - starts envoy in docker with --add-host=backend:host-gateway and the
#        .wasm mounted at /lib/wasm/bench_header.wasm,
#      - runs the curl matrix below and asserts response/request headers.
#
# Curl matrix (all against http://127.0.0.1:10000/):
#   A. -H "x-api-key: test-key-123" -H "user-agent: benchmark-agent/1.0"
#      -> x-echo-x-auth-status: authenticated, x-echo-x-bench-tag: wasm
#   B. no x-api-key, default curl UA (no "benchmark" substring)
#      -> x-echo-x-auth-status: unauthenticated, x-echo-x-auth-retry: true,
#         x-echo-x-bench-tag: wasm-default
#   C. -H "x-drop-me: 1" -> backend must NOT see it (no x-echo-x-drop-me)
#   A/B/C. response always has x-resp-added: wasm, x-resp-version: v1,
#      x-gateway: envoy-wasm, and must NOT contain server: or x-drop-me:
#
# If docker, the envoy image, or the .wasm artifact is unavailable, part 2
# is skipped and the script reports what was / wasn't runnable (exit 0 iff
# static checks pass).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="$ROOT/filters/wasm-rust"
MANIFEST="$CRATE_DIR/Cargo.toml"
LIB_RS="$CRATE_DIR/src/lib.rs"
WASM="$CRATE_DIR/target/wasm32-unknown-unknown/release/bench_header.wasm"
CONFIG="$ROOT/envoy/envoy-wasm.yaml"
IMAGE="envoyproxy/envoy:contrib-v1.40-latest"
ENVOY_PORT=10000
BACKEND_PORT=8080
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

echo "=== part 1: static checks (no docker needed) ==="

[ -f "$MANIFEST" ] || { fail "filters/wasm-rust/Cargo.toml exists"; }
[ -f "$LIB_RS" ] || { fail "filters/wasm-rust/src/lib.rs exists"; }
[ -f "$CONFIG" ] || { fail "envoy/envoy-wasm.yaml exists"; }
if [ ! -f "$MANIFEST" ] || [ ! -f "$LIB_RS" ] || [ ! -f "$CONFIG" ]; then
  echo "RESULT: FAIL ($FAIL failed, $PASS passed) - implementation files missing"
  exit 1
fi
pass "implementation files exist"

# Cargo.toml: cdylib + proxy-wasm 0.2.
grep -q 'crate-type.*cdylib' "$MANIFEST" \
  && pass "Cargo.toml sets crate-type cdylib" \
  || fail "Cargo.toml sets crate-type cdylib"
grep -qE 'proxy-wasm\s*=\s*"0\.2' "$MANIFEST" \
  && pass "Cargo.toml depends on proxy-wasm 0.2" \
  || fail "Cargo.toml depends on proxy-wasm 0.2"

# lib.rs: RootContext -> HttpContext structure.
grep -q "RootContext" "$LIB_RS" \
  && pass "lib.rs defines a RootContext" \
  || fail "lib.rs defines a RootContext"
grep -q "HttpContext" "$LIB_RS" \
  && pass "lib.rs defines an HttpContext" \
  || fail "lib.rs defines an HttpContext"
grep -q "on_http_request_headers" "$LIB_RS" \
  && pass "lib.rs defines on_http_request_headers" \
  || fail "lib.rs defines on_http_request_headers"
grep -q "on_http_response_headers" "$LIB_RS" \
  && pass "lib.rs defines on_http_response_headers" \
  || fail "lib.rs defines on_http_response_headers"
grep -q "Action::Continue" "$LIB_RS" \
  && pass "lib.rs returns Action::Continue" \
  || fail "lib.rs returns Action::Continue"

# Header-only API: require the request/response get/set/add/remove header
# calls the spec branches need (response path needs no get_).
for m in get_http_request_header set_http_request_header add_http_request_header remove_http_request_header \
         set_http_response_header add_http_response_header remove_http_response_header; do
  grep -q "$m" "$LIB_RS" || fail "lib.rs uses $m"
done
pass "lib.rs uses request/response header get/set/add/remove calls"
if grep -nE "request_body|response_body|buffer_bytes|trailers|grpc_|http_call|shared_data|foreign_function|log\(|get_property|set_property" "$LIB_RS" \
  | grep -v "^.*//" >/dev/null 2>&1; then
  fail "lib.rs uses only header APIs (no body/buffer/trailer/grpc/http_call)"
else
  pass "lib.rs uses only header APIs (no body/buffer/trailer/grpc/http_call)"
fi

# Spec branches present verbatim (filter-name = wasm).
grep -q 'test-key-123' "$LIB_RS" && pass "branches on x-api-key == test-key-123" \
  || fail "branches on x-api-key == test-key-123"
grep -q 'benchmark' "$LIB_RS" && pass "branches on benchmark UA substring" \
  || fail "branches on benchmark UA substring"
for h in x-auth-status x-auth-retry x-bench-tag x-request-touched x-filter-type x-drop-me x-resp-added x-resp-version x-gateway server; do
  grep -q "$h" "$LIB_RS" || fail "lib.rs mentions header $h"
done
pass "lib.rs mentions all spec headers"
grep -q '"wasm"' "$LIB_RS" && pass "lib.rs uses filter-name wasm values" \
  || fail "lib.rs uses filter-name wasm values"
grep -q 'envoy-wasm' "$LIB_RS" && pass "lib.rs sets x-gateway envoy-wasm" \
  || fail "lib.rs sets x-gateway envoy-wasm"

# build.sh exists and runs the expected build.
[ -f "$CRATE_DIR/build.sh" ] && pass "filters/wasm-rust/build.sh exists" \
  || fail "filters/wasm-rust/build.sh exists"
grep -q 'wasm32-unknown-unknown' "$CRATE_DIR/build.sh" 2>/dev/null \
  && pass "build.sh targets wasm32-unknown-unknown" \
  || fail "build.sh targets wasm32-unknown-unknown"

# Built artifact must exist (this FAILS until `bash filters/wasm-rust/build.sh` runs).
[ -f "$WASM" ] && pass "bench_header.wasm artifact built" \
  || fail "bench_header.wasm artifact built ($WASM missing)"

# YAML parses + structural assertions.
if python3 - "$CONFIG" <<'EOF'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
l = cfg['static_resources']['listeners'][0]
sa = l['address']['socket_address']
assert (sa['address'], sa['port_value']) == ('0.0.0.0', 10000), sa
chain = l['filter_chains'][0]['filters'][0]
tc = chain['typed_config']
assert tc['stat_prefix'] == 'ingress_http', tc.get('stat_prefix')
names = [f['name'] for f in tc['http_filters']]
assert names == ['envoy.filters.http.wasm', 'envoy.filters.http.router'], names
wasm_tc = tc['http_filters'][0]['typed_config']
assert wasm_tc['@type'] == 'type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm', wasm_tc.get('@type')
plugin = wasm_tc['config']
assert plugin['root_id'] == 'bench_root', plugin.get('root_id')
vm = plugin['vm_config']
assert vm['runtime'] == 'envoy.wasm.runtime.v8', vm.get('runtime')
code = vm['code']['local']
assert code.get('filename') == '/lib/wasm/bench_header.wasm', code
route = tc['route_config']['virtual_hosts'][0]['routes'][0]
assert route['match'] == {'prefix': '/'}, route['match']
assert route['route']['cluster'] == 'backend:8080', route['route']
clusters = {c['name']: c for c in cfg['static_resources']['clusters']}
assert 'backend:8080' in clusters, list(clusters)
ep = clusters['backend:8080']['load_assignment']['endpoints'][0]['lb_endpoints'][0]['endpoint']['address']['socket_address']
assert (ep['address'], ep['port_value']) == ('backend', 8080), ep
print('yaml structure ok')
EOF
then pass "envoy-wasm.yaml structure (listener :10000, wasm+router, cluster backend:8080)";
else fail "envoy-wasm.yaml structure"; fi

HAVE_DOCKER=0
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && HAVE_DOCKER=1
if [ "$HAVE_DOCKER" = "0" ]; then
  echo "SKIP part 2 (e2e): docker unavailable"
  echo "RESULT: static-only ($FAIL failed, $PASS passed)"
  [ "$FAIL" = "0" ]
  exit $?
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "pulling $IMAGE ..."
  docker pull "$IMAGE" >/dev/null 2>&1 || true
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "SKIP part 2 (e2e): envoy image unavailable (pull failed)"
  echo "NOTE: static checks + 'docker run --rm $IMAGE --mode validate' + curl matrix above remain runnable where noted"
  echo "RESULT: static-only ($FAIL failed, $PASS passed)"
  [ "$FAIL" = "0" ]
  exit $?
fi

echo "=== envoy --mode validate ==="
# Validate mode resolves the local filename, so mount the built artifact.
# Pre-build the artifact is absent and this step is skipped (the artifact
# check above already FAILs until `bash filters/wasm-rust/build.sh` runs).
if [ -f "$WASM" ]; then
  VALIDATE_OUT="$(docker run --rm -v "$CONFIG:/etc/envoy/envoy.yaml:ro" \
    -v "$WASM:/lib/wasm/bench_header.wasm:ro" "$IMAGE" \
    --mode validate -c /etc/envoy/envoy.yaml 2>&1)"
  VALIDATE_RC=$?
  echo "$VALIDATE_OUT" | tail -3
  if [ "$VALIDATE_RC" = "0" ]; then
    pass "envoy --mode validate accepts envoy-wasm.yaml"
  else
    fail "envoy --mode validate accepts envoy-wasm.yaml"
  fi
else
  echo "SKIP envoy --mode validate: $WASM not built yet"
fi

if [ ! -f "$WASM" ]; then
  echo "SKIP part 2 (e2e): $WASM not built; run bash filters/wasm-rust/build.sh first"
  echo "RESULT: static-only ($FAIL failed, $PASS passed)"
  [ "$FAIL" = "0" ]
  exit $?
fi

echo "=== part 2: e2e (docker + envoy + wasm) ==="
TMPD="$(mktemp -d)"
BACKEND_PY="$TMPD/backend.py"
cat >"$BACKEND_PY" <<'PYEOF'
# Stub upstream: echoes selected request headers as x-echo-* response
# headers so the test can observe what the filter forwarded. Deliberately
# sends server/x-drop-me/stale x-resp-version for the response filter to fix.
from http.server import BaseHTTPRequestHandler, HTTPServer
ECHO = ['x-auth-status', 'x-auth-retry', 'x-bench-tag', 'x-request-touched',
        'x-filter-type', 'x-drop-me']
class H(BaseHTTPRequestHandler):
    def _reply(self):
        body = b'ok'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('server', 'backend-origin')
        self.send_header('x-drop-me', 'upstream-should-be-removed')
        self.send_header('x-resp-version', '0-stale')
        for name in ECHO:
            v = self.headers.get(name)
            if v is not None:
                self.send_header('x-echo-' + name, v)
        self.end_headers()
        self.wfile.write(body)
    do_GET = _reply
    do_POST = _reply
    def log_message(self, *a):
        pass
HTTPServer(('127.0.0.1', 8080), H).serve_forever()
PYEOF

cleanup() {
  docker rm -f envoy-wasm-test >/dev/null 2>&1 || true
  kill "$BACKEND_PID" >/dev/null 2>&1 || true
  rm -rf "$TMPD"
}
trap cleanup EXIT
docker rm -f envoy-wasm-test >/dev/null 2>&1 || true

python3 "$BACKEND_PY" &
BACKEND_PID=$!
sleep 1
kill -0 "$BACKEND_PID" 2>/dev/null || { fail "stub backend starts on :8080"; exit 1; }
pass "stub backend starts on :8080"

docker run -d --name envoy-wasm-test \
  --add-host=backend:host-gateway \
  -p 127.0.0.1:10000:10000 \
  -v "$CONFIG:/etc/envoy/envoy.yaml:ro" \
  -v "$WASM:/lib/wasm/bench_header.wasm:ro" \
  "$IMAGE" -c /etc/envoy/envoy.yaml >/dev/null
ready=0
for _ in $(seq 1 60); do
  if curl -sS -o /dev/null http://127.0.0.1:10000/ 2>/dev/null; then ready=1; break; fi
  sleep 1
done
[ "$ready" = "1" ] || { fail "envoy listener ready on :10000"; docker logs envoy-wasm-test 2>&1 | tail -20; exit 1; }
pass "envoy listener ready on :10000"

get() { # get <outfile-prefix> [curl args...]
  local out="$TMPD/$1"; shift
  curl -sS -D "$out.hdr" -o "$out.body" http://127.0.0.1:10000/ "$@" || fail "curl $1"
}
has() { grep -qi "^$2:[[:space:]]*$3[[:space:]]*$" "$TMPD/$1.hdr" \
  && pass "$1: response has $2: $3" || { fail "$1: response has $2: $3"; sed 's/^/  hdr: /' "$TMPD/$1.hdr"; }; }
nohdr() { grep -qi "^$2:" "$TMPD/$1.hdr" \
  && { fail "$1: response omits $2"; grep -i "^$2:" "$TMPD/$1.hdr" | sed 's/^/  hdr: /'; } \
  || pass "$1: response omits $2"; }

# Case A: valid key + benchmark UA.
get caseA -H "x-api-key: test-key-123" -H "user-agent: benchmark-agent/1.0"
has caseA x-echo-x-auth-status authenticated
has caseA x-echo-x-bench-tag wasm
has caseA x-echo-x-request-touched true
has caseA x-echo-x-filter-type wasm
has caseA x-resp-added wasm
has caseA x-resp-version v1
has caseA x-gateway envoy-wasm
nohdr caseA server
nohdr caseA x-drop-me
nohdr caseA x-echo-x-drop-me
grep -qi "^x-echo-x-auth-retry:" "$TMPD/caseA.hdr" \
  && fail "caseA: no x-echo-x-auth-retry" || pass "caseA: no x-echo-x-auth-retry"

# Case B: no key + default curl UA (no "benchmark").
get caseB
has caseB x-echo-x-auth-status unauthenticated
has caseB x-echo-x-auth-retry true
has caseB x-echo-x-bench-tag wasm-default
has caseB x-resp-added wasm
has caseB x-resp-version v1
has caseB x-gateway envoy-wasm
nohdr caseB server
nohdr caseB x-drop-me

# Case C: client x-drop-me must be stripped before upstream.
get caseC -H "x-api-key: test-key-123" -H "x-drop-me: 1"
nohdr caseC x-echo-x-drop-me
has caseC x-echo-x-auth-status authenticated

echo "RESULT: e2e ($FAIL failed, $PASS passed)"
[ "$FAIL" = "0" ]
