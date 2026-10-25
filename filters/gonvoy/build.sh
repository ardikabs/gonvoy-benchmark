#!/bin/bash
# Build the gonvoy filter shared library (Task 5).
# Envoy loads filters/gonvoy/gonvoy.so at /lib/gonvoy.so (see
# envoy/envoy-gonvoy.yaml and tests/test_gonvoy.sh).
#
# NOTE: -buildmode=c-shared requires cgo with a Linux C toolchain when
# targeting the envoy container. On macOS hosts without a cross compiler,
# build inside the golang image instead:
#   docker run --rm -v "$PWD:/src" -w /src golang:1.26-bookworm \
#     go build -o gonvoy.so -buildmode=c-shared .
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
go build -o gonvoy.so -buildmode=c-shared .
