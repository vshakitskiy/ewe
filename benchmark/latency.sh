#!/usr/bin/env bash
#
# Usage: ./latency.sh [--servers ewe@5,bandit] [--cases hello,sse_big]

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
source "$ROOT/config.sh"
source "$ROOT/lib.sh"

ONLY_SERVERS=""
ONLY_CASES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --servers) ONLY_SERVERS="$2"; shift 2 ;;
    --cases) ONLY_CASES="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

WRK2="${WRK2:-$ROOT/.wrk2/wrk2}"
[ -x "$WRK2" ] || WRK2="$(command -v wrk2 || true)"
[ -x "$WRK2" ] || { echo "wrk2 not found, run ./wrk2-setup.sh first" >&2; exit 1; }

ensure_fixtures
new_results_dir latency
CSV="$RESULTS_DIR/latency.csv"
echo "server,case,target_rate,achieved_rate,p50,p90,p99,p999,p50_raw,p99_raw,errors" > "$CSV"

{
  echo "date        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "load        wrk2 http/1, ${CONNECTIONS} connections, ${THREADS} threads, fixed rates"
  echo "duration    ${DURATION}s per rate"
  echo "cpu         server on ${SERVER_CPUS}, load generator on ${LOAD_CPUS}"
} | tee "$RESULTS_DIR/run.txt"
echo

parse_wrk2() {
  awk '
    /Latency Distribution \(HdrHistogram - Recorded Latency\)/    { section = "corrected"; next }
    /Latency Distribution \(HdrHistogram - Uncorrected Latency/   { section = "raw"; next }
    section == "corrected" && / 50\.000%/ { p50 = $2 }
    section == "corrected" && / 90\.000%/ { p90 = $2 }
    section == "corrected" && / 99\.000%/ { p99 = $2 }
    section == "corrected" && / 99\.900%/ { p999 = $2 }
    section == "raw" && / 50\.000%/       { raw50 = $2 }
    section == "raw" && / 99\.000%/       { raw99 = $2 }
    /Requests\/sec:/                      { rate = $2; finished = 1 }
    /Socket errors:/                      { gsub(",", ""); errors = $0 }
    END {
      if (!finished) exit 1
      printf "%s|%s|%s|%s|%s|%s|%s|%s\n", rate, p50, p90, p99, p999, raw50, raw99, errors
    }
  '
}

run_rate() {
  local rate="$1" script raw parsed
  local achieved p50 p90 p99 p999 raw50 raw99 errors
  local args=()

  script="$(wrk_script "$case_name")"
  [ -n "$script" ] && args+=(-s "$ROOT/wrk/$script")

  raw="$RESULTS_DIR/${server}__${case_name}__${rate}.txt"
  if ! parsed="$("${PIN_LOAD[@]}" "$WRK2" -t"$THREADS" -c"$CONNECTIONS" -d"${DURATION}s" \
    -R"$rate" -U "${args[@]}" "http://127.0.0.1:$port$path" 2>&1 | tee "$raw" | parse_wrk2)"; then
    printf '    %8s target  failed, see %s\n' "$rate" "$raw"
    return 1
  fi

  IFS='|' read -r achieved p50 p90 p99 p999 raw50 raw99 errors <<< "$parsed"

  echo "$server,$case_name,$rate,$achieved,$p50,$p90,$p99,$p999,$raw50,$raw99,$errors" >> "$CSV"
  printf '    %8s target  %10s actual  p50 %9s  p99 %9s  raw p99 %9s\n' \
    "$rate" "$achieved" "$p50" "$p99" "$raw99"
}

for server_entry in "${SERVERS[@]}"; do
  IFS='|' read -r server dir cmd h1_port _h2_port <<< "$server_entry"
  selected "$server" "$ONLY_SERVERS" || continue
  [ "$h1_port" = "-" ] && continue
  port="$h1_port"

  echo "=== $server ==="
  start_server "$dir" "$cmd" "$port" "$RESULTS_DIR/$server.log" || continue

  "${PIN_LOAD[@]}" "$WRK2" -t"$THREADS" -c"$CONNECTIONS" -d"${WARMUP}s" -R"$WARMUP_RATE" \
    "http://127.0.0.1:$port/hello" > /dev/null 2>&1

  for case_entry in "${CASES[@]}"; do
    IFS='|' read -r case_name path _body _headers _messages <<< "$case_entry"
    selected "$case_name" "$ONLY_CASES" || continue

    if unsupported "$server" "$case_name"; then
      printf '  %-20s not supported\n' "$case_name"
      continue
    fi

    echo "  $case_name"
    for rate in $(latency_rates "$case_name"); do
      run_rate "$rate"
    done
  done

  stop_server
  echo
done

render_report "$CSV"
