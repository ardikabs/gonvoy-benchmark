#!/bin/bash
# Smoke test for the gonvoy header filter (Task 5).
#
# What it does:
#   1. Static checks (always run, no docker needed):
#      - filters/gonvoy/go.mod exists, declares module bench-gonvoy,
#        go 1.26, requires github.com/ardikabs/gonvoy.
#      - filters/gonvoy/handler.go exists, defines
#        BenchHandler as a gonvoy.Middleware
#        (func(next gonvoy.Handler) gonvoy.Handler) that calls next(c),
#        returns nil, uses only header APIs (c.Request().Header and
#        c.Response().Header Get/Set/Add/Del) plus
#        strings.Contains for the benchmark UA branch (no body calls).
#      - filters/gonvoy/main.go exists, registers plugin "bench-gonvoy"
#        via envoy.Handle("bench-gonvoy", gonvoy.Use(BenchHandler)) in
#        init(), with an empty main().
#      - filters/gonvoy/build.sh exists and runs
#        `go build -o gonvoy.so -buildmode=c-shared .`.
#      - filters/gonvoy/gonvoy.so exists (built artifact; FAILS until built).
#      - envoy/envoy-gonvoy.yaml exists, parses as YAML, has listener
#        0.0.0.0:10000, golang filter (library_id bench-gonvoy-id,
#        library_path /lib/gonvoy/gonvoy.so, plugin_name bench-gonvoy) before
#        router, route prefix / to cluster backend:8080.
#      - envoy --mode validate on the config (via docker image if present).
#   2. End-to-end checks (needs docker + envoyproxy/envoy:contrib-v1.40-latest
#      + the built .so artifact):
#      - starts a stub backend on host :8080 that echoes request headers back
#        as x-echo-* response headers,
#      - starts envoy in docker with --add-host=backend:host-gateway and the
#        .so mounted at /lib/gonvoy/gonvoy.so,
#      - runs the curl matrix below and asserts response/request headers.
#
# Curl matrix (all against http://127.0.0.1:10000/):
#   A. -H "x-api-key: test-key-123" -H "user-agent: benchmark-agent/1.0"
#      -> x-echo-x-auth-status: authenticated, x-echo-x-bench-tag: gonvoy
#   B. no x-api-key, default curl UA (no "benchmark" substring)
#      -> x-echo-x-auth-status: unauthenticated, x-echo-x-auth-retry: true,
#         x-echo-x-bench-tag: gonvoy-default
#   C. -H "x-drop-me: 1" -> backend must NOT see it (no x-echo-x-drop-me)
#   A/B/C. response always has x-resp-added: gonvoy, x-resp-version: v1,
#      x-gateway: envoy-gonvoy, and must NOT contain server: or x-drop-me:
#
# If docker, the envoy image, or the .so artifact is unavailable, part 2
# is skipped and the script reports what was / wasn't runnable (exit 0 iff
# static checks pass).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GO_DIR="$ROOT/filters/gonvoy"
GOMOD="$GO_DIR/go.mod"
HANDLER_GO="$GO_DIR/handler.go"
MAIN_GO="$GO_DIR/main.go"
BUILD_SH="$GO_DIR/build.sh"
SO="$GO_DIR/gonvoy.so"
CONFIG="$ROOT/envoy/envoy-gonvoy.yaml"
IMAGE="envoyproxy/envoy:contrib-v1.40-latest"
ENVOY_PORT=10000
BACKEND_PORT=8080
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

echo "=== part 1: static checks (no docker needed) ==="

[ -f "$GOMOD" ] || { fail "filters/gonvoy/go.mod exists"; }
[ -f "$HANDLER_GO" ] || { fail "filters/gonvoy/handler.go exists"; }
[ -f "$MAIN_GO" ] || { fail "filters/gonvoy/main.go exists"; }
[ -f "$BUILD_SH" ] || { fail "filters/gonvoy/build.sh exists"; }
[ -f "$CONFIG" ] || { fail "envoy/envoy-gonvoy.yaml exists"; }
if [ ! -f "$GOMOD" ] || [ ! -f "$HANDLER_GO" ] || [ ! -f "$MAIN_GO" ] || [ ! -f "$BUILD_SH" ] || [ ! -f "$CONFIG" ]; then
  echo "RESULT: FAIL ($FAIL failed, $PASS passed) - implementation files missing"
  exit 1
fi
pass "implementation files exist"

# go.mod: module + toolchain + gonvoy pin.
grep -q '^module bench-gonvoy' "$GOMOD" \
  && pass "go.mod declares module bench-gonvoy" \
  || fail "go.mod declares module bench-gonvoy"
grep -q '^go 1\.26' "$GOMOD" \
  && pass "go.mod pins go 1.26" \
  || fail "go.mod pins go 1.26"
grep -q 'github.com/ardikabs/gonvoy v' "$GOMOD" \
  && pass "go.mod requires github.com/ardikabs/gonvoy" \
  || fail "go.mod requires github.com/ardikabs/gonvoy"

# gofmt clean (when go is on PATH).
if command -v gofmt >/dev/null 2>&1; then
  if [ -z "$(gofmt -l "$HANDLER_GO" "$MAIN_GO")" ]; then pass "handler.go + main.go are gofmt-clean";
  else fail "handler.go + main.go are gofmt-clean"; fi
else
  echo "SKIP: no gofmt on PATH, format check omitted"
fi

# Entry point: BenchHandler is a gonvoy.Middleware so it can observe the
# response via next(c) (a plain func(c gonvoy.Context) error cannot be
# passed to gonvoy.Use and could never touch response headers).
grep -q 'func BenchHandler(next gonvoy\.Handler) gonvoy\.Handler' "$HANDLER_GO" \
  && pass "defines BenchHandler(next gonvoy.Handler) gonvoy.Handler" \
  || fail "defines BenchHandler(next gonvoy.Handler) gonvoy.Handler"
grep -q 'next(c)' "$HANDLER_GO" \
  && pass "BenchHandler proceeds upstream via next(c)" \
  || fail "BenchHandler proceeds upstream via next(c)"
grep -q 'return nil' "$HANDLER_GO" \
  && pass "handler.go returns nil (passthrough)" \
  || fail "handler.go returns nil (passthrough)"

# Header-only API: c.Request().Header (request Get/Set/Add/Del),
# c.Response().Header (response Get/Set/Add/Del, fresh view after next).
# Plus strings.Contains for the UA branch.
grep -q 'Request()\.Header\.Get' "$HANDLER_GO" \
  && pass "handler.go reads request headers via c.Request().Header" \
  || fail "handler.go reads request headers via c.Request().Header"
grep -q 'Response()\.Header\.\(Set\|Add\)' "$HANDLER_GO" \
  && pass "handler.go writes response headers via c.Response().Header" \
  || fail "handler.go writes response headers via c.Response().Header"
grep -q 'Request()\.Header\.Set' "$HANDLER_GO" \
  && pass "handler.go writes request headers via c.Request().Header" \
  || fail "handler.go writes request headers via c.Request().Header"
grep -q 'Response()\.Header\.Del' "$HANDLER_GO" \
  && pass "handler.go drops response headers via c.Response().Header.Del" \
  || fail "handler.go drops response headers via c.Response().Header.Del"
grep -q 'Request()\.Header\.\(Add\|Del\)' "$HANDLER_GO" \
  && pass "handler.go adds/drops request headers via c.Request().Header" \
  || fail "handler.go adds/drops request headers via c.Request().Header"
grep -q 'strings\.Contains' "$HANDLER_GO" \
  && pass "handler.go uses strings.Contains for benchmark UA" \
  || fail "handler.go uses strings.Contains for benchmark UA"
if grep -nE 'c\.Body\(|c\.ResponseBody\(|c\.Bind\(|c\.Write\(|c\.JSON\(|c\.String\(|c\.NoContent\(|ReadRequestBody|WriteRequestBody|ReadResponseBody|WriteResponseBody|OpenBodyAccess' "$HANDLER_GO" \
  | grep -v "^.*//" >/dev/null 2>&1; then
  fail "handler.go uses only header APIs, no body APIs"
else
  pass "handler.go uses only header APIs, no body APIs"
fi

# Spec branches present verbatim (filter-name = gonvoy).
grep -q 'test-key-123' "$HANDLER_GO" && pass "branches on x-api-key == test-key-123" \
  || fail "branches on x-api-key == test-key-123"
grep -q '"benchmark"' "$HANDLER_GO" && pass "branches on benchmark UA substring" \
  || fail "branches on benchmark UA substring"
for h in x-auth-status x-auth-retry x-bench-tag x-request-touched x-filter-type x-drop-me x-resp-added x-resp-version x-gateway; do
  grep -q "$h" "$HANDLER_GO" || fail "handler.go mentions header $h"
done
pass "handler.go mentions all spec headers"
grep -q '"gonvoy"' "$HANDLER_GO" && pass "handler.go uses filter-name gonvoy values" \
  || fail "handler.go uses filter-name gonvoy values"
grep -q 'envoy-gonvoy' "$HANDLER_GO" && pass "handler.go sets x-gateway envoy-gonvoy" \
  || fail "handler.go sets x-gateway envoy-gonvoy"

# Registration in main.go only (pkg/envoy links Envoy C bindings, so unit
# tests must never import it; handler.go must not mention envoy.Handle).
grep -q 'envoy\.Handle("bench-gonvoy", gonvoy\.Use(BenchHandler))' "$MAIN_GO" \
  && pass 'main.go registers plugin "bench-gonvoy" via envoy.Handle(.., gonvoy.Use(BenchHandler))' \
  || fail 'main.go registers plugin "bench-gonvoy" via envoy.Handle(.., gonvoy.Use(BenchHandler))'
grep -q '^func main() {}$' "$MAIN_GO" \
  && pass "main.go has empty main()" \
  || fail "main.go has empty main()"
grep -q '^package main' "$MAIN_GO" \
  && pass "main.go is package main (c-shared)" \
  || fail "main.go is package main (c-shared)"
if grep -q 'pkg/envoy' "$HANDLER_GO"; then
  fail "handler.go stays free of pkg/envoy (registration lives in main.go only)"
else
  pass "handler.go stays free of pkg/envoy (registration lives in main.go only)"
fi

# build.sh builds the exact artifact from the brief.
grep -q 'go build -o gonvoy\.so -buildmode=c-shared \.' "$BUILD_SH" \
  && pass "build.sh runs go build -o gonvoy.so -buildmode=c-shared ." \
  || fail "build.sh runs go build -o gonvoy.so -buildmode=c-shared ."

# Built artifact must exist (this FAILS until `bash filters/gonvoy/build.sh` runs).
[ -f "$SO" ] && pass "gonvoy.so artifact built" \
  || fail "gonvoy.so artifact built ($SO missing)"

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
assert tc.get('server_header_transformation') == 'PASS_THROUGH', tc.get('server_header_transformation')
names = [f['name'] for f in tc['http_filters']]
assert names == ['envoy.filters.http.golang', 'envoy.filters.http.router'], names
go_tc = tc['http_filters'][0]['typed_config']
assert go_tc['@type'] == 'type.googleapis.com/envoy.extensions.filters.http.golang.v3alpha.Config', go_tc.get('@type')
assert go_tc.get('library_id') == 'bench-gonvoy-id', go_tc.get('library_id')
assert go_tc.get('library_path') == '/lib/gonvoy/gonvoy.so', go_tc.get('library_path')
assert go_tc.get('plugin_name') == 'bench-gonvoy', go_tc.get('plugin_name')
route = tc['route_config']['virtual_hosts'][0]['routes'][0]
assert route['match'] == {'prefix': '/'}, route['match']
assert route['route']['cluster'] == 'backend:8080', route['route']
clusters = {c['name']: c for c in cfg['static_resources']['clusters']}
assert 'backend:8080' in clusters, list(clusters)
ep = clusters['backend:8080']['load_assignment']['endpoints'][0]['lb_endpoints'][0]['endpoint']['address']['socket_address']
assert (ep['address'], ep['port_value']) == ('backend', 8080), ep
print('yaml structure ok')
EOF
then pass "envoy-gonvoy.yaml structure (listener :10000, golang+router, cluster backend:8080)";
else fail "envoy-gonvoy.yaml structure"; fi

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
# Validate mode may resolve the library path, so mount the built artifact.
# Pre-build the artifact is absent and this step is skipped (the artifact
# check above already FAILs until `bash filters/gonvoy/build.sh` runs).
if [ -f "$SO" ]; then
  VALIDATE_OUT="$(docker run --rm -v "$CONFIG:/etc/envoy/envoy.yaml:ro" \
    -v "$SO:/lib/gonvoy/gonvoy.so:ro" "$IMAGE" \
    --mode validate -c /etc/envoy/envoy.yaml 2>&1)"
  VALIDATE_RC=$?
  echo "$VALIDATE_OUT" | tail -3
  if [ "$VALIDATE_RC" = "0" ]; then
    pass "envoy --mode validate accepts envoy-gonvoy.yaml"
  else
    fail "envoy --mode validate accepts envoy-gonvoy.yaml"
  fi
else
  echo "SKIP envoy --mode validate: $SO not built yet"
fi

if [ ! -f "$SO" ]; then
  echo "SKIP part 2 (e2e): $SO not built; run bash filters/gonvoy/build.sh first"
  echo "RESULT: static-only ($FAIL failed, $PASS passed)"
  [ "$FAIL" = "0" ]
  exit $?
fi

echo "=== part 2: e2e (docker + envoy + gonvoy) ==="
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
  docker rm -f envoy-gonvoy-test >/dev/null 2>&1 || true
  kill "$BACKEND_PID" >/dev/null 2>&1 || true
  rm -rf "$TMPD"
}
trap cleanup EXIT
docker rm -f envoy-gonvoy-test >/dev/null 2>&1 || true

python3 "$BACKEND_PY" &
BACKEND_PID=$!
sleep 1
kill -0 "$BACKEND_PID" 2>/dev/null || { fail "stub backend starts on :8080"; exit 1; }
pass "stub backend starts on :8080"

docker run -d --name envoy-gonvoy-test \
  --add-host=backend:host-gateway \
  -p 127.0.0.1:10000:10000 \
  -v "$CONFIG:/etc/envoy/envoy.yaml:ro" \
  -v "$SO:/lib/gonvoy/gonvoy.so:ro" \
  "$IMAGE" -c /etc/envoy/envoy.yaml >/dev/null
ready=0
for _ in $(seq 1 60); do
  if curl -sS -o /dev/null http://127.0.0.1:10000/ 2>/dev/null; then ready=1; break; fi
  sleep 1
done
[ "$ready" = "1" ] || { fail "envoy listener ready on :10000"; docker logs envoy-gonvoy-test 2>&1 | tail -20; exit 1; }
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
has caseA x-echo-x-bench-tag gonvoy
has caseA x-echo-x-request-touched true
has caseA x-echo-x-filter-type gonvoy
has caseA x-resp-added gonvoy
has caseA x-resp-version v1
has caseA x-gateway envoy-gonvoy
nohdr caseA server
nohdr caseA x-drop-me
nohdr caseA x-echo-x-drop-me
grep -qi "^x-echo-x-auth-retry:" "$TMPD/caseA.hdr" \
  && fail "caseA: no x-echo-x-auth-retry" || pass "caseA: no x-echo-x-auth-retry"

# Case B: no key + default curl UA (no "benchmark").
get caseB
has caseB x-echo-x-auth-status unauthenticated
has caseB x-echo-x-auth-retry true
has caseB x-echo-x-bench-tag gonvoy-default
has caseB x-resp-added gonvoy
has caseB x-resp-version v1
has caseB x-gateway envoy-gonvoy
nohdr caseB server
nohdr caseB x-drop-me

# Case C: client x-drop-me must be stripped before upstream.
get caseC -H "x-api-key: test-key-123" -H "x-drop-me: 1"
nohdr caseC x-echo-x-drop-me
has caseC x-echo-x-auth-status authenticated

echo "RESULT: e2e ($FAIL failed, $PASS passed)"
[ "$FAIL" = "0" ]
