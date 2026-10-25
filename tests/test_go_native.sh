#!/bin/bash
# Smoke test for the native Go header filter (Task 4).
#
# What it does:
#   1. Static checks (always run, no docker needed):
#      - filters/go-native/go.mod exists, declares module bench-go-native,
#        go 1.26, requires github.com/envoyproxy/envoy v1.40.0.
#      - filters/go-native/filter.go exists, defines DecodeHeaders with
#        api.RequestHeaderMap / EncodeHeaders with api.ResponseHeaderMap,
#        returns api.Continue, uses only Get/Set/Add/Del header calls plus
#        strings.Contains for the benchmark UA branch (no body calls), and
#        registers plugin "bench-go" via RegisterHttpFilterFactoryAndConfigParser.
#      - filters/go-native/build.sh exists and runs
#        `go build -buildmode=c-shared -o bench-go.so .`.
#      - filters/go-native/bench-go.so exists (built artifact; FAILS until built).
#      - envoy/envoy-go-native.yaml exists, parses as YAML, has listener
#        0.0.0.0:10000, golang filter (library_id bench-go-id, library_path
#        /lib/go-native/bench-go.so, plugin_name bench-go) before router, route prefix /
#        to cluster backend:8080.
#      - envoy --mode validate on the config (via docker image if present).
#   2. End-to-end checks (needs docker + envoyproxy/envoy:contrib-v1.40-latest
#      + the built .so artifact):
#      - starts a stub backend on host :8080 that echoes request headers back
#        as x-echo-* response headers,
#      - starts envoy in docker with --add-host=backend:host-gateway and the
#        .so mounted at /lib/go-native/bench-go.so,
#      - runs the curl matrix below and asserts response/request headers.
#
# Curl matrix (all against http://127.0.0.1:10000/):
#   A. -H "x-api-key: test-key-123" -H "user-agent: benchmark-agent/1.0"
#      -> x-echo-x-auth-status: authenticated, x-echo-x-bench-tag: go
#   B. no x-api-key, default curl UA (no "benchmark" substring)
#      -> x-echo-x-auth-status: unauthenticated, x-echo-x-auth-retry: true,
#         x-echo-x-bench-tag: go-default
#   C. -H "x-drop-me: 1" -> backend must NOT see it (no x-echo-x-drop-me)
#   A/B/C. response always has x-resp-added: go, x-resp-version: v1,
#      x-gateway: envoy-go, and must NOT contain server: or x-drop-me:
#
# If docker, the envoy image, or the .so artifact is unavailable, part 2
# is skipped and the script reports what was / wasn't runnable (exit 0 iff
# static checks pass).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GO_DIR="$ROOT/filters/go-native"
GOMOD="$GO_DIR/go.mod"
FILTER_GO="$GO_DIR/filter.go"
BUILD_SH="$GO_DIR/build.sh"
SO="$GO_DIR/bench-go.so"
CONFIG="$ROOT/envoy/envoy-go-native.yaml"
IMAGE="envoyproxy/envoy:contrib-v1.40-latest"
ENVOY_PORT=10000
BACKEND_PORT=8080
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

echo "=== part 1: static checks (no docker needed) ==="

[ -f "$GOMOD" ] || { fail "filters/go-native/go.mod exists"; }
[ -f "$FILTER_GO" ] || { fail "filters/go-native/filter.go exists"; }
[ -f "$BUILD_SH" ] || { fail "filters/go-native/build.sh exists"; }
[ -f "$CONFIG" ] || { fail "envoy/envoy-go-native.yaml exists"; }
if [ ! -f "$GOMOD" ] || [ ! -f "$FILTER_GO" ] || [ ! -f "$BUILD_SH" ] || [ ! -f "$CONFIG" ]; then
  echo "RESULT: FAIL ($FAIL failed, $PASS passed) - implementation files missing"
  exit 1
fi
pass "implementation files exist"

# go.mod: module + toolchain + SDK pins.
grep -q '^module bench-go-native' "$GOMOD" \
  && pass "go.mod declares module bench-go-native" \
  || fail "go.mod declares module bench-go-native"
grep -q '^go 1\.26' "$GOMOD" \
  && pass "go.mod pins go 1.26" \
  || fail "go.mod pins go 1.26"
grep -q 'github.com/envoyproxy/envoy v1\.40\.0' "$GOMOD" \
  && pass "go.mod requires github.com/envoyproxy/envoy v1.40.0" \
  || fail "go.mod requires github.com/envoyproxy/envoy v1.40.0"

# gofmt clean (when go is on PATH).
if command -v gofmt >/dev/null 2>&1; then
  if [ -z "$(gofmt -l "$FILTER_GO")" ]; then pass "filter.go is gofmt-clean";
  else fail "filter.go is gofmt-clean"; fi
else
  echo "SKIP: no gofmt on PATH, format check omitted"
fi

# Exact entry-point signatures from the brief.
grep -q 'func (f \*filter) DecodeHeaders(h api\.RequestHeaderMap, _ bool) api\.StatusType' "$FILTER_GO" \
  && pass "defines DecodeHeaders(h api.RequestHeaderMap, _ bool) api.StatusType" \
  || fail "defines DecodeHeaders(h api.RequestHeaderMap, _ bool) api.StatusType"
grep -q 'func (f \*filter) EncodeHeaders(h api\.ResponseHeaderMap, _ bool) api\.StatusType' "$FILTER_GO" \
  && pass "defines EncodeHeaders(h api.ResponseHeaderMap, _ bool) api.StatusType" \
  || fail "defines EncodeHeaders(h api.ResponseHeaderMap, _ bool) api.StatusType"
grep -q 'api\.Continue' "$FILTER_GO" \
  && pass "filter.go returns api.Continue" \
  || fail "filter.go returns api.Continue"

# Header-only API: Get/Set/Add/Del only (+ strings.Contains for the UA branch).
for m in '\.Get(' '\.Set(' '\.Add(' '\.Del('; do
  grep -q "$m" "$FILTER_GO" || fail "filter.go uses $m"
done
pass "filter.go uses Get/Set/Add/Del header calls"
grep -q 'strings\.Contains' "$FILTER_GO" \
  && pass "filter.go uses strings.Contains for benchmark UA" \
  || fail "filter.go uses strings.Contains for benchmark UA"
if grep -nE 'DecodeData|EncodeData|DecodeTrailers|EncodeTrailers|SendLocalReply|GetProperty|Range\(|Values\(|GetRaw\(|SetMethod|SetPath|SetHost' "$FILTER_GO" \
  | grep -v "^.*//" >/dev/null 2>&1; then
  fail "filter.go uses only Get/Set/Add/Del (+ strings.Contains), no body/trailer/other APIs"
else
  pass "filter.go uses only Get/Set/Add/Del (+ strings.Contains), no body/trailer/other APIs"
fi

# Spec branches present verbatim (filter-name = go).
grep -q 'test-key-123' "$FILTER_GO" && pass "branches on x-api-key == test-key-123" \
  || fail "branches on x-api-key == test-key-123"
grep -q '"benchmark"' "$FILTER_GO" && pass "branches on benchmark UA substring" \
  || fail "branches on benchmark UA substring"
for h in x-auth-status x-auth-retry x-bench-tag x-request-touched x-filter-type x-drop-me x-resp-added x-resp-version x-gateway server; do
  grep -q "$h" "$FILTER_GO" || fail "filter.go mentions header $h"
done
pass "filter.go mentions all spec headers"
grep -q '"go"' "$FILTER_GO" && pass "filter.go uses filter-name go values" \
  || fail "filter.go uses filter-name go values"
grep -q 'envoy-go' "$FILTER_GO" && pass "filter.go sets x-gateway envoy-go" \
  || fail "filter.go sets x-gateway envoy-go"

# Missing x-api-key treated as ELSE: Get's ok bool must be checked.
grep -q ', ok' "$FILTER_GO" && pass "filter.go checks ok bool for missing x-api-key" \
  || fail "filter.go checks ok bool for missing x-api-key"

# c-shared plugin registration.
grep -q 'RegisterHttpFilterFactoryAndConfigParser("bench-go"' "$FILTER_GO" \
  && pass 'filter.go registers plugin "bench-go"' \
  || fail 'filter.go registers plugin "bench-go"'
grep -q '^package main' "$FILTER_GO" \
  && pass "filter.go is package main (c-shared)" \
  || fail "filter.go is package main (c-shared)"

# build.sh builds the exact artifact from the brief.
grep -q 'go build -buildmode=c-shared -o bench-go\.so \.' "$BUILD_SH" \
  && pass "build.sh runs go build -buildmode=c-shared -o bench-go.so ." \
  || fail "build.sh runs go build -buildmode=c-shared -o bench-go.so ."

# Built artifact must exist (this FAILS until `bash filters/go-native/build.sh` runs).
[ -f "$SO" ] && pass "bench-go.so artifact built" \
  || fail "bench-go.so artifact built ($SO missing)"

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
assert go_tc.get('library_id') == 'bench-go-id', go_tc.get('library_id')
assert go_tc.get('library_path') == '/lib/go-native/bench-go.so', go_tc.get('library_path')
assert go_tc.get('plugin_name') == 'bench-go', go_tc.get('plugin_name')
route = tc['route_config']['virtual_hosts'][0]['routes'][0]
assert route['match'] == {'prefix': '/'}, route['match']
assert route['route']['cluster'] == 'backend:8080', route['route']
clusters = {c['name']: c for c in cfg['static_resources']['clusters']}
assert 'backend:8080' in clusters, list(clusters)
ep = clusters['backend:8080']['load_assignment']['endpoints'][0]['lb_endpoints'][0]['endpoint']['address']['socket_address']
assert (ep['address'], ep['port_value']) == ('backend', 8080), ep
print('yaml structure ok')
EOF
then pass "envoy-go-native.yaml structure (listener :10000, golang+router, cluster backend:8080)";
else fail "envoy-go-native.yaml structure"; fi

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
# check above already FAILs until `bash filters/go-native/build.sh` runs).
if [ -f "$SO" ]; then
  VALIDATE_OUT="$(docker run --rm -v "$CONFIG:/etc/envoy/envoy.yaml:ro" \
    -v "$SO:/lib/go-native/bench-go.so:ro" "$IMAGE" \
    --mode validate -c /etc/envoy/envoy.yaml 2>&1)"
  VALIDATE_RC=$?
  echo "$VALIDATE_OUT" | tail -3
  if [ "$VALIDATE_RC" = "0" ]; then
    pass "envoy --mode validate accepts envoy-go-native.yaml"
  else
    fail "envoy --mode validate accepts envoy-go-native.yaml"
  fi
else
  echo "SKIP envoy --mode validate: $SO not built yet"
fi

if [ ! -f "$SO" ]; then
  echo "SKIP part 2 (e2e): $SO not built; run bash filters/go-native/build.sh first"
  echo "RESULT: static-only ($FAIL failed, $PASS passed)"
  [ "$FAIL" = "0" ]
  exit $?
fi

echo "=== part 2: e2e (docker + envoy + go-native) ==="
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
  docker rm -f envoy-go-test >/dev/null 2>&1 || true
  kill "$BACKEND_PID" >/dev/null 2>&1 || true
  rm -rf "$TMPD"
}
trap cleanup EXIT
docker rm -f envoy-go-test >/dev/null 2>&1 || true

python3 "$BACKEND_PY" &
BACKEND_PID=$!
sleep 1
kill -0 "$BACKEND_PID" 2>/dev/null || { fail "stub backend starts on :8080"; exit 1; }
pass "stub backend starts on :8080"

docker run -d --name envoy-go-test \
  --add-host=backend:host-gateway \
  -p 127.0.0.1:10000:10000 \
  -v "$CONFIG:/etc/envoy/envoy.yaml:ro" \
  -v "$SO:/lib/go-native/bench-go.so:ro" \
  "$IMAGE" -c /etc/envoy/envoy.yaml >/dev/null
ready=0
for _ in $(seq 1 60); do
  if curl -sS -o /dev/null http://127.0.0.1:10000/ 2>/dev/null; then ready=1; break; fi
  sleep 1
done
[ "$ready" = "1" ] || { fail "envoy listener ready on :10000"; docker logs envoy-go-test 2>&1 | tail -20; exit 1; }
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
has caseA x-echo-x-bench-tag go
has caseA x-echo-x-request-touched true
has caseA x-echo-x-filter-type go
has caseA x-resp-added go
has caseA x-resp-version v1
has caseA x-gateway envoy-go
nohdr caseA server
nohdr caseA x-drop-me
nohdr caseA x-echo-x-drop-me
grep -qi "^x-echo-x-auth-retry:" "$TMPD/caseA.hdr" \
  && fail "caseA: no x-echo-x-auth-retry" || pass "caseA: no x-echo-x-auth-retry"

# Case B: no key + default curl UA (no "benchmark").
get caseB
has caseB x-echo-x-auth-status unauthenticated
has caseB x-echo-x-auth-retry true
has caseB x-echo-x-bench-tag go-default
has caseB x-resp-added go
has caseB x-resp-version v1
has caseB x-gateway envoy-go
nohdr caseB server
nohdr caseB x-drop-me

# Case C: client x-drop-me must be stripped before upstream.
get caseC -H "x-api-key: test-key-123" -H "x-drop-me: 1"
nohdr caseC x-echo-x-drop-me
has caseC x-echo-x-auth-status authenticated

echo "RESULT: e2e ($FAIL failed, $PASS passed)"
[ "$FAIL" = "0" ]
