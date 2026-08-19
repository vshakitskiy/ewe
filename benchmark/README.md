Compares ewe against other BEAM web servers on the same set of endpoints over
both HTTP/1.1 and h2c.

Every server implements the same routes so a row of the report is the same work
done by different web servers. Where a server has no native API for a case its 
route is absent and the case is skipped.

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

| name |
| ---  |
| `ewe@5` |
| `ewe@4` |
| `mist` |
| `elli` |
| `bandit` |
| `httpd` | |
| `roadrunner` |
| `chatterbox` |

Each is started for its measurements and stopped afterwards. `run.sh` in
each directory is the start command, the gleam ones use `gleam run`.

There are fifteen cases:
- `GET /hello`: returns `Hello, Joe!` body
- `GET /hello` with 7 headers: returns `Hello, Joe!` body
- `POST /echo` with 1KiB body: echoes the body
- `POST /echo` with 1KiB body and 7 headers: echoes the body
- `POST /echo` with 10KiB body: echoes the body
- `POST /echo/chunked` with 10KiB chunked body: echoes the body
- `GET /file/tiny`: serves `priv/file_1kb.bin`
- `GET /file/small`: serves `priv/file_100kb.bin`
- `GET /file/big`: servers `priv/file_5mb.bin`
- `GET /stream`: streams two chunks: `hello, ` and `Joe!`
- `GET /stream/small`: streams 100 x 64B chunks, 6400B in total
- `GET /stream/big`: streams 64 x 16KiB chunks, 1MiB in total
- `GET /sse`: streams 32 events, 2688B in total
- `GET /sse/small`: streams 100 events, 8400B total
- `GET /sse/big`: streams 64 x 16KiB events, 1MiB total

SSE events are `event: tick` with a various data line framed by each server's 
own SSE encoder on every request. The header set is seven fields including 
three cookies.

There is not native SSE API in `bandit`, `chatterbox`, `elli`, `httpd` so 
comparing with streaming endpoints is enough. And `elli`, `httpd` do not have 
incremental request body read so we can't measure chunked reading.

## Scripts

**`throughput.sh`**: requests a second, per server, per case and per protocol. 
Runs both protocols with `h2load`. Accepts `--servers`, `--cases` and `--profiles`.

**`latency.sh`**: response latency under fixed offered HTTP/1 only load. HTTP/1 
only because wrk2 has no HTTP/2 support. Accepts `--servers` and `--cases`.

**`report.js`**: renders either CSV as tables.
**`config.sh`**: settings on what to measure exactly.
**`lib.sh`**: settings on how to measure things.
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
                                            # messages_per_sec,mib_per_sec,succeeded,failed,
                                            # non_2xx,status
  run.txt                                   # date, load settings, cpu pinning, versions
  report.txt                                # rendered tables
  <server>.log                              # server stdout and stderr
  <server>__<profile>__<case>__<repeat>.txt # raw h2load output

results/<stamp>-latency/
  latency.csv                               # server,case,target_rate,achieved_rate,p50_us,
                                            # p75_us,p90_us,p99_us,p999_us,p9999_us,
                                            # p50_raw_us,p99_raw_us,connect_errors,read_errors,
                                            # write_errors,timeouts,non_2xx,status
  run.txt
  report.txt
  <server>.log
  <server>__<case>__<rate>.txt              # raw wrk2 output
```