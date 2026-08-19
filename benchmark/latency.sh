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
echo "server,case,target_rate,achieved_rate,p50_us,p75_us,p90_us,p99_us,p999_us,p9999_us,p50_raw_us,p99_raw_us,connect_errors,read_errors,write_errors,timeouts,non_2xx,status" > "$CSV"

{
  echo "date        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "load        wrk2 http/1, ${CONNECTIONS} connections, ${THREADS} threads, fixed rates"
  echo "duration    ${DURATION}s per rate"
  echo "cpu         server on ${SERVER_CPUS}, load generator on ${LOAD_CPUS}"
  record_versions
} | tee "$RESULTS_DIR/run.txt"
echo

parse_wrk2() {
  awk -v target="$1" '
    function to_us(value,   number) {
      number = value + 0
      if (value ~ /us$/) return number
      if (value ~ /ms$/) return number * 1000
      if (value ~ /s$/)  return number * 1000000
      if (value ~ /m$/)  return number * 60000000
      if (value ~ /h$/)  return number * 3600000000
      return number
    }
    /Latency Distribution \(HdrHistogram - Recorded Latency\)/  { section = "corrected"; next }
    /Latency Distribution \(HdrHistogram - Uncorrected Latency/ { section = "raw"; next }
    section != "" && $1 ~ /^[0-9.]+%$/ { at[section $1] = to_us($2) }
    /^Requests\/sec:/           { achieved = $2; finished = 1 }
    /Non-2xx or 3xx responses:/ { non2xx = $5 }
    /Socket errors:/ {
      gsub(",", "")
      connect_errors = $4; read_errors = $6; write_errors = $8; timeouts = $10
    }
    END {
      if (!finished) exit 1
      status = "ok"
      if (non2xx > 0 || connect_errors > 0 || read_errors > 0 || write_errors > 0) status = "errors"
      if (achieved < 0.95 * target) status = "overload"
      if (at["raw50.000%"] == 0) status = "stalled"
      printf "%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%s\n", achieved,
        at["corrected50.000%"], at["corrected75.000%"], at["corrected90.000%"],
        at["corrected99.000%"], at["corrected99.900%"], at["corrected99.990%"],
        at["raw50.000%"], at["raw99.000%"],
        connect_errors + 0, read_errors + 0, write_errors + 0, timeouts + 0, non2xx + 0, status
    }
  '
}

show_us() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000)  printf "%.2fs", n / 1000000
    else if (n >= 1000) printf "%.2fms", n / 1000
    else printf "%dus", n
  }'
}

run_rate() {
  local rate="$1" script raw parsed
  local achieved p50 p75 p90 p99 p999 p9999 raw50 raw99
  local connect_errors read_errors write_errors timeouts non2xx status
  local args=()

  script="$(wrk_script "$case_name")"
  [ -n "$script" ] && args+=(-s "$ROOT/wrk/$script")

  raw="$RESULTS_DIR/${server}__${case_name}__${rate}.txt"
  if ! parsed="$("${PIN_LOAD[@]}" "$WRK2" -t"$THREADS" -c"$CONNECTIONS" -d"${DURATION}s" \
    -R"$rate" -U "${args[@]}" "http://127.0.0.1:$port$path" 2>&1 \
    | tee "$raw" | parse_wrk2 "$rate")"; then
    printf '    %8s target  failed, see %s\n' "$rate" "$raw"
    return 1
  fi

  IFS='|' read -r achieved p50 p75 p90 p99 p999 p9999 raw50 raw99 \
    connect_errors read_errors write_errors timeouts non2xx status <<< "$parsed"

  echo "$server,$case_name,$rate,$achieved,$p50,$p75,$p90,$p99,$p999,$p9999,$raw50,$raw99,$connect_errors,$read_errors,$write_errors,$timeouts,$non2xx,$status" >> "$CSV"
  printf '    %8s target  %10s actual  p50 %9s  p99 %9s  raw p99 %9s  %s\n' \
    "$rate" "$achieved" "$(show_us "$p50")" "$(show_us "$p99")" "$(show_us "$raw99")" "$status"
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
