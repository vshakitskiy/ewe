#!/usr/bin/env bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CORES="$(nproc)"
if [ "$CORES" -ge 4 ]; then
  SERVER_CPUS="0-$((CORES / 2 - 1))"
  LOAD_CPUS="$((CORES / 2))-$((CORES - 1))"
  PIN_SERVER=(taskset -c "$SERVER_CPUS")
  PIN_LOAD=(taskset -c "$LOAD_CPUS")
else
  SERVER_CPUS="unpinned"
  LOAD_CPUS="unpinned"
  PIN_SERVER=()
  PIN_LOAD=()
fi

fixture() {
  local name="$1" size="$2"
  [ -f "$ROOT/priv/$name" ] || head -c "$size" /dev/urandom > "$ROOT/priv/$name"
}

ensure_fixtures() {
  mkdir -p "$ROOT/priv"
  fixture file_1kb.bin 1K
  fixture file_100kb.bin 100K
  fixture file_5mb.bin 5M
  fixture body_1kb.bin 1K
  fixture body_10kb.bin 10K
}

body_file() {
  case "$1" in
    -) echo "" ;;
    *) echo "$ROOT/priv/body_$1.bin" ;;
  esac
}

new_results_dir() {
  RESULTS_DIR="$ROOT/results/$(date +%Y%m%d-%H%M%S)-$1"
  mkdir -p "$RESULTS_DIR"
}

render_report() {
  local csv="$1"
  echo "Results: $csv"
  command -v deno > /dev/null || return 0
  echo
  "$ROOT/report.js" "$csv" | tee "$RESULTS_DIR/report.txt"
  echo "Report: $RESULTS_DIR/report.txt"
}

port_pid() {
  ss -tlnp 2>/dev/null | awk -v p=":$1\$" '$4 ~ p' | grep -oP 'pid=\K[0-9]+' | head -1
}

pgid_of() {
  ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '
}

free_port() {
  local port="$1" pid attempts=5

  [ "$port" = "-" ] && return 0
  while pid="$(port_pid "$port")" && [ -n "$pid" ]; do
    if [ "$attempts" -eq 0 ]; then
      echo "  port $port still held by pid $pid, giving up" >&2
      return 1
    fi
    echo "  port $port held by pid $pid, killing" >&2
    kill -9 "$pid" 2>/dev/null
    attempts=$((attempts - 1))
    sleep 1
  done
}

port_answered_by_group() {
  local port="$1" pgid="$2" pid
  pid="$(port_pid "$port")"
  [ -z "$pid" ] && return 0
  [ "$(pgid_of "$pid")" = "$pgid" ]
}

startup_port() {
  if [ "$1" != "-" ]; then echo "$1"; else echo "$2"; fi
}

wait_for_port() {
  local port="$1" attempts=60
  while [ "$attempts" -gt 0 ]; do
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && { exec 3<&- 3>&-; return 0; }
    sleep 0.5
    attempts=$((attempts - 1))
  done
  return 1
}

CURRENT_PGID=""

start_server() {
  local dir="$1" cmd="$2" port="$3" log="$4"

  free_port "$port" || return 1

  ( cd "$ROOT/$dir" && exec setsid "${PIN_SERVER[@]}" $cmd > "$log" 2>&1 < /dev/null ) &
  CURRENT_PGID=$!

  if ! wait_for_port "$port"; then
    echo "  failed to start, see $log" >&2
    stop_server
    return 1
  fi

  if ! port_answered_by_group "$port" "$CURRENT_PGID"; then
    echo "  port $port is answered by another process, see $log" >&2
    stop_server
    return 1
  fi
}

stop_server() {
  [ -z "$CURRENT_PGID" ] && return 0
  kill -TERM -- -"$CURRENT_PGID" 2>/dev/null
  sleep 1
  kill -KILL -- -"$CURRENT_PGID" 2>/dev/null
  wait "$CURRENT_PGID" 2>/dev/null
  CURRENT_PGID=""
}

trap stop_server EXIT INT TERM HUP PIPE

selected() {
  local name="$1" allowed="$2"
  [ -z "$allowed" ] && return 0
  case ",$allowed," in
    *",$name,"*) return 0 ;;
    *) return 1 ;;
  esac
}
