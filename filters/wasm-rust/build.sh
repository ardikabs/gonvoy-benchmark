#!/bin/bash
# Build the bench_header.wasm artifact for the WASM filter variant.
# Requires the wasm32-unknown-unknown target; installs it via rustup when
# rustup is available, then compiles the release cdylib.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if command -v rustup >/dev/null 2>&1; then
  rustup target add wasm32-unknown-unknown
fi
cargo build --release --target wasm32-unknown-unknown
ls -la target/wasm32-unknown-unknown/release/bench_header.wasm
