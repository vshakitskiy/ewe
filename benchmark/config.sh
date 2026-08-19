#!/usr/bin/env bash

# name|directory|start command|http/1 port|http/2 port
SERVERS=(
  "ewe@5|ewe@5|gleam run|3006|3006"
  "ewe@4|ewe@4|gleam run|3001|-"
  "mist|mist|gleam run|3002|-"
  "elli|elli|./run.sh|3003|-"
  "bandit|bandit|./run.sh|3004|3004"
  "httpd|httpd|./run.sh|3005|-"
  "roadrunner|roadrunner|./run.sh|3007|3008"
  "chatterbox|chatterbox|./run.sh|-|8082"
)

# name|path|body|headers|messages
CASES=(
  "hello|/hello|-|no|1"
  "hello_headers|/hello|-|yes|1"
  "echo_1kb|/echo|1kb|no|1"
  "echo_1kb_headers|/echo|1kb|yes|1"
  "echo_10kb|/echo|10kb|no|1"
  "echo_chunked_10kb|/echo/chunked|10kb|no|1"
  "file_tiny|/file/tiny|-|no|1"
  "file_small|/file/small|-|no|1"
  "file_big|/file/big|-|no|1"
  "stream|/stream|-|no|2"
  "stream_small|/stream/small|-|no|100"
  "stream_big|/stream/big|-|no|64"
  "sse|/sse|-|no|32"
  "sse_small|/sse/small|-|no|100"
  "sse_big|/sse/big|-|no|64"
)

unsupported() {
  case "$1:$2" in
    bandit:sse* | chatterbox:sse* | elli:sse* | httpd:sse*) return 0 ;;
    elli:echo_chunked_10kb | httpd:echo_chunked_10kb) return 0 ;;
    *) return 1 ;;
  esac
}

CONNECTIONS="${CONNECTIONS:-50}"
THREADS="${THREADS:-4}"
DURATION="${DURATION:-10}"
WARMUP="${WARMUP:-3}"
WARMUP_RATE="${WARMUP_RATE:-20000}"
REPEATS="${REPEATS:-3}"

# name|protocol|connections|streams
PROFILES=(
  "h1|h1|$CONNECTIONS|1"
  "h2|h2|$CONNECTIONS|${H2_STREAMS:-10}"
  "h2-serial|h2|$CONNECTIONS|1"
)

DEFAULT_PROFILES="h1,h2"

HEADER_ARGS=(
  -H "cookie: session=abc123def456"
  -H "cookie: theme=dark"
  -H "cookie: locale=en-US"
  -H "x-request-id: 9f86d081-b1bb-4c2e-8f21-9c7b1f2a0e3e"
  -H "x-client-version: 4.2.1"
  -H "accept-language: en-US,en;q=0.9"
  -H "x-forwarded-for: 203.0.113.42"
)

latency_rates() {
  case "$1" in
    hello | hello_headers | echo_1kb) echo "50000 100000 150000" ;;
    echo_1kb_headers) echo "40000 80000 120000" ;;
    echo_10kb) echo "20000 60000 100000" ;;
    echo_chunked_10kb) echo "40000 70000 100000" ;;
    file_tiny | stream) echo "20000 40000 60000" ;;
    file_small) echo "15000 30000 45000" ;;
    file_big) echo "500 1000 1500" ;;
    sse) echo "6000 10000 14000" ;;
    stream_small | stream_big | sse_small | sse_big) echo "3000 5000 7000" ;;
    *) echo "1000" ;;
  esac
}

server_package() {
  case "$1" in
    ewe@5 | httpd) echo "-" ;;
    ewe@4) echo "ewe" ;;
    *) echo "$1" ;;
  esac
}

wrk_script() {
  case "$1" in
    hello_headers) echo "get_headers.lua" ;;
    echo_1kb) echo "post_echo_1kb.lua" ;;
    echo_1kb_headers) echo "post_echo_1kb_headers.lua" ;;
    echo_10kb) echo "post_echo_10kb.lua" ;;
    echo_chunked_10kb) echo "post_echo_chunked_10kb.lua" ;;
    *) echo "" ;;
  esac
}
