#!/bin/bash
# Build the native Go filter shared library (Task 4).
# Envoy loads filters/go-native/bench-go.so at /lib/bench-go.so (see
# envoy/envoy-go-native.yaml and tests/test_go_native.sh).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
go build -buildmode=c-shared -o bench-go.so .
