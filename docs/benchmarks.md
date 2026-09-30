# ewe@9 benchmarks

ewe@9 benchmarks against ewe@8 and nine other BEAM web servers over HTTP/1.1 and
cleartext HTTP/2, measured on September 29 2026. The scripts and the exact
method are in the repository's 
[benchmark directory](https://github.com/vshakitskiy/ewe/tree/mistress/benchmark).

## Setup

```
machine     AMD Ryzen 7 5700G, 12 vCPUs in a KVM virtual machine, Linux 7.2
toolchain   Gleam 1.18.0, Erlang/OTP 29, Elixir 1.19.4
cpu         server pinned to CPUs 0-5, load generator to CPUs 6-11
throughput  h2load (nghttp2 1.70.0), 4 threads, 50 connections,
            10 streams per connection on HTTP/2,
            3 runs of 10s after a 3s warmup, median reported
latency     zrk 2.5.0, 4 threads, 50 connections,
            10 streams per connection on HTTP/2,
            10s per rate after a 3s warmup
```

## Servers

| server | version | HTTP/1.1 | HTTP/2 |
| --- | --- | :---: | :---: |
| `ewe@9` | 9.0.0 | yes | yes |
| `ewe@8` | 8.0.0 | yes | yes |
| `mist` | 6.0.3 | yes | no |
| `elli` | 3.3.0 | yes | no |
| `bandit` | 1.12.0 | yes | yes |
| `httpd` | inets 9.7.1 (OTP 29) | yes | no |
| `roadrunner` | 0.8.0 | yes | yes |
| `chatterbox` | 0.8.0 | no | yes |
| `cowboy` | 2.19.0 | yes | yes |
| `mochiweb` | 3.5.0 | yes | no |
| `yaws` | 2.3.1 | yes | no |

Every server runs a production build with the default settings except:

- `cowboy`'s `max_keepalive` and `max_received_frame_rate` are lifted.
- `elli`, `httpd`, `mochiweb` and `yaws` have Nagle's algorithm disabled.
- `yaws` has its access and auth logs disabled and serves files without
  sendfile.

`bandit`, `chatterbox`, `elli`, `httpd` and `mochiweb` have no native SSE API;
`elli` and `httpd` cannot read a request body incrementally.

## Cases

| case | request | response |
| --- | --- | --- |
| `hello` | `GET /hello` | `Hello, Joe!` |
| `hello_headers` | `GET /hello` with 7 extra headers | `Hello, Joe!` |
| `echo_1kb` | `POST /echo`, 1KiB body | the body |
| `echo_1kb_headers` | `POST /echo`, 1KiB body, 7 extra headers | the body |
| `echo_10kb` | `POST /echo`, 10KiB body | the body |
| `echo_chunked_10kb` | `POST /echo/chunked`, 10KiB body | the body, read incrementally |
| `file_tiny` | `GET /file/tiny` | 1KiB file |
| `file_small` | `GET /file/small` | 100KiB file |
| `file_big` | `GET /file/big` | 5MiB file |
| `stream` | `GET /stream` | 2 chunks, `hello, ` and `Joe!` |
| `stream_small` | `GET /stream/small` | 100 x 64B chunks |
| `stream_big` | `GET /stream/big` | 64 x 16KiB chunks |
| `sse` | `GET /sse` | 32 events |
| `sse_small` | `GET /sse/small` | 100 events |
| `sse_big` | `GET /sse/big` | 64 x 16KiB events |

## Throughput

Requests per second, higher is better. Rps above 200_000  are limited by the 
load generator so small differences in numbers between servers may be not 
accurate.

### HTTP/1.1

| case              |       ewe@9 |       ewe@8 |    mist |        elli |  bandit |       httpd | roadrunner |  cowboy | mochiweb |         yaws |
| ----------------- | ----------: | ----------: | ------: | ----------: | ------: | ----------: | ---------: | ------: | -------: | -----------: |
| hello             |     266,046 | **283,205** | 199,559 |   276,538 ~ | 152,776 |     103,490 |    246,009 | 116,951 |  180,532 |      165,957 |
| hello_headers     | **223,539** |     221,090 | 159,693 |     219,366 | 124,005 |      87,236 |    197,914 |  95,855 |  133,774 |      118,936 |
| echo_1kb          |     230,146 |     241,469 | 173,837 | **242,937** | 139,177 |      76,045 |    213,377 |  82,815 |  158,673 |      143,420 |
| echo_1kb_headers  |     201,422 |     198,650 | 143,568 | **205,644** | 116,815 |      57,985 |    185,188 |  72,432 |  122,660 |      105,882 |
| echo_10kb         |     188,255 | **190,263** | 158,321 |     166,777 | 119,510 |      12,513 |    183,832 |  66,638 |  116,616 |      111,922 |
| echo_chunked_10kb |     188,239 | **191,041** | 155,390 |           - | 109,274 |           - |    183,607 |  63,295 |  117,395 |      113,277 |
| file_tiny         |      69,500 |      69,346 |  37,838 |      39,857 |  49,345 |      34,046 |     38,771 |  33,116 | 64,847 ~ | **84,558** ~ |
| file_small        |      58,114 |  **59,962** |  35,100 |      37,018 |  44,618 |      29,559 |     35,878 |  30,641 |   20,220 |       13,480 |
| file_big          |   **3,695** |       3,622 |   3,599 |       3,657 |   3,610 |     1,303 ~ |      3,586 |   3,648 |      556 |        575 ~ |
| stream            |     142,687 | **144,423** | stalled |     stalled |  85,869 |     102,903 |   35,489 ~ |  79,342 |  100,729 |      101,332 |
| stream_small      |       8,165 |     8,092 ~ | stalled |     stalled |   7,147 | **8,466** ~ |      6,759 |   6,787 |    7,340 |        6,219 |
| stream_big        |       8,359 |     8,420 ~ | stalled |     stalled |   7,131 |   **8,440** |      7,700 |   7,051 |    7,445 |        6,504 |
| sse               |      17,705 |  **18,178** | stalled |           - |       - |           - |     13,090 |  13,747 |        - |       16,945 |
| sse_small         |       6,344 |   **6,484** | stalled |           - |       - |           - |      6,270 |   5,017 |        - |        5,900 |
| sse_big           |   **6,488** |       6,370 | stalled |           - |       - |           - |      2,465 |   2,361 |        - |        6,131 |

### HTTP/2

| case              |        ewe@9 |        ewe@8 |   bandit |  roadrunner | chatterbox |  cowboy |
| ----------------- | -----------: | -----------: | -------: | ----------: | ---------: | ------: |
| hello             |  **360,596** |      160,289 |   81,403 |     211,119 |      8,267 | 134,163 |
| hello_headers     |  **259,677** |      136,404 |   73,186 |     172,403 |      8,255 |  77,239 |
| echo_1kb          |  **199,023** |      118,402 |   68,576 |     183,023 |      7,310 |  90,615 |
| echo_1kb_headers  |  **162,428** |      107,699 |   62,943 |     152,565 |      7,227 |  60,352 |
| echo_10kb         |      132,853 |       96,793 |   57,692 | **138,248** |      8,476 |  76,147 |
| echo_chunked_10kb |      132,779 |       92,030 |   54,870 | **135,459** |      8,487 |  69,822 |
| file_tiny         |  **128,795** |       81,594 |   39,196 |      34,993 |      8,385 |  30,792 |
| file_small        |     45,262 ~ | **47,144** ~ | 30,113 ~ |      25,000 |     26,683 |  11,224 |
| file_big          |        982 ~ |        507 ~ |      750 | **1,066** ~ |      721 ~ |     321 |
| stream            |  **203,349** |       87,498 |   52,199 |     126,173 |      8,734 |  88,728 |
| stream_small      |   **13,156** |        4,831 |    4,500 |       6,424 |     10,922 |   5,884 |
| stream_big        | **11,957** ~ |        5,233 |    4,842 |       6,678 |    stalled |   6,212 |
| sse               |   **24,448** |        9,825 |        - |      15,974 |          - |  12,448 |
| sse_small         |    **8,667** |        3,415 |        - |       5,673 |          - |   4,298 |
| sse_big           |    **5,449** |        3,208 |        - |       2,193 |          - |   2,134 |

## Latency

p99 latency at a fixed offered rate with no coordinated omission, lower is 
better. Every server gets the same rates.

### HTTP/1.1

| case              |   req/s |       ewe@9 |      ewe@8 |       mist |       elli |     bandit |       httpd | roadrunner |     cowboy |   mochiweb |       yaws |
| ----------------- | ------: | ----------: | ---------: | ---------: | ---------: | ---------: | ----------: | ---------: | ---------: | ---------: | ---------: |
| hello             |  50,000 |       169us |      162us |     1.71ms |  **132us** |      236us |       490us |      153us |      429us |      148us |      159us |
| hello             | 100,000 |      1.35ms |     1.26ms |     2.79ms |  **833us** |     3.04ms |     37.78ms |     1.18ms |    14.32ms |     2.49ms |     2.82ms |
| hello             | 150,000 |      3.19ms |     3.21ms |     3.32ms | **2.90ms** |   355.71ms |  overloaded |     3.15ms | overloaded |     6.25ms |     9.35ms |
| hello_headers     |  50,000 |       218us |      207us |      231us |  **171us** |      318us |      2.70ms |      198us |      910us |      422us |      437us |
| hello_headers     | 100,000 |  **1.26ms** |     2.17ms |     3.10ms |     2.12ms |     3.33ms |  overloaded |     2.05ms | overloaded |    16.10ms |     6.70ms |
| hello_headers     | 150,000 |      3.35ms |     3.67ms |   418.43ms | **2.88ms** | overloaded |  overloaded |     4.28ms | overloaded | overloaded | overloaded |
| echo_1kb          |  50,000 |       162us |  **159us** |      195us |      162us |      208us |      3.96ms |      167us |     2.77ms |      253us |      220us |
| echo_1kb          | 100,000 |      1.83ms |     1.68ms |     2.52ms | **1.23ms** |     2.84ms |  overloaded |     2.73ms | overloaded |     3.93ms |     3.63ms |
| echo_1kb          | 150,000 |      3.65ms |     4.57ms |    11.44ms | **3.15ms** | overloaded |  overloaded |     3.17ms | overloaded |    18.38ms |   243.65ms |
| echo_1kb_headers  |  40,000 |   **156us** |      176us |      272us |      159us |      295us |      3.39ms |      166us |     1.52ms |      259us |      236us |
| echo_1kb_headers  |  80,000 |      1.66ms |      832us |     3.07ms |  **561us** |     3.25ms |  overloaded |      680us | overloaded |     3.77ms |     3.81ms |
| echo_1kb_headers  | 120,000 |      3.61ms |     2.94ms |     8.80ms | **2.87ms** | overloaded |  overloaded |     3.10ms | overloaded | overloaded | overloaded |
| echo_10kb         |  20,000 |       161us |      157us |      195us |  **154us** |      188us |  overloaded |      169us |      343us |      201us |      199us |
| echo_10kb         |  60,000 |       469us |      320us |      317us |      554us |     2.51ms |  overloaded |  **253us** |    32.55ms |     3.24ms |     2.87ms |
| echo_10kb         | 100,000 |  **1.16ms** |     2.26ms |     3.71ms |     3.18ms |     4.21ms |  overloaded |     2.81ms | overloaded |    13.04ms |   106.14ms |
| echo_chunked_10kb |  40,000 |       177us |  **139us** |      220us |          - |      356us |           - |      160us |     2.89ms |      237us |      305us |
| echo_chunked_10kb |  70,000 |   **380us** |      408us |     2.31ms |          - |     2.95ms |           - |      455us | overloaded |     3.33ms |     3.31ms |
| echo_chunked_10kb | 100,000 |      3.29ms | **2.40ms** |     3.24ms |          - |    27.50ms |           - |     3.12ms | overloaded |     6.44ms |    30.41ms |
| file_tiny         |  20,000 |       707us |      398us |      929us |      442us |     1.76ms |       669us |      529us |      976us |     1.59ms |  **222us** |
| file_tiny         |  40,000 |      3.94ms |     3.76ms | overloaded |   181.95ms |     6.53ms |  overloaded | overloaded | overloaded |     4.94ms |  **386us** |
| file_tiny         |  60,000 | **37.87ms** |    54.42ms | overloaded | overloaded | overloaded |  overloaded | overloaded | overloaded |   160.19ms | overloaded |
| file_small        |  15,000 |       398us |  **343us** |      577us |      508us |      777us |      1.10ms |      571us |     1.25ms |    29.99ms | overloaded |
| file_small        |  30,000 |      3.35ms | **3.01ms** |     4.09ms |     3.76ms |     3.91ms |  overloaded |     5.10ms | overloaded | overloaded | overloaded |
| file_small        |  45,000 |  **9.35ms** |     9.60ms | overloaded | overloaded | overloaded |  overloaded | overloaded | overloaded | overloaded | overloaded |
| file_big          |     500 |      2.07ms |     1.90ms |     1.92ms |     1.90ms |     2.38ms |      2.24ms | **1.86ms** |     2.30ms |    58.06ms |    25.66ms |
| file_big          |   1,000 |      2.40ms |     2.31ms |     2.45ms |     2.52ms |     2.36ms |      4.68ms |     2.52ms | **2.25ms** | overloaded | overloaded |
| file_big          |   1,500 |      2.55ms |     2.50ms |     2.65ms |     2.58ms |     2.45ms |      7.49ms |     2.65ms | **2.44ms** | overloaded | overloaded |
| stream            |  20,000 |       208us |  **199us** |     errors |     errors |      287us |       256us |      715us |      290us |      232us |      253us |
| stream            |  40,000 |   **243us** |      274us |     errors |     errors |      888us |       439us | overloaded |     1.40ms |      402us |      556us |
| stream            |  60,000 |   **668us** |      838us |     errors |     errors |     3.56ms |      3.12ms | overloaded |     5.58ms |     3.23ms |     3.51ms |
| stream_small      |   3,000 |      1.77ms |     1.72ms |     errors |     errors |     2.15ms |  **1.67ms** |     2.13ms |     2.16ms |     2.08ms |     2.52ms |
| stream_small      |   5,000 |      2.65ms |     2.70ms |     errors |     errors |     5.98ms |  **2.38ms** |     4.76ms |     6.42ms |     5.37ms |    17.22ms |
| stream_small      |   7,000 |     16.05ms |    11.56ms |     errors |     errors | overloaded | **10.38ms** | overloaded | overloaded | overloaded | overloaded |
| stream_big        |   3,000 |      1.77ms |     1.76ms |     errors |     errors |     2.06ms |  **1.72ms** |     1.92ms |     1.92ms |     1.97ms |     2.21ms |
| stream_big        |   5,000 |      2.39ms |     2.29ms |     errors |     errors |     3.62ms |  **2.19ms** |     3.03ms |     4.48ms |     3.55ms |     9.61ms |
| stream_big        |   7,000 | **12.43ms** |    15.05ms |     errors |     errors |   452.22ms |     19.45ms |    61.58ms |   264.06ms |   103.01ms | overloaded |
| sse               |   6,000 |  **1.03ms** |     1.04ms |     1.77ms |          - |          - |           - |     1.28ms |     1.33ms |          - |     1.12ms |
| sse               |  10,000 |      1.80ms | **1.63ms** |    52.66ms |          - |          - |           - |     4.65ms |     4.83ms |          - |     3.04ms |
| sse               |  14,000 |  **5.30ms** |     5.65ms | overloaded |          - |          - |           - | overloaded |   366.72ms |          - |    16.98ms |
| sse_small         |   3,000 |      2.42ms |     2.33ms |     3.48ms |          - |          - |           - | **2.29ms** |     3.75ms |          - |     2.62ms |
| sse_small         |   5,000 |      7.75ms |     8.28ms | overloaded |          - |          - |           - | **7.58ms** | overloaded |          - |    33.74ms |
| sse_small         |   7,000 |  overloaded | overloaded | overloaded |          - |          - |           - | overloaded | overloaded |          - | overloaded |
| sse_big           |   3,000 |      2.25ms | **2.21ms** |     2.57ms |          - |          - |           - | overloaded | overloaded |          - |     2.35ms |
| sse_big           |   5,000 |      9.18ms | **6.50ms** |    20.36ms |          - |          - |           - | overloaded | overloaded |          - |    12.51ms |
| sse_big           |   7,000 |  overloaded | overloaded | overloaded |          - |          - |           - | overloaded | overloaded |          - | overloaded |

### HTTP/2

| case              |   req/s |        ewe@9 |       ewe@8 |     bandit |  roadrunner | chatterbox |     cowboy |
| ----------------- | ------: | -----------: | ----------: | ---------: | ----------: | ---------: | ---------: |
| hello             |  50,000 |        242us |   **211us** |     3.30ms |       243us |     errors |      636us |
| hello             | 100,000 |        603us |   **206us** | overloaded |      2.88ms |     errors |    12.53ms |
| hello             | 150,000 |   **4.41ms** |     18.79ms | overloaded |      7.41ms |     errors | overloaded |
| hello_headers     |  50,000 |        370us |   **257us** |     6.03ms |      2.66ms |     errors |     8.24ms |
| hello_headers     | 100,000 |   **5.93ms** |     26.04ms | overloaded |     20.74ms |     errors | overloaded |
| hello_headers     | 150,000 | **141.25ms** |  overloaded | overloaded |  overloaded |     errors | overloaded |
| echo_1kb          |  50,000 |    **240us** |       337us |     4.24ms |       301us |     errors |     errors |
| echo_1kb          | 100,000 |       4.55ms |      8.62ms | overloaded |  **3.75ms** |     errors |     errors |
| echo_1kb          | 150,000 |      70.56ms |  overloaded | overloaded | **40.53ms** |     errors |     errors |
| echo_1kb_headers  |  40,000 |        401us |   **354us** |     3.26ms |       551us |     errors |     6.87ms |
| echo_1kb_headers  |  80,000 |       9.40ms |     39.89ms | overloaded |  **6.60ms** |     errors |     errors |
| echo_1kb_headers  | 120,000 |   overloaded |  overloaded | overloaded |  overloaded |     errors |     errors |
| echo_10kb         |  20,000 |        319us |       283us |      386us |   **211us** |     errors |      634us |
| echo_10kb         |  60,000 |    **343us** |       578us | overloaded |      1.46ms |     errors |     errors |
| echo_10kb         | 100,000 |      13.96ms |  overloaded | overloaded |  **4.99ms** |     errors |     errors |
| echo_chunked_10kb |  40,000 |    **340us** |       343us |     3.62ms |       469us |     errors |     errors |
| echo_chunked_10kb |  70,000 |    **482us** |       677us | overloaded |      2.61ms |     errors |     errors |
| echo_chunked_10kb | 100,000 |      19.30ms |  overloaded | overloaded |  **5.69ms** |     errors |     errors |
| file_tiny         |  20,000 |       1.39ms |  **1.28ms** |     2.45ms |      2.19ms |     errors |     1.98ms |
| file_tiny         |  40,000 |       4.04ms |  **2.55ms** | overloaded |  overloaded |     errors | overloaded |
| file_tiny         |  60,000 |   **8.60ms** |     38.86ms | overloaded |  overloaded |     errors | overloaded |
| file_small        |  15,000 |       1.40ms |   **921us** |     2.60ms |      3.05ms |     errors | overloaded |
| file_small        |  30,000 |       7.16ms |  **3.47ms** |   462.98ms |  overloaded |     errors | overloaded |
| file_small        |  45,000 |   overloaded | **93.66ms** | overloaded |  overloaded |     errors | overloaded |
| file_big          |     500 |       4.09ms |  overloaded | **3.36ms** |      5.64ms |     errors | overloaded |
| file_big          |   1,000 |      58.96ms |  overloaded | overloaded | **15.00ms** |     errors | overloaded |
| file_big          |   1,500 |   overloaded |  overloaded | overloaded |  overloaded |     errors | overloaded |
| stream            |  20,000 |        328us |       341us |      459us |   **244us** |          - |      375us |
| stream            |  40,000 |        406us |   **360us** |     6.45ms |       572us |          - |      640us |
| stream            |  60,000 |       1.15ms |   **617us** | overloaded |      3.29ms |          - |     4.95ms |
| stream_small      |   3,000 |       3.07ms |      2.71ms |     5.19ms |  **2.29ms** |          - |     2.37ms |
| stream_small      |   5,000 |      25.61ms |    203.97ms | overloaded | **18.98ms** |          - |    54.45ms |
| stream_small      |   7,000 |  **49.14ms** |  overloaded | overloaded |  overloaded |          - | overloaded |
| stream_big        |   3,000 |       2.52ms |      2.54ms |     3.33ms |  **2.12ms** |          - |     2.24ms |
| stream_big        |   5,000 |      16.74ms |     12.80ms |   260.80ms |      7.68ms |          - | **6.16ms** |
| stream_big        |   7,000 |  **41.97ms** |  overloaded | overloaded |  overloaded |          - | overloaded |
| sse               |   6,000 |       2.28ms |      2.58ms |          - |  **1.25ms** |          - |     1.78ms |
| sse               |  10,000 |      15.81ms |    602.37ms |          - |  **2.65ms** |          - |     9.42ms |
| sse               |  14,000 |  **36.40ms** |  overloaded |          - |     38.22ms |          - | overloaded |
| sse_small         |   3,000 |      11.04ms |     16.81ms |          - |  **2.73ms** |          - |     4.86ms |
| sse_small         |   5,000 |      67.42ms |  overloaded |          - | **65.07ms** |          - | overloaded |
| sse_small         |   7,000 | **116.32ms** |  overloaded |          - |  overloaded |          - | overloaded |
| sse_big           |   3,000 |       5.97ms |  **4.67ms** |          - |  overloaded |          - | overloaded |
| sse_big           |   5,000 | **225.09ms** |  overloaded |          - |  overloaded |          - | overloaded |
| sse_big           |   7,000 |   overloaded |  overloaded |          - |  overloaded |          - | overloaded |

`chatterbox` could not sustain any of the fixed rates, answering a few hundred
requests per second at most. Its connections crashed whenever a client closed
the socket first. Under the constant load the memory grew until the kernel
killed it during the `file_big` case.

## Legend

- `~` the runs for the median were more than 5% apart.
- `stalled` none of the connections completed a second request.
- `overloaded` the server answered less than 98% of the offered rate.
- `errors` failed requests or non-2xx responses.
- `-` the server does not support the case. `chatterbox` stopped after `file_big` 
  in the latency run.
