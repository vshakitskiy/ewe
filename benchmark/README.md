Compares ewe against other BEAM web servers on the same set of endpoints over
both HTTP/1.1 and cleartext HTTP/2.

## Requirements

This benchmark script works on Linux on my arch VM but probably won't work on
macOS. You also need to have these runtimes and tools installed:

- Gleam, Erlang, rebar3 and Elixir to build and run the servers.
- `h2load` from nghttp2 for throughput.
- `zrk` for latency. See [Opinion on zrk](#opinion-on-zrk).
- `jq` to read zrk's reports.
- `deno` to run `report.js`.

## Quick start

```sh
./bench.sh throughput
./bench.sh latency

# You can also use flags:
./bench.sh throughput --servers ewe@9,roadrunner --cases hello,sse_big
./bench.sh latency --cases hello --protocols h2
```

Each execution writes a timestamped directory under `results/` and prints a
report at the end. To print the reports again:

```sh
./report.js results/<stamp>-throughput/throughput.csv results/<stamp>-latency/latency.csv
```

## Suites

`throughput` measures the peak request rate with h2load. Every case runs
`REPEATS` times with `WARMUP` seconds of unmeasured load. The report is showing
the median values.

`latency` runs a ladder of fixed request rates with zrk and records the
latency percentiles avoiding coordinated omission. Every server gets the same
absolute rates. Each case starts with `WARMUP` seconds at the lowest rate.

With four or more CPUs the server is pinned to the first half of the physical
cores and the load generator to the rest of the cores. In a VM these are vCPUs
and the host decides which physical cores they run on. High rates (in my case
above about 200_000 req/s for h2load) are partly limited by the benchmarking
tools so small differences in the server runs are mostly noise.

If a run is not clean, there is a specific status shown:

| status | meaning |
| --- | --- |
| `errors` | failed requests, resets or non-2xx responses. In latency runs timeouts count as `overloaded` instead |
| `stalled` | none of the connections/streams completed a second request |
| `overloaded` | the server produced less than 98% of the offered rate |
| `-` | the server does not support the case, exited earlier in the run, the case was not selected or the load generator failed |

## Servers

Every server's `run.sh` builds and starts the server for production usage.

| server | h1 | h2 |
| --- | --- | --- |
| `ewe@9` | 3006 | 3006 |
| `ewe@8` | 3001 | 3001 |
| `mist` | 3002 | - |
| `elli` | 3003 | - |
| `bandit` | 3004 | 3004 |
| `httpd` | 3005 | - |
| `roadrunner` | 3007 | 3008 |
| `chatterbox` | - | 8082 |
| `cowboy` | 3009 | 3009 |
| `mochiweb` | 3010 | - |
| `yaws` | 3011 | - |

`bandit`, `chatterbox`, `elli`, `httpd` and `mochiweb` have no native SSE API
and `elli` and `httpd` cannot read a request body incrementally.

Almost all the servers run preferably with their default settings with the
exceptions:

- `cowboy`'s `max_keepalive` and `max_received_frame_rate` are lifted.
- `mochiweb`, `yaws`, `elli` and `httpd` have Nagle's algorithm disabled.
- `yaws` has its access and auth logs disabled.

`yaws` serves files through its read/write path, its Erlang sendfile path
crashes in version 2.3.1. `yaws` SSE events are sent within the chunked stream 
with `yaws_sse` formatting them.

## Cases

| case | request | response |
| --- | --- | --- |
| `hello` | `GET /hello` | `Hello, Joe!` |
| `hello_headers` | `GET /hello` with 7 extra headers | `Hello, Joe!` |
| `echo_1kb` | `POST /echo`, 1KiB body | the body |
| `echo_1kb_headers` | `POST /echo`, 1KiB body, 7 extra headers | the body |
| `echo_10kb` | `POST /echo`, 10KiB body | the body |
| `echo_chunked_10kb` | `POST /echo/chunked`, 10KiB body | the body, read incrementally |
| `file_tiny` | `GET /file/tiny` | `priv/file_1kb.bin` |
| `file_small` | `GET /file/small` | `priv/file_100kb.bin` |
| `file_big` | `GET /file/big` | `priv/file_5mb.bin` |
| `stream` | `GET /stream` | 2 chunks `hello, ` and `Joe!` |
| `stream_small` | `GET /stream/small` | 100 x 64B chunks |
| `stream_big` | `GET /stream/big` | 64 x 16KiB chunks |
| `sse` | `GET /sse` | 32 events |
| `sse_small` | `GET /sse/small` | 100 events |
| `sse_big` | `GET /sse/big` | 64 x 16KiB events |

## Settings

Environment variables with their defaults that you can use:

```sh
CONNECTIONS=50      # connections per run
THREADS=4           # load generator threads
H2_STREAMS=10       # concurrent streams per h2 connection
DURATION=10         # seconds measured per run
WARMUP=3            # seconds of unmeasured load before measuring
REPEATS=3           # throughput runs per case
STARTUP_TIMEOUT=120 # seconds a server gets to build and open its ports
```

## Files

```
bench.sh   settings, servers, cases and both benchmarks
report.js  prints the CSVs in tables

results/<stamp>-throughput/
  throughput.csv  server,protocol,case,repeat,requests_per_sec,status
  run.txt         date, machine, toolchain, CPU pinning and load
  report.md       the printed report
  raw/            h2load output in <server>__<protocol>__<case>__<repeat>.txt
  logs/           build and server output in <server>.log

results/<stamp>-latency/
  latency.csv     server,protocol,case,rate,achieved_rate,p50_us,p99_us,p999_us,status
  run.txt         date, machine, toolchain, CPU pinning and load
  report.md       the printed report
  raw/            zrk JSON reports and output in <server>__<protocol>__<case>__<rate>.{json,txt}
  logs/           build and server output in <server>.log
```

## Opinion on zrk

I know zrk is pretty young and, most importantly, a wildly vibe coded tool. I was
really sceptical about even trying it as there are other tools available on the
internet. However, I still decided to use it for latency measurements. At least
for now.

Previously I used wrk2 to measure latency without coordinated omission. What I
noticed was how much the timer affects the corrected values because wrk2
schedules sends on its millisecond timer and rounds every wait up. This is
especially noticeable when corrected numbers should equal raw numbers at low
loads but this is not the case with wrk2. At 10k req/s against a server that
produces the response in ~70 µs, wrk2's corrected p50 was 880 µs while its raw
p50 was 68 µs. zrk's corrected p50 was 70 µs. wrk2 also has no HTTP/2 support
and tools like h2load do have the coordinated omission problem. I looked at other
HTTP/2 tools but they were not performant enough for the request rates I need.

I am not entirely confident in the legitimacy of the numbers zrk produces but I
checked its output. I froze the server with `SIGSTOP` for 500 ms during a
20k req/s run and zrk's p99 and p99.9 (about 412 ms and 494 ms) matched that
while h2load reported a p99 of 2.3 ms. I also compared zrk with other tools and
confirmed that it sustains 150k req/s on both HTTP/1.1 and HTTP/2. After these
checks I concluded that it is usable.

Also when looking at the HTTP/2 latency results keep in mind that zrk advertises
`HEADER_TABLE_SIZE=0`, which means servers cannot use HPACK's dynamic table for
responses.