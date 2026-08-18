# ewe@5 benchmarks

This page evaluates the performance of ewe@5 against seven other BEAM-based web 
servers. Benchmarks were conducted on August 17, 2026, across fifteen endpoints 
using both HTTP/1.1 and h2c (cleartext HTTP/2).

ewe@5 outperformed competitors in 11 of the 15 tested scenarios on HTTP/1. It 
demonstrated a 32% to 49% throughput improvement over ewe@4 across all shared 
test cases and a 23% to 83% advantage over mist. On HTTP/2, ewe@5 delivered 
roughly twice the throughput of bandit but trailed roadrunner on request heavy 
scenarios. The `file_big` endpoint on h2c represents its weakest comparative 
performance. See [Known Bottlenecks and Limitations](#known-bottlenecks-and-limitations) section.

All reported figures represent the median of five consecutive runs.

## Content
- [How to read these numbers](#how-to-read-these-numbers)
- [How it was run](#how-it-was-run)
- [Throughput: HTTP/1.1](#throughput-http-1.1)
- [Throughput: HTTP/2](#throughput-http-2)
- [Against ewe@4](#against-ewe-4)
- [Against mist](#against-mist)
- [Against elli and roadrunner](#against-elli-and-roadrunner)
- [Against bandit on HTTP/2](#against-bandit-on-http-2)
- [Latency](#latency)
- [Known bottlenecks and limitations](#known-bottlenecks-and-limitations)

<h2 id="how-to-read-these-numbers">How to read these numbers</h2>

**No network overhead.** The benchmark was run entirely on localhost. The load 
generator and server were pinned to six dedicated CPU cores each. Real world 
network stack and TCP overheads are not represented in these numbers.

**Numbers above 200,000 req/s are approximate.** At rates exceeding 200,000 req/s, 
h2load's own CPU consumption impacts the results as it competes with the server 
for system resources. Adjusting h2load's thread count on the `hello` case 
produced a 14% spread ranging from 228,000 to 261,000 req/s without any changes 
to the server configuration. Small performance gaps in this high range should 
therefore be treated as approximate. Comparisons below 200,000 req/s provide 
more stable and reliable data.

**Cases that has no native API for the implementation are skipped.** Some test 
cases were omitted for servers lacking native API support. `bandit`, `chatterbox`, 
`elli` and `httpd` have no SSE API and `elli` and `httpd` cannot read a request 
body incrementally so the cases are skipped for them.

**Every server runs on default settings.** All servers were tested using default 
configurations. The single exception is `TCP_NODELAY`. `elli` and `httpd` do 
not enable it themselves so during the benchmark we turn it on for them since 
every other server already has it on by default.

**Not every row survived.** 95 of 740 throughput rows and 83 of 282 latency rows
are missing from these tables because the server stalled, answered incorrectly
or was driven past its capacity. In each case the number not really described 
the server's speed.

<h2 id="how-it-was-run">How it was run</h2>

```
load        h2load, 4 threads
            h1         50 connections x 1 stream
            h2         50 connections x 10 streams
duration    10s measured, 3s warmup, 5 repeats
latency     wrk2 http/1, 50 connections, 4 threads, fixed rate ladders
cpu         server pinned to cores 0-5, load generator to cores 6-11
```

<details>
<summary>Versions</summary>

| | version |
| --- | --- |
| Gleam | 1.18.0 |
| Erlang/OTP | 29 |
| Elixir | 1.19.4 |
| h2load | nghttp2 1.69.0 |
| wrk2 | `44a94c1` |
| `ewe@4` | 4.0.1 |
| `mist` | 6.0.3 |
| `elli` | 3.3.0 |
| `bandit` | 1.12.0 |
| `roadrunner` | 0.8.0 |
| `chatterbox` | 0.8.0 |

</details>

<h2 id="throughput-http-1.1">Throughput: HTTP/1.1</h2>

Requests per second, higher is better. Best in each row is bold.

| case | ewe@5 | ewe@4 | mist | elli | roadrunner | bandit | httpd |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hello` | **263,626** | 177,750 | 195,679 | 260,834 | 245,115 | 145,446 | 100,347 |
| `hello_headers` | 212,005 | 142,136 | 152,771 | **214,961** | 197,112 | 120,482 | 84,057 |
| `echo_1kb` | 219,243 | 157,622 | 172,493 | **231,526** | 210,856 | 133,830 | 73,699 |
| `echo_1kb_headers` | 177,036 | 126,760 | 142,050 | **205,897** | 185,680 | 113,018 | 55,418 |
| `echo_10kb` | **190,931** | 144,334 | 155,218 | 166,859 | 183,455 | 114,652 | 12,497 |
| `echo_chunked_10kb` | **194,402** | 136,069 | 155,080 | — | 183,763 | 104,944 | — |
| `file_tiny` | **68,969** | — | 37,649 | 38,745 | 37,699 | 50,007 | 33,566 |
| `file_small` | **60,213** | — | 35,123 | 35,743 | 35,303 | 45,293 | 29,604 |
| `file_big` | 3,411 | — | **3,420** | 3,369 | 3,376 | 3,346 | 1,314 |
| `stream` | **139,207** | — | — | — | 34,513 | 82,577 | 98,329 |
| `stream_small` | **7,921** | — | — | — | 6,384 | 6,801 | 7,890 |
| `stream_big` | **7,853** | — | — | — | 7,313 | 6,729 | 7,692 |
| `sse` | **17,398** | — | — | — | 12,350 | — | — |
| `sse_small` | **6,122** | — | — | — | 6,039 | — | — |
| `sse_big` | **5,867** | — | — | — | 2,432 | — | — |

ewe@5 achieved the highest throughput in 11 out of 15 scenarios. Three of the 
cases where it trailed involved small payload request handling where `elli` 
maintained an advantage. The fourth was `file_big` where five of the servers 
performed within 2% of each other, as the 5 MiB payload transfer time became 
the primary bottleneck.

The streaming benchmarks sent multiple frames per request:

| case | ewe@5 | roadrunner | bandit | httpd |
| --- | ---: | ---: | ---: | ---: |
| `stream` | **278,414** | 69,026 | 165,154 | 196,658 |
| `stream_small` | **792,090** | 638,440 | 680,100 | 788,960 |
| `stream_big` | **502,592** | 468,019 | 430,682 | 492,307 |
| `sse` | **556,720** | 395,184 | — | — |
| `sse_small` | **612,230** | 603,940 | — | — |
| `sse_big` | **375,482** | 155,616 | — | — |

<h2 id="throughput-http-2">Throughput: HTTP/2</h2>

| case | ewe@5 | roadrunner | bandit | chatterbox |
| --- | ---: | ---: | ---: | ---: |
| `hello` | 161,818 | **208,646** | 77,163 | 8,307 |
| `hello_headers` | 132,414 | **170,414** | 70,781 | 8,307 |
| `echo_1kb` | 114,323 | **179,320** | 66,793 | 7,087 |
| `echo_1kb_headers` | 100,474 | **146,623** | 60,932 | 7,072 |
| `echo_10kb` | 94,743 | **139,063** | 55,153 | 8,695 |
| `echo_chunked_10kb` | 91,506 | **134,671** | 52,649 | 8,688 |
| `file_tiny` | **82,601** | 34,653 | 40,192 | 8,372 |
| `file_small` | **51,610** | 24,965 | 30,246 | 26,198 |
| `file_big` | 497 | **1,005** | 750 | 527 |
| `stream` | 88,401 | **114,733** | 50,032 | 8,764 |
| `stream_small` | 5,086 | 6,149 | 4,455 | **10,687** |
| `stream_big` | 5,189 | **6,428** | 4,554 | — |
| `sse` | 10,955 | **15,414** | — | — |
| `sse_small` | 3,817 | **5,547** | — | — |
| `sse_big` | **3,323** | 2,162 | — | — |

Roadrunner led in most h2c scenarios. [Known bottlenecks and limitations](#known-bottlenecks-and-limitations)
covers where are the flaws of ewe@5 implementation.

<h2 id="against-ewe-4">Against ewe@4</h2>

Shared endpoints over HTTP/1.1:

| case | ewe@5 | ewe@4 | gain |
| --- | ---: | ---: | ---: |
| `hello` | **263,626** | 177,750 | **+48%** |
| `hello_headers` | **212,005** | 142,136 | **+49%** |
| `echo_1kb` | **219,243** | 157,622 | **+39%** |
| `echo_1kb_headers` | **177,036** | 126,760 | **+40%** |
| `echo_10kb` | **190,931** | 144,334 | **+32%** |
| `echo_chunked_10kb` | **194,402** | 136,069 | **+43%** |

ewe@5 achieved a 32% to 49% throughput increase across all shared test cases. 
The remaining nine cases are omitted because ewe@4 did not successfully process 
multiple requests per connection.

ewe@4 shows latency degradation under sustained loads. When held at 150,000 
req/s on `hello_headers`, its p99 latency rose to 872.96 ms while ewe@5 
maintained 3.67 ms. Similarly on `echo_chunked_10kb` at 100,000 req/s ewe@4 
recorded 511.49 ms compared to ewe@5's 4.01 ms.

<h2 id="against-mist">Against mist</h2>

| case | ewe@5 | mist | gain |
| --- | ---: | ---: | ---: |
| `hello` | **263,626** | 195,679 | **+35%** |
| `hello_headers` | **212,005** | 152,771 | **+39%** |
| `echo_1kb` | **219,243** | 172,493 | **+27%** |
| `echo_1kb_headers` | **177,036** | 142,050 | **+25%** |
| `echo_10kb` | **190,931** | 155,218 | **+23%** |
| `echo_chunked_10kb` | **194,402** | 155,080 | **+25%** |
| `file_tiny` | **68,969** | 37,649 | **+83%** |
| `file_small` | **60,213** | 35,123 | **+71%** |

ewe@5 showed a 23% to 39% throughput improvement on standard request cases and a 
71% to 83% advantage on static file serving.

Under load ewe@5 also demonstrated lower latency percentiles. At 150,000 req/s 
on `hello_headers`, mist's p99 latency was 9.94 ms compared to ewe@5's 3.67 ms. 
At 100,000 req/s on `echo_chunked_10kb` mist recorded 7.12 ms against ewe@5's 4.01 ms.

<h2 id="against-elli-and-roadrunner">Against elli and roadrunner</h2>

These two engines represent the primary benchmarks for HTTP/1.1 performance.

`elli` is a mature production-proven Erlang server. ewe@5 maintained competitive 
performance alongside it:

| case | ewe@5 | elli | difference |
| --- | ---: | ---: | ---: |
| `hello` | **263,626** | 260,834 | +1% |
| `hello_headers` | 212,005 | **214,961** | −1% |
| `echo_1kb` | 219,243 | **231,526** | −5% |
| `echo_1kb_headers` | 177,036 | **205,897** | −14% |
| `echo_10kb` | **190,931** | 166,859 | +14% |
| `file_tiny` | **68,969** | 38,745 | +78% |
| `file_small` | **60,213** | 35,743 | +68% |
| `file_big` | **3,411** | 3,369 | +1% |

There is no SSE API and no incremental body read for elli.

`roadrunner` competes across the whole tests:

| case | ewe@5 | roadrunner | difference |
| --- | ---: | ---: | ---: |
| `hello` | **263,626** | 245,115 | +8% |
| `hello_headers` | **212,005** | 197,112 | +8% |
| `echo_1kb` | **219,243** | 210,856 | +4% |
| `echo_1kb_headers` | 177,036 | **185,680** | −5% |
| `echo_10kb` | **190,931** | 183,455 | +4% |
| `echo_chunked_10kb` | **194,402** | 183,763 | +6% |
| `file_tiny` | **68,969** | 37,699 | +83% |
| `file_small` | **60,213** | 35,303 | +71% |
| `file_big` | **3,411** | 3,376 | +1% |
| `stream` | **139,207** | 34,513 | +303% |
| `stream_small` | **7,921** | 6,384 | +24% |
| `stream_big` | **7,853** | 7,313 | +7% |
| `sse` | **17,398** | 12,350 | +41% |
| `sse_small` | **6,122** | 6,039 | +1% |
| `sse_big` | **5,867** | 2,432 | +141% |

ewe@5 led in 14 of 15 on HTTP/1.1, a few percent ahead on the plain request
cases, far ahead on files and streaming.

<h2 id="against-bandit-on-http-2">Against bandit on HTTP/2</h2>

| case | ewe@5 | bandit | difference |
| --- | ---: | ---: | ---: |
| `hello` | **161,818** | 77,163 | +110% |
| `hello_headers` | **132,414** | 70,781 | +87% |
| `echo_1kb` | **114,323** | 66,793 | +71% |
| `echo_1kb_headers` | **100,474** | 60,932 | +65% |
| `echo_10kb` | **94,743** | 55,153 | +72% |
| `echo_chunked_10kb` | **91,506** | 52,649 | +74% |
| `file_tiny` | **82,601** | 40,192 | +106% |
| `file_small` | **51,610** | 30,246 | +71% |
| `file_big` | 497 | **750** | −34% |
| `stream` | **88,401** | 50,032 | +77% |
| `stream_small` | **5,086** | 4,455 | +14% |
| `stream_big` | **5,189** | 4,554 | +14% |

ewe@5 led in 11 of the 12 shared test cases showing a 65% to 110% improvement on 
request and file tasks and a 14% improvement on smaller stream runs. The exception 
is `file_big` which is affected by the HTTP/2 window limitation detailed in the 
[Known Bottlenecks and Limitations](#known-bottlenecks-and-limitations) section.

`wrk2` has no HTTP/2 support so there are no latency numbers for this table.

<h2 id="latency">Latency</h2>

`wrk2` targets a fixed request rate meaning its latency percentiles account for 
queuing delays before transmission. If the load generator fails to maintain the 
target rate the server has exceeded its capacity and the resulting percentiles 
may no longer accurately reflect performance.

A `—` means the server couldn't hold that rate.

| case | ewe@5 | ewe@4 | mist | elli | roadrunner | bandit | httpd |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hello` @ 150,000 | 3.97ms | 4.96ms | 4.09ms | **3.84ms** | 4.03ms | 53.98ms | — |
| `echo_1kb` @ 100,000 | 3.91ms | 3.75ms | 3.69ms | 3.77ms | **3.63ms** | 3.90ms | — |
| `echo_10kb` @ 100,000 | **3.75ms** | 3.86ms | 4.17ms | 4.52ms | 3.78ms | 6.43ms | — |
| `echo_chunked_10kb` @ 70,000 | 3.57ms | 3.57ms | **3.49ms** | — | 3.50ms | 7.70ms | — |
| `file_small` @ 30,000 | 4.65ms | — | 6.08ms | 4.73ms | 5.13ms | **4.49ms** | 191.74ms |
| `file_big` @ 1,500 | **4.61ms** | — | 4.89ms | 4.76ms | 4.72ms | 4.72ms | — |
| `stream` @ 60,000 | **3.33ms** | — | — | — | — | 4.28ms | 3.85ms |
| `sse` @ 6,000 | **2.59ms** | 3.36ms | 3.12ms | — | 2.83ms | — | — |

ewe@5 achieved the lowest latency in four of the eight scenarios and remained 
within 0.28 ms of the top-performing server in the remaining four.

<h2 id="known-bottlenecks-and-limitations">Known Bottlenecks and Limitations</h2>

**HTTP/2 Request Handling:** Roadrunner maintains a 22% to 36% performance lead 
over h2c on `hello`, echo cases and `stream`. While ewe@5 significantly 
outperforms bandit in these tests, roadrunner's HTTP/2 implementation is simply 
faster.

**Large Files over HTTP/2:** ewe@5 achieves only 497 req/s compared to 
roadrunner's 1,005 req/s and bandit's 750 req/s. The bottleneck stems from the 
connection flow-control window. ewe@5 defaults to a static window size of 65,535 
bytes without dynamic window scaling. Consequently delivering a 5 MiB response 
requires approximately eighty `WINDOW_UPDATE` round trips which must be 
coordinated across ten concurrent streams.

**Small Payloads on HTTP/1.1:** ewe@5 falls behind elli by up to 14% on specific
cases like `echo_1kb_headers`.

**SSE over HTTP/2.** ewe@5 trails roadrunner by 29% to 31% on `sse` and 
`sse_small` over h2c.

<h2 id="reproducing">Reproducing</h2>

To run these benchmarks locally:

```sh
cd benchmark
REPEATS=5 ./throughput.sh
./latency.sh
```
