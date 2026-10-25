#!/bin/bash
# Load harness (Task 7): drive fixed-RPS load with nighthawk across Envoy
# filter variants and save raw JSON + resource snapshots for
# scripts/parse-results.py.
#
# usage:
#   ./scripts/run-benchmark.sh [--rps 1000,5000,20000] [--duration 60s]
#     [--repeats 3] [--variants all] [--warmup 10s] [--results-dir results/raw]
#
# Per <variant, rps, rep> combo:
#   1. switch to the variant via scripts/switch-variant.sh (verifies serving),
#   2. warmup run at the same RPS for --warmup (output discarded),
#   3. measured run: nighthawk_client with the canonical Task 7 headers
#      (x-api-key: test-key-123, user-agent: benchmark-agent),
#      --output-format json saved to <results-dir>/<variant>-<rps>-<rep>.json,
#      while docker stats for the envoy container is sampled in the
#      background to <variant>-<rps>-<rep>.stats.csv.
# Once per invocation: capture-env.sh output + pinned image digests + git SHA
# are saved alongside the raw results (floating tags must be pinned/digested
# at bench time, otherwise runs are not comparable).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RPS_LIST="1000,5000,20000"
DURATION="60s"
REPEATS=3
VARIANTS="all"
WARMUP="10s"
RESULTS_DIR="results/raw"
ALL_VARIANTS="baseline,lua,wasm,go-native,gonvoy"
NIGHTHAWK_IMAGE="envoyproxy/nighthawk-dev:latest"

usage() {
  echo "usage: $0 [--rps 1000,5000,20000] [--duration 60s] [--repeats 3] [--variants all|baseline,lua,...] [--warmup 10s] [--results-dir results/raw]" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --rps)         RPS_LIST="${2:-}"; shift 2 ;;
    --duration)    DURATION="${2:-}"; shift 2 ;;
    --repeats)     REPEATS="${2:-}"; shift 2 ;;
    --variants)    VARIANTS="${2:-}"; shift 2 ;;
    --warmup)      WARMUP="${2:-}"; shift 2 ;;
    --results-dir) RESULTS_DIR="${2:-}"; shift 2 ;;
    -h|--help)     usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

# Strip a trailing "s" ("60s" -> "60"); nighthawk --duration takes uint32 sec.
strip_s() { echo "${1%s}"; }
DUR_SECS="$(strip_s "$DURATION")"
WARMUP_SECS="$(strip_s "$WARMUP")"
case "$DUR_SECS$WARMUP_SECS$REPEATS" in
  *[!0-9]*|'') echo "duration/warmup/repeats must be numeric (got duration=$DURATION warmup=$WARMUP repeats=$REPEATS)" >&2; exit 1 ;;
esac

if [ "$VARIANTS" = "all" ]; then
  VARIANTS="$ALL_VARIANTS"
fi
RPS_CSV="$(echo "$RPS_LIST" | tr ',' ' ')"
VAR_CSV="$(echo "$VARIANTS" | tr ',' ' ')"

mkdir -p "$RESULTS_DIR"

echo "=== benchmark run: variants=[$VAR_CSV] rps=[$RPS_CSV] duration=${DUR_SECS}s repeats=$REPEATS warmup=${WARMUP_SECS}s ==="

# --- once-per-run environment capture -------------------------------------
./scripts/capture-env.sh > "$RESULTS_DIR/env.txt" 2>&1 || echo "capture-env.sh failed (see $RESULTS_DIR/env.txt)" >&2
{
  echo "date_utc=$(date -u +%FT%TZ)"
  echo "git_sha=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "git_status=$(git status --short 2>/dev/null | tr '\n' ';' || echo unknown)"
  echo "nighthawk_version=$(docker run --rm --entrypoint /usr/local/bin/nighthawk_client "$NIGHTHAWK_IMAGE" --version 2>&1 | grep -v WARNING | grep -v '^$' | head -1 || echo unknown)"
  echo "--- image digests (pinned at bench time; floating tags are not comparable without these) ---"
  for img in envoyproxy/envoy:contrib-v1.40-latest mendhak/http-https-echo:latest "$NIGHTHAWK_IMAGE"; do
    printf '%s RepoDigest=%s\n' "$img" "$(docker inspect --format '{{.RepoDigests}}' "$img" 2>/dev/null || echo inspect-failed)"
  done
  echo "--- compose images ---"
  docker compose images 2>/dev/null || echo "docker compose images unavailable"
} > "$RESULTS_DIR/meta.txt" 2>&1 || true
echo "env snapshot -> $RESULTS_DIR/env.txt, $RESULTS_DIR/meta.txt"

# --- helpers ---------------------------------------------------------------
# Stream `docker stats` for the envoy container (~1Hz) into raw file $1,
# prefixing each sample with a UTC timestamp. Killed by the caller when the
# measured run ends. Targets the exact compose container id ($2) so other
# projects' containers can never pollute the samples.
start_stats() {
  local raw="$1" cid="$2"
  : > "$raw"
  docker stats --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' "$cid" 2>/dev/null \
    | while IFS= read -r line; do
        printf '%s|%s\n' "$(date -u +%FT%TZ)" "$line"
      done >> "$raw" &
  STATS_PID=$!
}

# Convert streaming raw stats (ANSI control codes included) into the
# canonical CSV: timestamp_utc,container,cpu_pct,mem_used_mib,mem_limit_mib.
normalize_stats() {
  python3 - "$1" <<'EOF'
import csv, re, sys
path = sys.argv[1]
ansi = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b\([AB0]|\r')
def mib(s):
    m = re.match(r'\s*([\d.]+)\s*([KMGT]?i?B)\s*', s or '')
    if not m: return ''
    v, u = float(m.group(1)), m.group(2)
    mult = {'B': 1/1048576., 'KB': 1/1024., 'MB': 1., 'GB': 1024.,
            'KIB': 1/1024., 'MIB': 1., 'GIB': 1024.,
            'Kib': 1/1024., 'MiB': 1., 'GiB': 1024.}
    return str(round(v * mult.get(u.upper(), 1), 3))
rows = []
with open(path) as f:
    for line in f:
        line = ansi.sub('', line).strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split('|')]
        if len(parts) != 4:
            continue
        ts, name, cpu, mem = parts
        cpu = cpu.rstrip('%')
        try:
            float(cpu)
        except ValueError:
            continue
        used, _, limit = mem.partition('/')
        key = (ts, name, cpu, mib(used), mib(limit))
        if rows and rows[-1] == list(key):
            continue  # streaming stats repeats identical frames; keep first
        rows.append(list(key))
with open(path, 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(['timestamp_utc', 'container', 'cpu_pct', 'mem_used_mib', 'mem_limit_mib'])
    w.writerows(rows)
EOF
}

run_nighthawk() {
  # $1=rps $2=duration_secs $3=output file (/dev/null to discard warmup)
  # Load shape is fixed methodology: --concurrency 1 (single nighthawk event
  # loop, so loader-side parallelism never varies between runs) with
  # --connections 100 (nighthawk default cap per loop; high-RPS runs share
  # this pool). These are pinned, not scaled with RPS, so compare variants
  # only within one run; host CPU count is recorded in env.txt (nproc).
  local rps="$1" dur="$2" out="$3" err
  err="$(mktemp)"
  if docker compose --profile load run -T --rm --entrypoint /usr/local/bin/nighthawk_client loader \
    --rps "$rps" --duration "$dur" \
    --concurrency 1 --connections 100 \
    --request-header "x-api-key: test-key-123" \
    --request-header "user-agent: benchmark-agent" \
    --output-format json \
    http://envoy:10000/ > "$out" 2>"$err"; then
    rm -f "$err"
    return 0
  else
    echo "WARN: nighthawk rps=$rps dur=${dur}s exited nonzero:" >&2
    tail -5 "$err" >&2 || true
    rm -f "$err"
    return 1
  fi
}

# --- main loop -------------------------------------------------------------
for variant in $VAR_CSV; do
  case "$variant" in
    baseline|lua|wasm|go-native|gonvoy) ;;
    *) echo "unknown variant: $variant (want one of $ALL_VARIANTS)" >&2; exit 1 ;;
  esac
  echo "--- variant: $variant ---"
  ./scripts/switch-variant.sh "$variant"

  for rps in $RPS_CSV; do
    echo "warmup: $variant @ ${rps}rps for ${WARMUP_SECS}s (discarded)"
    run_nighthawk "$rps" "$WARMUP_SECS" /dev/null || echo "WARN: warmup failed for $variant @ $rps, continuing" >&2

    for rep in $(seq 1 "$REPEATS"); do
      json="$RESULTS_DIR/${variant}-${rps}-${rep}.json"
      csv="$RESULTS_DIR/${variant}-${rps}-${rep}.stats.csv"
      echo "measure: $variant @ ${rps}rps rep $rep/${REPEATS} (${DUR_SECS}s)"
      ENVOY_CID="$(docker compose ps -q envoy 2>/dev/null || true)"
      if [ -z "$ENVOY_CID" ]; then
        echo "WARN: envoy container id not found; stats will be missing for $json" >&2
      else
        start_stats "$csv" "$ENVOY_CID"
      fi
      if run_nighthawk "$rps" "$DUR_SECS" "$json"; then
        echo "  saved $json"
      else
        echo "WARN: measured run failed for $variant @ $rps rep $rep (partial $json kept)" >&2
      fi
      if [ -n "${STATS_PID:-}" ]; then
        kill "$STATS_PID" 2>/dev/null || true
        wait "$STATS_PID" 2>/dev/null || true
        unset STATS_PID
      fi
      normalize_stats "$csv"
      echo "  stats $csv ($(($(wc -l < "$csv") - 1)) samples)"
    done
  done
done

echo "=== done: raw results in $RESULTS_DIR ==="
echo "next: python3 scripts/parse-results.py --raw-dir $RESULTS_DIR --output results/summary.md"
