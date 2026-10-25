#!/bin/bash
# Smoke test for the Lua header filter (Task 2).
#
# What it does:
#   1. Static checks (always run, no docker needed):
#      - filters/lua/filter.lua exists, passes Lua syntax check, defines
#        envoy_on_request/envoy_on_response, uses only headers()
#        get/add/replace/remove, makes no body calls.
#      - envoy/envoy-lua.yaml exists, parses as YAML, has listener
#        0.0.0.0:10000, lua filter before router, route prefix / to cluster
#        backend:8080, and its inline Lua matches filters/lua/filter.lua.
#      - envoy --mode validate on the config (via docker image if present).
#   2. End-to-end checks (needs docker + envoyproxy/envoy:contrib-v1.40-latest):
#      - starts a stub backend on host :8080 that echoes request headers back
#        as x-echo-* response headers,
#      - starts envoy in docker with --add-host=backend:host-gateway,
#      - runs the curl matrix below and asserts response/request headers.
#
# Curl matrix (all against http://127.0.0.1:10000/):
#   A. -H "x-api-key: test-key-123" -H "user-agent: benchmark-agent/1.0"
#      -> x-echo-x-auth-status: authenticated, x-echo-x-bench-tag: lua
#   B. no x-api-key, default curl UA (no "benchmark" substring)
#      -> x-echo-x-auth-status: unauthenticated, x-echo-x-auth-retry: true,
#         x-echo-x-bench-tag: lua-default
#   C. -H "x-drop-me: 1" -> backend must NOT see it (no x-echo-x-drop-me)
#   A/B/C. response always has x-resp-added: lua, x-resp-version: v1,
#      x-gateway: envoy-lua, and must NOT contain server: or x-drop-me:
#
# If docker or the envoy image is unavailable, part 2 is skipped and the
# script reports what was / wasn't runnable (exit 0 iff static checks pass).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER="$ROOT/filters/lua/filter.lua"
CONFIG="$ROOT/envoy/envoy-lua.yaml"
IMAGE="envoyproxy/envoy:contrib-v1.40-latest"
ENVOY_PORT=10000
BACKEND_PORT=8080
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

echo "=== part 1: static checks (no docker needed) ==="

[ -f "$FILTER" ] || { fail "filters/lua/filter.lua exists"; }
[ -f "$CONFIG" ] || { fail "envoy/envoy-lua.yaml exists"; }
if [ ! -f "$FILTER" ] || [ ! -f "$CONFIG" ]; then
  echo "RESULT: FAIL ($FAIL failed, $PASS passed) - implementation files missing"
  exit 1
fi
pass "implementation files exist"

# Lua syntax check (luac preferred; lua load() fallback; skip if neither).
if command -v luac >/dev/null 2>&1; then
  if luac -p "$FILTER" 2>lua_err.txt; then pass "filter.lua parses (luac -p)";
  else fail "filter.lua parses (luac -p): $(cat lua_err.txt)"; fi
  rm -f lua_err.txt
elif command -v lua >/dev/null 2>&1; then
  if lua -e "assert(loadfile('$FILTER'))" 2>/dev/null; then pass "filter.lua parses (lua loadfile)";
  else fail "filter.lua parses (lua loadfile)"; fi
else
  echo "SKIP: no luac/lua on PATH, syntax check omitted"
fi

# Exact entry-point names.
grep -q "function envoy_on_request(request_handle)" "$FILTER" \
  && pass "defines envoy_on_request(request_handle)" \
  || fail "defines envoy_on_request(request_handle)"
grep -q "function envoy_on_response(response_handle)" "$FILTER" \
  && pass "defines envoy_on_response(response_handle)" \
  || fail "defines envoy_on_response(response_handle)"

# Header-only API: allow :headers/:get/:add/:replace/:remove/string/handle ops;
# forbid body and other handle APIs.
if grep -nE ":(body|bodyChunks|trailers|getBody|appendBody|log[A-Z]|httpCall|streamInfo|connection|ssl)" "$FILTER" \
  | grep -v "^.*--" >/dev/null 2>&1; then
  fail "filter uses only headers() get/add/replace/remove (no body/log/httpCall)"
else
  pass "filter uses only headers() get/add/replace/remove (no body/log/httpCall)"
fi
for m in ':get(' ':add(' ':replace(' ':remove('; do
  grep -q "$m" "$FILTER" || fail "filter uses headers()$m"
done
pass "filter calls headers() get/add/replace/remove"

# Spec branches present verbatim.
grep -q 'test-key-123' "$FILTER" && pass "branches on x-api-key == test-key-123" \
  || fail "branches on x-api-key == test-key-123"
grep -q 'string.find.*benchmark.*1, true' "$FILTER" && pass "plain string.find for benchmark UA" \
  || fail "plain string.find for benchmark UA"
for h in x-auth-status x-auth-retry x-bench-tag x-request-touched x-filter-type x-drop-me x-resp-added x-resp-version x-gateway server; do
  grep -q "$h" "$FILTER" || fail "filter mentions header $h"
done
pass "filter mentions all spec headers"

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
assert names == ['envoy.filters.http.lua', 'envoy.filters.http.router'], names
route = tc['route_config']['virtual_hosts'][0]['routes'][0]
assert route['match'] == {'prefix': '/'}, route['match']
assert route['route']['cluster'] == 'backend:8080', route['route']
assert 'default_source_code' in tc['http_filters'][0]['typed_config'], 'inline lua missing'
assert 'inline_string' in tc['http_filters'][0]['typed_config']['default_source_code'], 'inline lua missing'
clusters = {c['name']: c for c in cfg['static_resources']['clusters']}
assert 'backend:8080' in clusters, list(clusters)
ep = clusters['backend:8080']['load_assignment']['endpoints'][0]['lb_endpoints'][0]['endpoint']['address']['socket_address']
assert (ep['address'], ep['port_value']) == ('backend', 8080), ep
print('yaml structure ok')
EOF
then pass "envoy-lua.yaml structure (listener :10000, lua+router, cluster backend:8080)";
else fail "envoy-lua.yaml structure"; fi

# Inline Lua must match filter.lua verbatim (drift guard).
if python3 - "$CONFIG" "$FILTER" <<'EOF'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
inline = cfg['static_resources']['listeners'][0]['filter_chains'][0]['filters'][0] \
  ['typed_config']['http_filters'][0]['typed_config']['default_source_code']['inline_string']
src = open(sys.argv[2]).read()
assert inline == src, 'inline lua differs from filters/lua/filter.lua'
print('inline lua matches')
EOF
then pass "inline lua matches filters/lua/filter.lua";
else fail "inline lua matches filters/lua/filter.lua"; fi

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
VALIDATE_OUT="$(docker run --rm -v "$CONFIG:/etc/envoy/envoy.yaml:ro" "$IMAGE" \
  --mode validate -c /etc/envoy/envoy.yaml 2>&1)"
VALIDATE_RC=$?
echo "$VALIDATE_OUT" | tail -3
if [ "$VALIDATE_RC" = "0" ]; then
  pass "envoy --mode validate accepts envoy-lua.yaml"
else
  fail "envoy --mode validate accepts envoy-lua.yaml"
fi

echo "=== part 2: e2e (docker + envoy) ==="
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
  docker rm -f envoy-lua-test >/dev/null 2>&1 || true
  kill "$BACKEND_PID" >/dev/null 2>&1 || true
  rm -rf "$TMPD"
}
trap cleanup EXIT
docker rm -f envoy-lua-test >/dev/null 2>&1 || true

python3 "$BACKEND_PY" &
BACKEND_PID=$!
sleep 1
kill -0 "$BACKEND_PID" 2>/dev/null || { fail "stub backend starts on :8080"; exit 1; }
pass "stub backend starts on :8080"

docker run -d --name envoy-lua-test \
  --add-host=backend:host-gateway \
  -p 127.0.0.1:10000:10000 \
  -v "$CONFIG:/etc/envoy/envoy.yaml:ro" \
  "$IMAGE" -c /etc/envoy/envoy.yaml >/dev/null
ready=0
for _ in $(seq 1 60); do
  if curl -sS -o /dev/null http://127.0.0.1:10000/ 2>/dev/null; then ready=1; break; fi
  sleep 1
done
[ "$ready" = "1" ] || { fail "envoy listener ready on :10000"; exit 1; }
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
has caseA x-echo-x-bench-tag lua
has caseA x-echo-x-request-touched true
has caseA x-echo-x-filter-type lua
has caseA x-resp-added lua
has caseA x-resp-version v1
has caseA x-gateway envoy-lua
nohdr caseA '^server'
nohdr caseA x-drop-me
nohdr caseA x-echo-x-drop-me
grep -qi "^x-echo-x-auth-retry:" "$TMPD/caseA.hdr" \
  && fail "caseA: no x-echo-x-auth-retry" || pass "caseA: no x-echo-x-auth-retry"

# Case B: no key + default curl UA (no "benchmark").
get caseB
has caseB x-echo-x-auth-status unauthenticated
has caseB x-echo-x-auth-retry true
has caseB x-echo-x-bench-tag lua-default
has caseB x-resp-added lua
has caseB x-resp-version v1
has caseB x-gateway envoy-lua
nohdr caseB '^server'
nohdr caseB x-drop-me

# Case C: client x-drop-me must be stripped before upstream.
get caseC -H "x-api-key: test-key-123" -H "x-drop-me: 1"
nohdr caseC x-echo-x-drop-me
has caseC x-echo-x-auth-status authenticated

echo "RESULT: e2e ($FAIL failed, $PASS passed)"
[ "$FAIL" = "0" ]
