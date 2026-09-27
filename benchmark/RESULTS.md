# ewe@9 benchmarks

This page evaluates the performance of ewe@9 against ewe@8 and six other 
BEAM-based web servers. Benchmarks were measured on September 26 2026 across 
fifteen endpoints using both HTTP/1.1 and cleartext HTTP/2.

On HTTP/1.1 ewe@9 outperformed the other servers in 12 of the 15 tested 
scenarios and stayed within 4% of ewe@8 on every case. On HTTP/2 it outperformed 
every server in 13 of 15 scenarios delivering 39% to 144% more throughput than 
ewe@8 on 14 of them. The `file_big` endpoint on cleartext HTTP/2 represents its 
weakest comparative performance. See 
[Known Bottlenecks and Limitations](#known-bottlenecks-and-limitations) section.

All reported figures represent the median of three consecutive runs.

## Content
- [How to read these numbers](#how-to-read-these-numbers)
- [How it was run](#how-it-was-run)
- [Throughput: HTTP/1.1](#throughput-http-1.1)
- [Throughput: HTTP/2](#throughput-http-2)
- [Against ewe@8](#against-ewe-8)
- [Against mist](#against-mist)
- [Against elli and roadrunner on HTTP/1](#against-elli-and-roadrunner)
- [Against roadrunner and bandit on HTTP/2](#against-roadrunner-and-bandit-on-http-2)
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

**Not every row survived.** 30 of 489 throughput rows and 57 of 282 latency rows
are missing from these tables because the server stalled, answered incorrectly
or was driven past its capacity. In each case the number not really described 
the server's speed.

<h2 id="how-it-was-run">How it was run</h2>

```
load        h2load, 4 threads
            h1         50 connections x 1 stream
            h2         50 connections x 10 streams
duration    10s measured, 3s warmup, 3 repeats
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
| h2load | nghttp2 1.70.0 |
| wrk2 | `44a94c1` |
| `ewe@8` | 8.0.0 |
| `mist` | 6.0.3 |
| `elli` | 3.3.0 |
| `bandit` | 1.12.0 |
| `roadrunner` | 0.8.0 |
| `chatterbox` | 0.8.0 |

</details>

<h2 id="throughput-http-1.1">Throughput: HTTP/1.1</h2>

Requests per second, higher is better. Best in each row is bold.

| case | ewe@9 | ewe@8 | mist | elli | roadrunner | bandit | httpd |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hello` | 275,439 | **282,622** | 201,897 | 267,914 | 254,256 | 149,214 | 102,489 |
| `hello_headers` | **232,846** | 225,152 | 157,902 | 222,884 | 205,181 | 122,866 | 85,989 |
| `echo_1kb` | 229,498 | 233,779 | 177,461 | **247,351** | 221,814 | 136,389 | 74,874 |
| `echo_1kb_headers` | 202,558 | 204,050 | 146,355 | **208,486** | 191,658 | 114,188 | 56,074 |
| `echo_10kb` | 193,708 | **194,201** | 160,960 | 170,952 | 187,372 | 119,884 | 12,551 |
| `echo_chunked_10kb` | 193,991 | **195,798** | 158,704 | — | 188,410 | 107,016 | — |
| `file_tiny` | 68,920 | **69,561** | 38,755 | 40,097 | 38,291 | 49,586 | 32,893 |
| `file_small` | 59,293 | **60,381** | 36,221 | 36,939 | 35,725 | 47,540 | 28,671 |
| `file_big` | 3,730 | **3,762** | 3,754 | 3,669 | 3,727 | 3,691 | 1,317 |
| `stream` | **148,422** | 142,925 | — | — | 34,977 | 86,545 | 102,764 |
| `stream_small` | **8,374** | 8,207 | — | — | 6,785 | 7,214 | 8,288 |
| `stream_big` | 8,697 | **8,726** | — | — | 7,691 | 7,343 | 8,510 |
| `sse` | **18,606** | 18,341 | — | — | 12,796 | — | — |
| `sse_small` | 6,577 | **6,598** | — | — | 6,264 | — | — |
| `sse_big` | 6,486 | **6,781** | — | — | 2,444 | — | — |

The difference between ewe@8 and ewe@9 are noice as ewe@9 didn't introduce any 
downgrading changes to HTTP/1.1. ewe achieved the highest throughput in 12 
out of 15 scenarios. Two of the cases where it trailed involved small payload 
echo handling where `elli` maintained an advantage. The third was `file_big` 
where six of the servers performed within 3% of each other as the 5 MiB payload 
transfer time became the primary bottleneck.

The streaming benchmarks sent multiple frames per request:

| case | ewe@9 | ewe@8 | roadrunner | bandit | httpd |
| --- | ---: | ---: | ---: | ---: | ---: |
| `stream` | **296,844** | 285,850 | 69,953 | 173,089 | 205,528 |
| `stream_small` | **837,410** | 820,670 | 678,450 | 721,400 | 828,840 |
| `stream_big` | 556,614 | **558,451** | 492,218 | 469,952 | 544,627 |
| `sse` | **595,376** | 586,896 | 409,475 | — | — |
| `sse_small` | 657,650 | **659,800** | 626,360 | — | — |
| `sse_big` | 415,098 | **433,952** | 156,410 | — | — |

<h2 id="throughput-http-2">Throughput: HTTP/2</h2>

| case | ewe@9 | ewe@8 | roadrunner | bandit | chatterbox |
| --- | ---: | ---: | ---: | ---: | ---: |
| `hello` | **363,035** | 163,450 | 216,188 | 80,467 | 8,307 |
| `hello_headers` | **259,101** | 137,648 | 178,425 | 72,721 | 8,309 |
| `echo_1kb` | **211,514** | 120,417 | 186,200 | 68,590 | 7,097 |
| `echo_1kb_headers` | **167,435** | 110,368 | 155,359 | 63,238 | 7,061 |
| `echo_10kb` | 137,507 | 99,088 | **140,386** | 57,553 | 8,685 |
| `echo_chunked_10kb` | **141,614** | 93,774 | 136,139 | 54,651 | 8,693 |
| `file_tiny` | **129,972** | 81,861 | 35,029 | 40,707 | 8,386 |
| `file_small` | 47,999 | **49,874** | 25,559 | 31,624 | 26,619 |
| `file_big` | 949 | 493 | **1,074** | 749 | 472 |
| `stream` | **200,561** | 88,386 | 128,305 | 52,299 | 8,799 |
| `stream_small` | **12,490** | 5,122 | 6,657 | 4,541 | 10,530 |
| `stream_big` | **11,938** | 5,441 | 6,945 | 4,937 | — |
| `sse` | **23,603** | 9,899 | 16,456 | — | — |
| `sse_small` | **8,512** | 3,579 | 5,809 | — | — |
| `sse_big` | **4,842** | 3,257 | 2,256 | — | — |

ewe@9 led in 13 of 15 cleartext HTTP/2 scenarios. Roadrunner kept the lead on 
`echo_10kb` by 2% and on `file_big` by 12%. 
[Known bottlenecks and limitations](#known-bottlenecks-and-limitations) covers 
where are the flaws of ewe@9 implementation.

The streaming benchmarks over h2c:

| case | ewe@9 | ewe@8 | roadrunner | bandit | chatterbox |
| --- | ---: | ---: | ---: | ---: | ---: |
| `stream` | **401,122** | 176,771 | 256,610 | 104,597 | 17,597 |
| `stream_small` | **1,248,960** | 512,160 | 665,650 | 454,070 | 1,053,010 |
| `stream_big` | **764,038** | 348,243 | 444,461 | 315,974 | — |
| `sse` | **755,302** | 316,774 | 526,576 | — | — |
| `sse_small` | **851,180** | 357,910 | 580,920 | — | — |
| `sse_big` | **309,914** | 208,461 | 144,352 | — | — |

<h2 id="against-ewe-8">Against ewe@8</h2>

Over HTTP/2:

| case | ewe@9 | ewe@8 | gain |
| --- | ---: | ---: | ---: |
| `hello` | **363,035** | 163,450 | **+122%** |
| `hello_headers` | **259,101** | 137,648 | **+88%** |
| `echo_1kb` | **211,514** | 120,417 | **+76%** |
| `echo_1kb_headers` | **167,435** | 110,368 | **+52%** |
| `echo_10kb` | **137,507** | 99,088 | **+39%** |
| `echo_chunked_10kb` | **141,614** | 93,774 | **+51%** |
| `file_tiny` | **129,972** | 81,861 | **+59%** |
| `file_small` | 47,999 | **49,874** | −4% |
| `file_big` | **949** | 493 | **+92%** |
| `stream` | **200,561** | 88,386 | **+127%** |
| `stream_small` | **12,490** | 5,122 | **+144%** |
| `stream_big` | **11,938** | 5,441 | **+119%** |
| `sse` | **23,603** | 9,899 | **+138%** |
| `sse_small` | **8,512** | 3,579 | **+138%** |
| `sse_big` | **4,842** | 3,257 | **+49%** |

ewe@9 achieved a 39% to 144% throughput increase on 14 of the 15 h2c cases. The 
exception is `file_small` at 4% below ewe@8.

Under sustained HTTP/1.1 load ewe@9 has slightly higher tail latency than ewe@8 
on most request cases. At 150,000 req/s on `hello` its p99 was 4.18 ms against 
ewe@8's 3.61 ms, and at 150,000 req/s on `echo_1kb` 4.32 ms against 3.58 ms. 
On streaming it holds the heavy rungs better. At 7,000 req/s on `stream_small` 
ewe@9 recorded 12.46 ms against ewe@8's 24.27 ms and at 5,000 req/s on 
`sse_small` 12.53 ms against 18.14 ms.

<h2 id="against-mist">Against mist</h2>

| case | ewe@9 | mist | gain |
| --- | ---: | ---: | ---: |
| `hello` | **275,439** | 201,897 | **+36%** |
| `hello_headers` | **232,846** | 157,902 | **+47%** |
| `echo_1kb` | **229,498** | 177,461 | **+29%** |
| `echo_1kb_headers` | **202,558** | 146,355 | **+38%** |
| `echo_10kb` | **193,708** | 160,960 | **+20%** |
| `echo_chunked_10kb` | **193,991** | 158,704 | **+22%** |
| `file_tiny` | **68,920** | 38,755 | **+78%** |
| `file_small` | **59,293** | 36,221 | **+64%** |

ewe@9 showed a 20% to 47% throughput improvement on standard request cases and a 
64% to 78% advantage on static file serving.

Under load ewe@9 also demonstrated lower latency percentiles. At 150,000 req/s 
on `hello_headers`, mist's p99 latency was 8.28 ms compared to ewe@9's 4.07 ms. 
At 100,000 req/s on `echo_chunked_10kb` mist recorded 6.45 ms against ewe@9's 
4.02 ms, and at 10,000 req/s on `sse` 83.58 ms against 4.00 ms.

<h2 id="against-elli-and-roadrunner">Against elli and roadrunner on HTTP/1</h2>

These two engines represent the primary benchmarks for HTTP/1.1 performance.

`elli` is a mature production-proven Erlang server. ewe@9 maintained competitive 
performance alongside it:

| case | ewe@9 | elli | difference |
| --- | ---: | ---: | ---: |
| `hello` | **275,439** | 267,914 | +3% |
| `hello_headers` | **232,846** | 222,884 | +4% |
| `echo_1kb` | 229,498 | **247,351** | −7% |
| `echo_1kb_headers` | 202,558 | **208,486** | −3% |
| `echo_10kb` | **193,708** | 170,952 | +13% |
| `file_tiny` | **68,920** | 40,097 | +72% |
| `file_small` | **59,293** | 36,939 | +61% |
| `file_big` | **3,730** | 3,669 | +2% |

There is no SSE API and no incremental body read for elli.

`roadrunner` competes across the whole tests:

| case | ewe@9 | roadrunner | difference |
| --- | ---: | ---: | ---: |
| `hello` | **275,439** | 254,256 | +8% |
| `hello_headers` | **232,846** | 205,181 | +13% |
| `echo_1kb` | **229,498** | 221,814 | +3% |
| `echo_1kb_headers` | **202,558** | 191,658 | +6% |
| `echo_10kb` | **193,708** | 187,372 | +3% |
| `echo_chunked_10kb` | **193,991** | 188,410 | +3% |
| `file_tiny` | **68,920** | 38,291 | +80% |
| `file_small` | **59,293** | 35,725 | +66% |
| `file_big` | **3,730** | 3,727 | 0% |
| `stream` | **148,422** | 34,977 | +324% |
| `stream_small` | **8,374** | 6,785 | +23% |
| `stream_big` | **8,697** | 7,691 | +13% |
| `sse` | **18,606** | 12,796 | +45% |
| `sse_small` | **6,577** | 6,264 | +5% |
| `sse_big` | **6,486** | 2,444 | +165% |

ewe@9 led in all 15 on HTTP/1.1 with a few percent ahead on the plain request 
cases and far ahead on files and streaming (this difference happens due to 
roadrunner not reusing the connection on streams).

<h2 id="against-roadrunner-and-bandit-on-http-2">Against roadrunner and bandit on HTTP/2</h2>

| case | ewe@9 | roadrunner | difference |
| --- | ---: | ---: | ---: |
| `hello` | **363,035** | 216,188 | +68% |
| `hello_headers` | **259,101** | 178,425 | +45% |
| `echo_1kb` | **211,514** | 186,200 | +14% |
| `echo_1kb_headers` | **167,435** | 155,359 | +8% |
| `echo_10kb` | 137,507 | **140,386** | −2% |
| `echo_chunked_10kb` | **141,614** | 136,139 | +4% |
| `file_tiny` | **129,972** | 35,029 | +271% |
| `file_small` | **47,999** | 25,559 | +88% |
| `file_big` | 949 | **1,074** | −12% |
| `stream` | **200,561** | 128,305 | +56% |
| `stream_small` | **12,490** | 6,657 | +88% |
| `stream_big` | **11,938** | 6,945 | +72% |
| `sse` | **23,603** | 16,456 | +43% |
| `sse_small` | **8,512** | 5,809 | +47% |
| `sse_big` | **4,842** | 2,256 | +115% |

ewe@9 led roadrunner in 13 of 15 h2c cases. The margin is largest on files and 
streaming, 43% to 271%, and narrows to 4% to 14% on the echo cases where the 
request body dominates. `echo_10kb` is within 2% and `file_big` trails by 12%.

| case | ewe@9 | bandit | difference |
| --- | ---: | ---: | ---: |
| `hello` | **363,035** | 80,467 | +351% |
| `hello_headers` | **259,101** | 72,721 | +256% |
| `echo_1kb` | **211,514** | 68,590 | +208% |
| `echo_1kb_headers` | **167,435** | 63,238 | +165% |
| `echo_10kb` | **137,507** | 57,553 | +139% |
| `echo_chunked_10kb` | **141,614** | 54,651 | +159% |
| `file_tiny` | **129,972** | 40,707 | +219% |
| `file_small` | **47,999** | 31,624 | +52% |
| `file_big` | **949** | 749 | +27% |
| `stream` | **200,561** | 52,299 | +283% |
| `stream_small` | **12,490** | 4,541 | +175% |
| `stream_big` | **11,938** | 4,937 | +142% |

ewe@9 led in all 12 of the shared test cases showing a 139% to 351% improvement 
on request tasks and 27% to 283% on files and streaming.

`wrk2` has no HTTP/2 support so there are no latency numbers for these tables.

<h2 id="latency">Latency</h2>

`wrk2` targets a fixed request rate meaning its latency percentiles account for 
queuing delays before transmission. If the load generator fails to maintain the 
target rate the server has exceeded its capacity and the resulting percentiles 
may no longer accurately reflect performance.

A `—` means the server couldn't hold that rate.

| case | ewe@9 | ewe@8 | mist | elli | roadrunner | bandit | httpd |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hello` @ 150,000 | 4.18ms | **3.61ms** | 3.82ms | 4.20ms | 3.70ms | 23.66ms | — |
| `echo_1kb` @ 100,000 | 3.85ms | **3.48ms** | 3.77ms | 3.50ms | 3.61ms | 3.81ms | — |
| `echo_10kb` @ 100,000 | 3.84ms | **3.53ms** | 3.85ms | 4.04ms | 3.88ms | 5.78ms | — |
| `echo_chunked_10kb` @ 70,000 | 3.90ms | **3.50ms** | 3.82ms | — | 3.60ms | 8.93ms | — |
| `file_small` @ 30,000 | **4.43ms** | 4.80ms | 5.34ms | 4.97ms | 5.56ms | 4.82ms | 78.01ms |
| `file_big` @ 1,500 | 4.82ms | 4.90ms | 4.60ms | **4.59ms** | 4.74ms | 4.69ms | 9.44ms |
| `stream` @ 60,000 | 3.41ms | **3.17ms** | — | — | — | 3.94ms | 3.64ms |
| `sse` @ 6,000 | **2.58ms** | 2.59ms | 3.04ms | — | 2.82ms | — | — |

ewe@9 achieved the lowest latency in two of the eight scenarios and remained 
within 0.57 ms of the top-performing server in the remaining six. ewe@8 was the 
lowest in five of them.

<h2 id="known-bottlenecks-and-limitations">Known Bottlenecks and Limitations</h2>

**Large Files over HTTP/2:** ewe@9 achieves 949 req/s compared to roadrunner's 
1,074 req/s. That is nearly double ewe@8's 493 req/s and ahead of bandit's 
749 req/s but still 12% behind roadrunner.

**Small Payloads on HTTP/1.1:** ewe@9 falls behind elli by up to 7% on specific
cases like `echo_1kb`.

**HTTP/1.1 Tail Latency:** At the highest rung of five of the six request 
cases ewe@9's p99 sits 0.3 ms to 0.7 ms above ewe@8's while throughput is level 
between the two. `echo_chunked_10kb` is the exception.

**`file_small` over HTTP/2.** ewe@9 is the only h2c case where it trails ewe@8 
by 4%.

<h2 id="reproducing">Reproducing</h2>

To run these benchmarks locally:

```sh
cd benchmark
./throughput.sh
./latency.sh
```
