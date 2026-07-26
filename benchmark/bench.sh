#!/usr/bin/env bash
#
# Drives wrk2 against every server in benchmark/. For each endpoint, it first 
# probes for the server's saturation throughput, then re-runs at fixed target 
# rates that are 50/75/90/95% of that saturation point, recording both corrected 
# and uncorrected latency percentiles at each rate.
#
# Requires benchmark/.wrk2/wrk2, so run ./wrk2-setup.sh once first.
#
# Usage:
#   ./bench.sh [--servers "ewe@5,mist"] [--endpoints "sse"] [--pcts "50 75 90 95"] 
#              [--conns 50] [--duration 20s] [--warmup 5s] [--threads 4] 
#              [--probe-rate 500000] [--probe-duration 5s]
#
#   --servers         comma separated subset of server names (default: all)
#   --endpoints       comma separated subset of endpoint names (default: all)
#   --pcts            space separated percentages of saturation to test (default: "50 75 90 95")
#   --conns           connections held open per run (default: 50)
#   --duration        wrk2 measured run duration (default: 20s)
#   --warmup          untimed warmup before measuring each server (default: 5s)
#   --threads         wrk2 threads (default: 4)
#   --probe-rate      -R used for the saturation probe (default: 500000)
#   --probe-duration  duration of the saturation probe (default: 5s)

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# name|port|dir|start command
SERVERS=(
  "ewe@5|3006|ewe@5|gleam run"
  "ewe@4|3001|ewe@4|gleam run"
  "mist|3002|mist|gleam run"
  "elli|3003|elli|./run.sh"
  "bandit|3004|bandit|./run.sh"
  "httpd|3005|httpd|./run.sh"
  "roadrunner|3007|roadrunner|./run.sh"
)

# name|path|wrk script relative to benchmark/wrk
ENDPOINTS=(
  "hello|/hello|"
  "echo|/echo|post_echo.lua"
  "echo_chunked|/echo/chunked|post_echo_chunked.lua"
  "stream|/stream|"
  "sse|/sse|"
  "file_small|/file/small|"
)

SSE_EVENTS=32

# server|endpoint|reason combos to skip before probing. Two distinct reasons:
# - not_implemented: the server doesn't implement the feature the endpoint is 
#   meant to exercise, so measuring it tells us nothing.
#
# - unstable: the endpoint collapses under wrk2's rate-limited load for a 
#   confirmed reproducible reason that isn't a benchmark setup mistake.
SKIP=(
  "elli|echo_chunked|not_implemented"
  "httpd|echo_chunked|not_implemented"
  "elli|stream|unstable"
  "elli|sse|unstable"
  "mist|stream|unstable"
  "ewe@4|stream|unstable"
  "ewe@4|file_small|unstable"
)

skip_endpoint() {
  local name="$1" ename="$2" entry s_name s_ename
  for entry in "${SKIP[@]}"; do
    IFS='|' read -r s_name s_ename SKIP_REASON <<< "$entry"
    if [ "$s_name" = "$name" ] && [ "$s_ename" = "$ename" ]; then
      return 0
    fi
  done
  return 1
}

server_selected() {
  local name="$1"
  [ -z "${ONLY_SERVERS:-}" ] && return 0
  case ",$ONLY_SERVERS," in
    *",$name,"*) return 0 ;;
    *) return 1 ;;
  esac
}

endpoint_selected() {
  local name="$1"
  [ -z "${ONLY_ENDPOINTS:-}" ] && return 0
  case ",$ONLY_ENDPOINTS," in
    *",$name,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Kills whatever is already listening on $1, e.g. a server orphaned by a 
# previous run that got interrupted before its own cleanup ran.
free_port() {
  local port="$1" pid
  pid=$(ss -tlnp 2>/dev/null | awk -v p=":$port\$" '$4 ~ p' | grep -oP 'pid=\K[0-9]+' | head -1)
  if [ -n "$pid" ]; then
    echo "  port $port already in use by pid $pid, killing" >&2
    kill -9 "$pid" 2>/dev/null
    sleep 1
  fi
}

# Cleans up whichever server is currently running if the script exits early.
CURRENT_PGID=""
cleanup() {
  if [ -n "$CURRENT_PGID" ]; then
    kill -TERM -- -"$CURRENT_PGID" 2>/dev/null
    sleep 1
    kill -KILL -- -"$CURRENT_PGID" 2>/dev/null
  fi
}
trap cleanup EXIT INT TERM

wait_ready() {
  local port="$1" tries=60
  while [ "$tries" -gt 0 ]; do
    if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/hello"; then
      return 0
    fi
    sleep 0.5
    tries=$((tries - 1))
  done
  return 1
}

# Starts $dir/$cmd in its own process group, logs to $log, and waits for $port 
# to answer. Must NOT be called via $(...). Sets CURRENT_PGID on success clears 
# it on failure. Returns 0/1.
start_server() {
  local dir="$1" cmd="$2" port="$3" log="$4"

  free_port "$port"

  ( cd "$ROOT/$dir" && exec setsid $cmd > "$log" 2>&1 < /dev/null ) &
  CURRENT_PGID=$!

  if ! wait_ready "$port"; then
    echo "  failed to start, see $log" >&2
    kill -KILL -- -"$CURRENT_PGID" 2>/dev/null
    wait "$CURRENT_PGID" 2>/dev/null
    CURRENT_PGID=""
    return 1
  fi

  return 0
}

stop_server() {
  local pgid="$1"
  kill -TERM -- -"$pgid" 2>/dev/null
  sleep 1
  kill -KILL -- -"$pgid" 2>/dev/null
  wait "$pgid" 2>/dev/null
  CURRENT_PGID=""
  sleep 1
}

WRK2_BIN="${WRK2_BIN:-$ROOT/.wrk2/wrk2}"
if ! [ -x "$WRK2_BIN" ]; then
  WRK2_BIN="$(command -v wrk2 || true)"
fi
if [ -z "$WRK2_BIN" ] || ! [ -x "$WRK2_BIN" ]; then
  echo "wrk2 not found. Run ./wrk2-setup.sh first (or set WRK2_BIN)." >&2
  exit 1
fi

PCTS="50 75 90 95"
CONNS=50
DURATION="20s"
WARMUP_DURATION="5s"
THREADS=4
PROBE_RATE=500000
PROBE_DURATION="5s"
ONLY_SERVERS=""
ONLY_ENDPOINTS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --servers) ONLY_SERVERS="$2"; shift 2 ;;
    --endpoints) ONLY_ENDPOINTS="$2"; shift 2 ;;
    --pcts) PCTS="$2"; shift 2 ;;
    --conns) CONNS="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --warmup) WARMUP_DURATION="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --probe-rate) PROBE_RATE="$2"; shift 2 ;;
    --probe-duration) PROBE_DURATION="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_DIR="$ROOT/results/$TIMESTAMP-wrk2"
mkdir -p "$RESULTS_DIR"
CSV="$RESULTS_DIR/results.csv"
echo "server,endpoint,pct_of_saturation,target_rate,saturation_rate,connections,threads,duration,requests_per_sec,corrected_p50,corrected_p90,corrected_p99,corrected_p999,corrected_p9999,uncorrected_p50,uncorrected_p90,uncorrected_p99,uncorrected_p999,uncorrected_p9999,errors" > "$CSV"

mkdir -p "$ROOT/priv"
[ -f "$ROOT/priv/file_100kb.bin" ] || head -c 100K /dev/urandom > "$ROOT/priv/file_100kb.bin"

wrk2_url() {
  local port="$1" path="$2"
  echo "http://127.0.0.1:$port$path"
}

wrk2_run() {
  # Runs wrk2 and prints raw output; $1=port $2=path $3=script $4=rate $5=conn 
  # $6=duration
  local port="$1" path="$2" script="$3" rate="$4" conn="$5" duration="$6"
  if [ -n "$script" ]; then
    "$WRK2_BIN" -t"$THREADS" -c"$conn" -d"$duration" -R"$rate" -U \
      -s "$ROOT/wrk/$script" "$(wrk2_url "$port" "$path")"
  else
    "$WRK2_BIN" -t"$THREADS" -c"$conn" -d"$duration" -R"$rate" -U \
      "$(wrk2_url "$port" "$path")"
  fi
}

# Probes achievable throughput by requesting a rate far above what the server 
# can sustain and reading back what it actually achieved.
probe_saturation() {
  local port="$1" path="$2" script="$3"
  local out rps
  out=$(wrk2_run "$port" "$path" "$script" "$PROBE_RATE" "$CONNS" "$PROBE_DURATION")
  rps=$(printf '%s\n' "$out" | awk '/Requests\/sec:/ { print $2 }')
  # Integer floor; falls back to 1 if parsing failed so a /0 can't happen.
  printf '%.0f\n' "${rps:-1}"
}

# Parses wrk2 -U output into pipe-separated fields.
parse_wrk2() {
  awk '
    /Latency Distribution \(HdrHistogram - Recorded Latency\)/ { section="c"; next }
    /Latency Distribution \(HdrHistogram - Uncorrected Latency/ { section="u"; next }
    section=="c" && / 50\.000%/  { c50=$2 }
    section=="c" && / 90\.000%/  { c90=$2 }
    section=="c" && / 99\.000%/  { c99=$2 }
    section=="c" && / 99\.900%/  { c999=$2 }
    section=="c" && / 99\.990%/  { c9999=$2 }
    section=="u" && / 50\.000%/  { u50=$2 }
    section=="u" && / 90\.000%/  { u90=$2 }
    section=="u" && / 99\.000%/  { u99=$2 }
    section=="u" && / 99\.900%/  { u999=$2 }
    section=="u" && / 99\.990%/  { u9999=$2 }
    /Requests\/sec:/ { rps=$2 }
    /Socket errors:/ { gsub(",", "", $0); err=$0 }
    END {
      printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", \
        rps, c50, c90, c99, c999, c9999, u50, u90, u99, u999, u9999, err
    }
  '
}

# Converts a wrk-style duration string to microseconds, for computing the 
# corrected/uncorrected ratio.
to_us() {
  awk -v v="$1" '
    BEGIN {
      if (v ~ /us$/) { sub(/us$/, "", v); printf "%.4f", v }
      else if (v ~ /ms$/) { sub(/ms$/, "", v); printf "%.4f", v * 1000 }
      else if (v ~ /s$/) { sub(/s$/, "", v); printf "%.4f", v * 1000000 }
      else { printf "%.4f", v }
    }
  '
}

# corrected/uncorrected, as like "12.3x".
ratio_of() {
  local c u
  c=$(to_us "$1")
  u=$(to_us "$2")
  awk -v c="$c" -v u="$u" 'BEGIN { if (u + 0 == 0) print "n/a"; else printf "%.1fx", c / u }'
}

table_header() {
  printf "    %-5s %11s %11s  %-24s  %-24s  %s\n" \
    "load" "target/s" "actual/s" "corrected p50/p99/p99.9" "uncorrected p50/p99/p99.9" "CO ratio(p99)"
}

run_rate() {
  local server="$1" port="$2" endpoint="$3" path="$4" script="$5" pct="$6" sat="$7"
  local rate=$(( sat * pct / 100 ))
  [ "$rate" -lt 1 ] && rate=1

  local raw="$RESULTS_DIR/${server}__${endpoint}__p${pct}.txt"
  local out
  out=$(wrk2_run "$port" "$path" "$script" "$rate" "$CONNS" "$DURATION" | tee "$raw")

  local parsed rps c50 c90 c99 c999 c9999 u50 u90 u99 u999 u9999 err
  parsed=$(printf '%s\n' "$out" | parse_wrk2)
  IFS='|' read -r rps c50 c90 c99 c999 c9999 u50 u90 u99 u999 u9999 err <<< "$parsed"

  local err_csv=""
  [ -n "$err" ] && err_csv="\"$err\""
  echo "$server,$endpoint,$pct,$rate,$sat,$CONNS,$THREADS,$DURATION,$rps,$c50,$c90,$c99,$c999,$c9999,$u50,$u90,$u99,$u999,$u9999,$err_csv" >> "$CSV"

  local ratio corrected uncorrected
  ratio=$(ratio_of "$c99" "$u99")
  corrected="$c50/$c99/$c999"
  uncorrected="$u50/$u99/$u999"
  printf "    %3d%%  %11s %11s  %-24s  %-24s  %s\n" \
    "$pct" "$rate" "$rps" "$corrected" "$uncorrected" "$ratio"
  [ -n "$err" ] && printf "          %s\n" "$err"
}

for entry in "${SERVERS[@]}"; do
  IFS='|' read -r name port dir cmd <<< "$entry"
  server_selected "$name" || continue

  echo "=== $name (port $port) ==="
  server_log="$RESULTS_DIR/${name}.server.log"

  start_server "$dir" "$cmd" "$port" "$server_log" || continue
  pgid="$CURRENT_PGID"

  wrk -t2 -c20 -d"$WARMUP_DURATION" "http://127.0.0.1:$port/hello" > /dev/null 2>&1

  for endpoint_entry in "${ENDPOINTS[@]}"; do
    IFS='|' read -r ename epath escript <<< "$endpoint_entry"
    endpoint_selected "$ename" || continue

    if skip_endpoint "$name" "$ename"; then
      echo
      case "$SKIP_REASON" in
        not_implemented)
          echo "  $ename  (skipped: $name doesn't implement this feature)" ;;
        unstable)
          echo "  $ename  (skipped: cannot measure properly)" ;;
      esac
      continue
    fi

    saturation=$(probe_saturation "$port" "$epath" "$escript")
    echo
    if [ "$ename" = "sse" ]; then
      echo "  $ename  (saturation ~$saturation streams/s = ~$(( saturation * SSE_EVENTS )) events/s)"
    else
      echo "  $ename  (saturation ~$saturation req/s)"
    fi
    table_header

    for pct in $PCTS; do
      run_rate "$name" "$port" "$ename" "$epath" "$escript" "$pct" "$saturation"
    done
  done

  stop_server "$pgid"
done

echo
echo "Results: $CSV"
