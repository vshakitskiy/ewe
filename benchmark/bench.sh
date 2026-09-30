#!/usr/bin/env bash
#
# Benchmarks BEAM web servers over HTTP/1.1 and cleartext HTTP/2.
#
#   throughput  peak request rate with h2load
#   latency     latency percentiles at fixed request rates with zrk
#
# Usage: ./bench.sh throughput|latency [--servers a,b] [--cases a,b] [--protocols h1,h2]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONNECTIONS="${CONNECTIONS:-50}"
THREADS="${THREADS:-4}"
H2_STREAMS="${H2_STREAMS:-10}"
DURATION="${DURATION:-10}"
WARMUP="${WARMUP:-3}"
REPEATS="${REPEATS:-3}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-120}"

RATE_HELD=0.98

PROTOCOLS=(h1 h2)

# name|h1|h2|skips
SERVERS=(
  "ewe@9|3006|3006|-"
  "ewe@8|3001|3001|-"
  "mist|3002|-|-"
  "elli|3003|-|sse*,echo_chunked_10kb"
  "bandit|3004|3004|sse*"
  "httpd|3005|-|sse*,echo_chunked_10kb"
  "roadrunner|3007|3008|-"
  "chatterbox|-|8082|sse*"
  "cowboy|3009|3009|-"
  "mochiweb|3010|-|sse*"
  "yaws|3011|-|-"
)

# name|path|body|headers|rates
CASES=(
  "hello|/hello|-|no|50000 100000 150000"
  "hello_headers|/hello|-|yes|50000 100000 150000"
  "echo_1kb|/echo|body_1kb.bin|no|50000 100000 150000"
  "echo_1kb_headers|/echo|body_1kb.bin|yes|40000 80000 120000"
  "echo_10kb|/echo|body_10kb.bin|no|20000 60000 100000"
  "echo_chunked_10kb|/echo/chunked|body_10kb.bin|no|40000 70000 100000"
  "file_tiny|/file/tiny|-|no|20000 40000 60000"
  "file_small|/file/small|-|no|15000 30000 45000"
  "file_big|/file/big|-|no|500 1000 1500"
  "stream|/stream|-|no|20000 40000 60000"
  "stream_small|/stream/small|-|no|3000 5000 7000"
  "stream_big|/stream/big|-|no|3000 5000 7000"
  "sse|/sse|-|no|6000 10000 14000"
  "sse_small|/sse/small|-|no|3000 5000 7000"
  "sse_big|/sse/big|-|no|3000 5000 7000"
)

HEADERS=(
  -H "cookie: session=abc123def456"
  -H "cookie: theme=dark"
  -H "cookie: locale=en-US"
  -H "x-request-id: 9f86d081-b1bb-4c2e-8f21-9c7b1f2a0e3e"
  -H "x-client-version: 4.2.1"
  -H "accept-language: en-US,en;q=0.9"
  -H "x-forwarded-for: 203.0.113.42"
)

die() {
  echo "$*" >&2
  exit 1
}

require() {
  command -v "$1" > /dev/null || die "$1 not found, $2"
}

ONLY_SERVERS=""
ONLY_CASES=""
ONLY_PROTOCOLS=""

parse_args() {
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case "$1" in
      --servers) ONLY_SERVERS="$2" ;;
      --cases) ONLY_CASES="$2" ;;
      --protocols) ONLY_PROTOCOLS="$2" ;;
      *) die "unknown argument: $1" ;;
    esac
    shift 2
  done

  check_selection "$ONLY_SERVERS" "${SERVERS[@]}"
  check_selection "$ONLY_CASES" "${CASES[@]}"
  check_selection "$ONLY_PROTOCOLS" "${PROTOCOLS[@]}"
}

check_selection() {
  local selection="$1" name entry names
  shift
  IFS=',' read -ra names <<< "$selection"
  for name in "${names[@]}"; do
    for entry in "$@"; do
      [ "$name" = "${entry%%|*}" ] && continue 2
    done
    die "unknown name: $name"
  done
}

selected() {
  local name="$1" selection="$2"
  [ -z "$selection" ] || [[ ",$selection," == *",$name,"* ]]
}

pin_cpus() {
  SERVER_CPUS="unpinned"
  LOAD_CPUS="unpinned"
  PIN_SERVER=()
  PIN_LOAD=()
  [ "$(nproc)" -ge 4 ] || return 0

  read -r SERVER_CPUS LOAD_CPUS < <(lscpu -p=cpu,core | awk -F, '
    /^#/ { next }
    { n++; cpu[n] = $1; core[n] = $2; if (!($2 in rank)) rank[$2] = cores++ }
    END {
      for (i = 1; i <= n; i++) {
        if (rank[core[i]] < int(cores / 2)) server = server (server == "" ? "" : ",") cpu[i]
        else load = load (load == "" ? "" : ",") cpu[i]
      }
      print server, load
    }
  ')
  PIN_SERVER=(taskset -c "$SERVER_CPUS")
  PIN_LOAD=(taskset -c "$LOAD_CPUS")
}

ensure_fixtures() {
  local name size
  mkdir -p "$ROOT/priv"
  while read -r name size; do
    [ -f "$ROOT/priv/$name" ] || head -c "$size" /dev/urandom > "$ROOT/priv/$name"
  done << 'EOF'
file_1kb.bin 1K
file_100kb.bin 100K
file_5mb.bin 5M
body_1kb.bin 1K
body_10kb.bin 10K
EOF
}

start_results() {
  RESULTS_DIR="$ROOT/results/$(date +%Y%m%d-%H%M%S)-$1"
  CSV="$RESULTS_DIR/$1.csv"
  mkdir -p "$RESULTS_DIR/raw" "$RESULTS_DIR/logs"
}

record() {
  local IFS=,
  echo "$server,$protocol,$case_name,$*" >> "$CSV"
}

write_run_info() {
  local line label="load"
  {
    echo "date        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'machine     %s, Linux %s, virtualization %s\n' \
      "$(lscpu | awk -F': +' '/^Model name/ { print $2 }')" \
      "$(uname -r)" \
      "$(systemd-detect-virt || true)"
    printf 'toolchain   gleam %s, OTP %s, elixir %s\n' \
      "$(gleam --version | awk '{ print $2 }')" \
      "$(erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().')" \
      "$(elixir --version | awk '/^Elixir/ { print $2 }')"
    echo "cpu         server on $SERVER_CPUS, load generator on $LOAD_CPUS"
    for line in "$@"; do
      printf '%-12s%s\n' "$label" "$line"
      label=""
    done
  } | tee "$RESULTS_DIR/run.txt"
  echo
}

render_report() {
  echo "Results: $CSV"
  command -v deno > /dev/null || return 0
  echo
  "$ROOT/report.js" "$CSV" | tee "$RESULTS_DIR/report.md"
}

SERVER_PID=""

port_open() {
  (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null
}

server_ports() {
  local port
  for port in "$@"; do
    if [ "$port" != "-" ]; then echo "$port"; fi
  done | sort -u
}

wait_for_port() {
  local port="$1" deadline=$((SECONDS + STARTUP_TIMEOUT))
  until port_open "$port"; do
    kill -0 "$SERVER_PID" 2> /dev/null || return 1
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.5
  done
}

start_server() {
  local server="$1" h1_port="$2" h2_port="$3" ports port
  local log="$RESULTS_DIR/logs/$server.log"
  ports="$(server_ports "$h1_port" "$h2_port")"

  for port in $ports; do
    if port_open "$port"; then
      echo "  port $port is already in use" >&2
      return 1
    fi
  done

  (cd "$ROOT/$server" && exec setsid "${PIN_SERVER[@]}" ./run.sh > "$log" 2>&1 < /dev/null) &
  SERVER_PID=$!

  for port in $ports; do
    if ! wait_for_port "$port"; then
      echo "  port $port never opened, see logs/$server.log" >&2
      stop_server
      return 1
    fi
  done
}

stop_server() {
  local deadline=$((SECONDS + 10))
  [ -n "$SERVER_PID" ] || return 0
  kill -TERM -- "-$SERVER_PID" 2> /dev/null || true
  while kill -0 -- "-$SERVER_PID" 2> /dev/null && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.2
  done
  kill -KILL -- "-$SERVER_PID" 2> /dev/null || true
  wait "$SERVER_PID" 2> /dev/null || true
  SERVER_PID=""
}

is_skipped() {
  local case_name="$1" skips="$2" pattern patterns
  IFS=',' read -ra patterns <<< "$skips"
  for pattern in "${patterns[@]}"; do
    [[ "$case_name" == $pattern ]] && return 0
  done
  return 1
}

run_matrix() {
  local measure="$1" server_entry case_entry
  for server_entry in "${SERVERS[@]}"; do
    IFS='|' read -r server h1_port h2_port skips <<< "$server_entry"
    selected "$server" "$ONLY_SERVERS" || continue

    echo "=== $server"
    start_server "$server" "$h1_port" "$h2_port" || continue

    for protocol in "${PROTOCOLS[@]}"; do
      selected "$protocol" "$ONLY_PROTOCOLS" || continue
      if [ "$protocol" = h1 ]; then port="$h1_port"; else port="$h2_port"; fi
      [ "$port" != "-" ] || continue

      for case_entry in "${CASES[@]}"; do
        IFS='|' read -r case_name path body headers rates <<< "$case_entry"
        selected "$case_name" "$ONLY_CASES" || continue
        if ! kill -0 "$SERVER_PID" 2> /dev/null; then
          echo "  $server exited, see logs/$server.log" >&2
          break 2
        fi
        if is_skipped "$case_name" "$skips"; then
          printf '  %s %-18s skipped\n' "$protocol" "$case_name"
          continue
        fi
        "$measure"
      done
    done

    stop_server
    echo
  done
}

# Throughput

throughput_start() {
  echo "server,protocol,case,repeat,requests_per_sec,status" > "$CSV"
  write_run_info \
    "$(h2load --version | head -1), $THREADS threads, $CONNECTIONS connections" \
    "h2 with $H2_STREAMS streams per connection" \
    "${DURATION}s per run with the ${WARMUP}s warmup; $REPEATS runs per case"
}

parse_h2load() {
  awk '
    /^finished in/   { rate = $4; finished = 1 }
    /^requests:/     { completed = $6; failed = $10 }
    /^status codes:/ { non_2xx = $5 + $7 + $9 }
    END {
      if (!finished) exit 1
      printf "%s,%d,%d,%d\n", rate, completed, failed, non_2xx
    }
  ' "$1"
}

throughput_measure() {
  local url="http://127.0.0.1:$port$path" in_flight="$CONNECTIONS"
  local repeat raw row rate completed failed non_2xx status
  local args=(-c "$CONNECTIONS" -t "$THREADS" -D "$DURATION" --warm-up-time "$WARMUP")

  if [ "$protocol" = h2 ]; then
    args+=(-p h2c -m "$H2_STREAMS")
    in_flight=$((CONNECTIONS * H2_STREAMS))
  else
    args+=(--h1)
  fi
  if [ "$headers" = yes ]; then args+=("${HEADERS[@]}"); fi
  if [ "$body" != "-" ]; then args+=(-d "$ROOT/priv/$body"); fi

  printf '  %s %-18s' "$protocol" "$case_name"
  for ((repeat = 1; repeat <= REPEATS; repeat++)); do
    raw="$RESULTS_DIR/raw/${server}__${protocol}__${case_name}__${repeat}.txt"
    if ! "${PIN_LOAD[@]}" h2load "${args[@]}" "$url" > "$raw" 2>&1 \
      || ! row="$(parse_h2load "$raw")"; then
      printf ' %10s' failed
      continue
    fi
    IFS=, read -r rate completed failed non_2xx <<< "$row"

    if [ "$failed" -gt 0 ] || [ "$non_2xx" -gt 0 ]; then
      status=errors
    elif [ "$completed" -le "$in_flight" ]; then
      status=stalled
    else
      status=ok
    fi

    record "$repeat" "$rate" "$status"
    if [ "$status" = ok ]; then printf ' %10.0f' "$rate"; else printf ' %10s' "$status"; fi
  done
  echo
}

# Latency

latency_start() {
  echo "server,protocol,case,rate,achieved_rate,p50_us,p99_us,p999_us,status" > "$CSV"
  write_run_info \
    "$(zrk --version), $THREADS threads, $CONNECTIONS connections" \
    "h2 with $H2_STREAMS streams per connection" \
    "${DURATION}s per rate with the ${WARMUP}s warmup"
}

parse_zrk() {
  jq -r --argjson held "$RATE_HELD" '
    ((.errors | add) - .errors.timeout) as $failures
    | [
        .achieved_rate, .latency_us.p50, .latency_us.p99, .latency_us.p99_9,
        if $failures > 0 then "errors"
        elif .rate_ratio < $held then "overloaded"
        else "ok" end
      ]
    | map(tostring)
    | join(",")
  ' "$1"
}

latency_measure() {
  local url="http://127.0.0.1:$port$path" lowest_rate="${rates%% *}"
  local rate raw row achieved p50 p99 status
  local args=(-c "$CONNECTIONS" -t "$THREADS" --plain)

  if [ "$protocol" = h2 ]; then args+=(--http2 -s "$H2_STREAMS"); fi
  if [ "$headers" = yes ]; then args+=("${HEADERS[@]}"); fi
  if [ "$body" != "-" ]; then args+=(-m POST -b "@$ROOT/priv/$body"); fi

  echo "  $protocol $case_name"
  "${PIN_LOAD[@]}" zrk "${args[@]}" -d "${WARMUP}s" -R "$lowest_rate" "$url" > /dev/null 2>&1 || true

  for rate in $rates; do
    raw="$RESULTS_DIR/raw/${server}__${protocol}__${case_name}__${rate}"
    if ! "${PIN_LOAD[@]}" zrk "${args[@]}" -d "${DURATION}s" -R "$rate" \
      --format json -o "$raw.json" "$url" > "$raw.txt" 2>&1 \
      || ! row="$(parse_zrk "$raw.json")"; then
      printf '    %7s req/s  failed, see raw/%s.txt\n' "$rate" "${raw##*/}"
      continue
    fi

    record "$rate" "$row"
    IFS=, read -r achieved p50 p99 _p999 status <<< "$row"
    printf '    %7s req/s  achieved %7.0f  p50 %7sus  p99 %8sus  %s\n' \
      "$rate" "$achieved" "$p50" "$p99" "$status"
  done
}

main() {
  local benchmark="${1:-}"
  case "$benchmark" in
    throughput) require h2load "install nghttp2" ;;
    latency)
      require zrk "brew install zoxy-io/tap/zrk"
      require jq "install jq"
      ;;
    *) die "usage: ./bench.sh throughput|latency [--servers a,b] [--cases a,b] [--protocols h1,h2]" ;;
  esac
  shift

  parse_args "$@"
  pin_cpus
  ensure_fixtures
  start_results "$benchmark"
  trap stop_server EXIT
  trap 'exit 130' INT TERM

  "${benchmark}_start"
  run_matrix "${benchmark}_measure"
  render_report
}

main "$@"
