#!/bin/bash
# Switch the Envoy filter variant and verify it serves traffic.
# usage: ./scripts/switch-variant.sh [baseline|lua|wasm|go-native|gonvoy]
# Sets FILTER_VARIANT, recreates the envoy service (compose remounts
# ./envoy/envoy-${FILTER_VARIANT}.yaml), waits for admin /ready, then curls
# the data path and checks the x-resp-added marker for the active filter
# (absent for baseline). Prints the active filter on success.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VARIANT="${1:-}"
case "$VARIANT" in
  baseline|lua|wasm|go-native|gonvoy) ;;
  *) echo "usage: $0 [baseline|lua|wasm|go-native|gonvoy]" >&2; exit 1 ;;
esac

# Canonical x-resp-added marker per variant (docs/FILTER_SPEC.md;
# go-native uses filter-name "go"). Baseline adds no response headers.
case "$VARIANT" in
  baseline)  EXPECT_RESP_ADDED="" ;;
  lua)       EXPECT_RESP_ADDED="lua" ;;
  wasm)      EXPECT_RESP_ADDED="wasm" ;;
  go-native) EXPECT_RESP_ADDED="go" ;;
  gonvoy)    EXPECT_RESP_ADDED="gonvoy" ;;
esac

export FILTER_VARIANT="$VARIANT"
docker compose up -d backend
# --force-recreate: the volume source changes with FILTER_VARIANT; recreate
# unconditionally so a stale config can never survive a switch. --no-deps:
# leave a healthy backend untouched.
docker compose up -d --force-recreate --no-deps envoy

echo "waiting for envoy admin /ready ..."
for i in $(seq 1 60); do
  if curl -sf -o /dev/null http://localhost:9901/ready; then
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "envoy admin never became ready" >&2
    docker compose logs --tail=50 envoy
    exit 1
  fi
  sleep 1
done

echo "probing http://localhost:10000/ ..."
RESP_HEADERS="$(mktemp)"
trap 'rm -f "$RESP_HEADERS"' EXIT
CODE="$(curl -s -D "$RESP_HEADERS" -o /dev/null -w "%{http_code}" \
  http://localhost:10000/ \
  -H "x-api-key: test-key-123" \
  -H "user-agent: benchmark-agent" \
  -H "x-drop-me: 1")"
GOT="$(grep -i '^x-resp-added:' "$RESP_HEADERS" | awk '{print $2}' | tr -d '\r' || true)"

echo "active filter: $VARIANT (FILTER_VARIANT=$FILTER_VARIANT) http_status=$CODE x-resp-added=${GOT:-<absent>}"
if [ "$CODE" != "200" ]; then
  echo "FAIL: expected HTTP 200, got $CODE" >&2
  cat "$RESP_HEADERS" >&2
  docker compose logs --tail=30 envoy >&2
  exit 1
fi
if [ "$GOT" != "$EXPECT_RESP_ADDED" ]; then
  echo "FAIL: expected x-resp-added '${EXPECT_RESP_ADDED:-<absent>}', got '${GOT:-<absent>}'" >&2
  exit 1
fi
echo "PASS: $VARIANT"
