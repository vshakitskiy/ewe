#!/usr/bin/env bash
#
# Usage: ./throughput.sh [--servers ewe@5,bandit] [--cases sse_big]
#                        [--profiles h1,h2,h2-serial]

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
source "$ROOT/config.sh"
source "$ROOT/lib.sh"

ONLY_SERVERS=""
ONLY_CASES=""
ONLY_PROFILES="$DEFAULT_PROFILES"
while [ $# -gt 0 ]; do
  case "$1" in
    --servers) ONLY_SERVERS="$2"; shift 2 ;;
    --cases) ONLY_CASES="$2"; shift 2 ;;
    --profiles) ONLY_PROFILES="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

command -v h2load > /dev/null || { echo "h2load not found (install nghttp2)" >&2; exit 1; }

ensure_fixtures
new_results_dir throughput
CSV="$RESULTS_DIR/throughput.csv"
echo "server,profile,protocol,connections,streams,case,repeat,requests_per_sec,messages,messages_per_sec,mb_per_sec,succeeded,failed,non_2xx" > "$CSV"

{
  echo "date        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "load        h2load, ${THREADS} threads"
  for profile_entry in "${PROFILES[@]}"; do
    IFS='|' read -r profile protocol connections streams <<< "$profile_entry"
    selected "$profile" "$ONLY_PROFILES" || continue
    printf '            %-10s %s, %s connections x %s stream(s)\n' \
      "$profile" "$protocol" "$connections" "$streams"
  done
  echo "duration    ${DURATION}s measured, ${WARMUP}s warmup, ${REPEATS} repeats per cell"
  echo "cpu         server on ${SERVER_CPUS}, load generator on ${LOAD_CPUS}"
} | tee "$RESULTS_DIR/run.txt"
echo

set_protocol_args() {
  case "$1" in
    h1) PROTOCOL_ARGS=(--h1) ;;
    h2) PROTOCOL_ARGS=(-p h2c) ;;
    *) echo "unknown protocol: $1" >&2; exit 1 ;;
  esac
}

parse_h2load() {
  awk '
    /^finished in/   { gsub(",", ""); rate = $4; mb = $6; sub("MB/s", "", mb); finished = 1 }
    /^requests:/     { gsub(",", ""); succeeded = $8; failed = $10 + $12 + $14 }
    /^status codes:/ { gsub(",", ""); non2xx = $5 + $7 + $9 }
    END {
      if (!finished) exit 1
      printf "%s|%s|%s|%s|%s\n", rate + 0, mb + 0, succeeded + 0, failed + 0, non2xx + 0
    }
  '
}

run_case() {
  local repeat="$1" body_path raw parsed
  local rate mb succeeded failed non2xx messages_per_sec

  set_protocol_args "$protocol"
  local args=("${PROTOCOL_ARGS[@]}" -c "$connections" -m "$streams" -t "$THREADS" -D "$DURATION")
  [ "$headers" = "yes" ] && args+=("${HEADER_ARGS[@]}")

  body_path="$(body_file "$body")"
  [ -n "$body_path" ] && args+=(-d "$body_path")

  raw="$RESULTS_DIR/${server}__${profile}__${case_name}__${repeat}.txt"
  if ! parsed="$("${PIN_LOAD[@]}" h2load "${args[@]}" "http://127.0.0.1:$port$path" 2>&1 \
    | tee "$raw" | parse_h2load)"; then
    printf 'failed '
    return 1
  fi

  IFS='|' read -r rate mb succeeded failed non2xx <<< "$parsed"
  messages_per_sec="$(awk -v r="$rate" -v m="$messages" 'BEGIN { printf "%.0f", r * m }')"

  echo "$server,$profile,$protocol,$connections,$streams,$case_name,$repeat,$rate,$messages,$messages_per_sec,$mb,$succeeded,$failed,$non2xx" >> "$CSV"
  printf '%s ' "$rate"
}

for server_entry in "${SERVERS[@]}"; do
  IFS='|' read -r server dir cmd h1_port h2_port <<< "$server_entry"
  selected "$server" "$ONLY_SERVERS" || continue

  echo "=== $server ==="
  start_server "$dir" "$cmd" "$(startup_port "$h1_port" "$h2_port")" "$RESULTS_DIR/$server.log" || continue

  for profile_entry in "${PROFILES[@]}"; do
    IFS='|' read -r profile protocol connections streams <<< "$profile_entry"
    selected "$profile" "$ONLY_PROFILES" || continue

    if [ "$protocol" = h1 ]; then
      port="$h1_port"
    else
      port="$h2_port"
    fi
    [ "$port" = "-" ] && continue

    set_protocol_args "$protocol"
    "${PIN_LOAD[@]}" h2load "${PROTOCOL_ARGS[@]}" \
      -c "$connections" -m "$streams" -t "$THREADS" -D "$WARMUP" \
      "http://127.0.0.1:$port/hello" > /dev/null 2>&1

    for case_entry in "${CASES[@]}"; do
      IFS='|' read -r case_name path body headers messages <<< "$case_entry"
      selected "$case_name" "$ONLY_CASES" || continue

      if unsupported "$server" "$case_name"; then
        printf '  %-10s %-20s not supported\n' "$profile" "$case_name"
        continue
      fi

      printf '  %-10s %-20s ' "$profile" "$case_name"
      for ((repeat = 1; repeat <= REPEATS; repeat++)); do
        run_case "$repeat"
      done
      echo "req/s"
    done
  done

  stop_server
  echo
done

render_report "$CSV"
