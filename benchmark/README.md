Compares ewe against other BEAM web servers on the same set of endpoints over
both HTTP/1.1 and h2c.

Every server implements the same routes so a row of the report is the same work
done by different web servers. Where a server has no native API for a case its 
route is absent and the case is skipped rather than hand rolled.

## Requirements

To run everything you should have Gleam, Elixir and Erlang installed. For 
benchmarks the tools are `wrk2` (can be built by `./wrk2-setup.sh`) and 
`h2load` from `nghttp2`. For printing the reports I have a `report.js` that I run
with Deno.

## Quick start

```sh
./throughput.sh # runs full matrix and its like ~80 min
./latency.sh    # runs full ladder for ~50 min

./throughput.sh --servers ewe@5,roadrunner --cases hello,sse_big
./latency.sh --cases hello
```

Both write a timestamped directory under `results/` and print a report at the
end. To rerender one later:

```sh
./report.js results/<stamp>-throughput/throughput.csv
./report.js results/<stamp>-latency/latency.csv # you can also run both at once
```

## Servers

| name | dir | http/1 | h2c |
| --- | --- | --- | --- | --- |
| `ewe@5` | `ewe@5` | 3006 | 3006 |
| `ewe@4` | `ewe@4` | 3001 | — |
| `mist` | `mist` | 3002 | — |
| `elli` | `elli` | 3003 | — |
| `bandit` | `bandit` | 3004 | 3004 |
| `httpd` | `httpd` | 3005 | — |
| `roadrunner` | `roadrunner` | 3007 | 3008 |
| `chatterbox` | `chatterbox` | — | 8082 |

Each is started fresh for its measurements and stopped afterwards. `run.sh` in
each directory is the start command, the gleam ones use `gleam run`.

There are fifteen cases.
| case | request | response |
| --- | --- | --- | --- |
| `hello` | `GET /hello` | `Hello, Joe!`, 11 B |
| `hello_headers` | `GET /hello` + 7 headers | 11 B |
| `echo_1kb` | `POST /echo`, 1 KiB body | echoes body |
| `echo_1kb_headers` | `POST /echo`, 1 KiB + 7 headers | echoes body |
| `echo_10kb` | `POST /echo`, 10 KiB body | echoes body |
| `echo_chunked_10kb` | `POST /echo/chunked`, 10 KiB chunked | echoes body |
| `file_tiny` | `GET /file/tiny` | `priv/file_1kb.bin`, 1 KiB |
| `file_small` | `GET /file/small` | `priv/file_100kb.bin`, 100 KiB |
| `file_big` | `GET /file/big` | `priv/file_5mb.bin`, 5 MiB |
| `stream` | `GET /stream` | `hello, ` then `Joe!`, 11 B |
| `stream_small` | `GET /stream/small` | 100 × 64 B chunks, 6,400 B |
| `stream_big` | `GET /stream/big` | 64 × 16 KiB chunks, 1 MiB |
| `sse` | `GET /sse` | 32 events, 2,688 B |
| `sse_small` | `GET /sse/small` | 100 events, 8,400 B |
| `sse_big` | `GET /sse/big` | 64 events of 16 KiB, 1,049,856 B |

SSE events are `event: tick` with a 64-byte data line (and 16 KiB for `sse_big`),
framed by each server's own SSE encoder on every request. The header set is 
seven fields including three cookies.

There is not native SSE API in `bandit`, `chatterbox`, `elli`, `httpd`, so 
comparing with streaming endpoints is enough. And `elli`, `httpd` do not have 
incremental request body read, so we can't measure chunked reading.

## Scripts

**`throughput.sh`**: requests a second, per server, per case and per protocol. 
Drives both protocols with `h2load` so the h1 and h2 rows are the same tool
measuring the same work. Reports no coordinated omission correction which is
why there is separate latency script. Accepts `--servers`, `--cases` and `--profiles`.

**`latency.sh`**: response latency under fixed offered HTTP/1 only load. `wrk2` 
holds a target rate rather than a connection count so its percentiles include 
the time a request waited to be sent. HTTP/1 only because wrk2 has no HTTP/2 
support and an h2 column from a different tool would not be comparable. Accepts `--servers` and `--cases`.

**`report.js`**: small script that renders either CSV as tables. Detects the 
format from the header so it takes any mix of files. Throughput mode prints req/s and
messages/s then warnings for servers answering incorrectly, servers collapsed
against their peers and cells whose repeats disagreed by over 5%.

**`config.sh`**: settings on what to measure: servers, cases, profiles, latency rates,
unsupported combinations.

**`lib.sh`** — settings on how to measure things: fixture generation, port handling, server
start/stop, core pinning. 

**`wrk2-setup.sh`**: clones and builds wrk2 into `.wrk2/`.

The environment variables are:

```
CONNECTIONS=50   THREADS=4   DURATION=10   WARMUP=3   WARMUP_RATE=20000
REPEATS=3        H2_STREAMS=10             WRK2=<path to wrk2 binary>
```

Latency uses fixed rate ladders per case (`latency_rates()` in `config.sh`) so
every server is driven at the same absolute load to make servers really comparable.

If the machine has four or more cores the server gets the first half and the
load generator the second since the generator is heavy enough to fight the
server for CPU otherwise. The chosen ranges are printed at the top of each run.

The output of the scripts is something like this:

```
results/<stamp>-throughput/
  throughput.csv                            # server,profile,protocol,connections,streams,
                                            # case,repeat,requests_per_sec,messages,
                                            # messages_per_sec,mb_per_sec,succeeded,failed,non_2xx
  run.txt                                   # date, load settings, cpu pinning
  report.txt                                # rendered tables
  <server>.log                              # server stdout and stderr
  <server>__<profile>__<case>__<repeat>.txt # raw h2load output

results/<stamp>-latency/
  latency.csv                               # server,case,target_rate,achieved_rate,
                                            # p50,p90,p99,p999,p50_raw,p99_raw,errors
  run.txt
  report.txt
  <server>.log
  <server>__<case>__<rate>.txt              # raw wrk2 output
```