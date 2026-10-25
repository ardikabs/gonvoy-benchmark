#!/bin/bash
# Capture benchmark environment details for reproducibility.
set -euo pipefail

echo "=== uname ==="
uname -a
echo
echo "=== cpu ==="
if command -v nproc >/dev/null 2>&1; then
  nproc
else
  sysctl -n hw.ncpu 2>/dev/null || echo "nproc unavailable"
fi
echo
echo "=== memory ==="
if command -v free >/dev/null 2>&1; then
  free -h
else
  vm_stat 2>/dev/null || echo "memory info unavailable"
  sysctl hw.memsize 2>/dev/null || true
fi
echo
echo "=== docker ==="
docker info 2>/dev/null || echo "docker info unavailable"
echo
echo "=== envoy ==="
if command -v envoy >/dev/null 2>&1; then
  envoy --version
else
  echo "envoy binary not on PATH (version captured from container image at bench time)"
fi
