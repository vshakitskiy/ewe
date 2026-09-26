![ewe](https://raw.githubusercontent.com/vshakitskiy/ewe/mistress/public/banner.jpg)

# 🐑 ewe

ewe [/juː/] - fluffy HTTP/1 and HTTP/2 web server for Gleam.

[![Package Version](https://img.shields.io/hexpm/v/ewe)](https://hex.pm/packages/ewe)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/ewe/)

## Contents

- [Installation](#installation)
- [Usage](#usage)
  - [Getting Started](#getting-started)
  - [HTTPS](#https)
  - [HTTP/2](#http2)
  - [Sending a Response](#sending-a-response)
  - [Reading the Request Body](#reading-the-request-body)
  - [Streaming Bodies](#streaming-bodies)
  - [Serving Files](#serving-files)
  - [Client Address](#client-address)
  - [WebSocket](#websocket)
  - [Server-Sent Events](#server-sent-events)
  - [Connection Limits and Timeouts](#connection-limits-and-timeouts)
  - [Running Under Supervision](#running-under-supervision)
  - [Running as an OTP Application](#running-as-an-otp-application)
  - [Graceful Shutdown](#graceful-shutdown)
- [Examples](#examples)
- [API Reference](#api-reference)

Most section headings are links, each one opening the runnable example it is
based on.

<h2 id="installation">Installation</h2>

```sh
gleam add ewe@8 gleam_erlang gleam_otp gleam_http logging
```

<h2 id="usage">Usage</h2>

<h3 id="getting-started"><a target="_blank" href="https://github.com/vshakitskiy/ewe/blob/mistress/examples/src/getting_started.gleam">Getting Started</a></h3>

A handler takes a 
[`request.Request(ewe.Connection)`](https://hexdocs.pm/ewe/ewe.html#Connection)
and returns a 
[`response.Response(ewe.Body)`](https://hexdocs.pm/ewe/ewe.html#Body). The 
request argument the handler receives contains the connection, which you pass to 
[`ewe.read_body`](https://hexdocs.pm/ewe/ewe.html#read_body) to read the body, 
or to [`ewe.file`](https://hexdocs.pm/ewe/ewe.html#file) and
[`ewe.websocket`](https://hexdocs.pm/ewe/ewe.html#websocket).

To listen on a Unix domain socket instead of a port, use 
[`ewe.unix`](https://hexdocs.pm/ewe/ewe.html#unix).
[`ewe.listening_random`](https://hexdocs.pm/ewe/ewe.html#listening_random) lets the
OS pick a free port and [`ewe.start`](https://hexdocs.pm/ewe/ewe.html#start)
returns the address as the actor's started data. Name the server with 
[`ewe.named`](https://hexdocs.pm/ewe/ewe.html#named) to look that address later 
with [`ewe.get_server_info`](https://hexdocs.pm/ewe/ewe.html#get_server_info).

```gleam
import ewe
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  let assert Ok(_) =
    ewe.new(handler: handle_request)
    |> ewe.bind(to: "0.0.0.0")
    |> ewe.listening(on: 8080)
    |> ewe.start

  process.sleep_forever()
}

fn handle_request(
  _request: request.Request(ewe.Connection),
) -> response.Response(ewe.Body) {
  // Give every body a `content-type`. ewe writes `content-length` and
  // `transfer-encoding` itself, ypu don't need to specify those headers.
  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(ewe.Text("Hello, World!"))
}
```

<h3 id="https"><a target="_blank" href="https://github.com/vshakitskiy/ewe/blob/mistress/examples/src/https.gleam">HTTPS</a></h3>

Enable TLS with [`ewe.with_tls`](https://hexdocs.pm/ewe/ewe.html#with_tls), which
takes the certificate source as a [`ewe.Tls`](https://hexdocs.pm/ewe/ewe.html#Tls)
value. The certificate and key are checked when the server starts and
`ewe.start` returns an error if they are missing or invalid.

```gleam
ewe.new(handler: handle_request)
|> ewe.bind(to: "0.0.0.0")
|> ewe.listening(on: 8080)
// Certificate and key files on disk.
|> ewe.with_tls(ewe.Disk("priv/localhost.crt", "priv/localhost.key"))
// Or PEM already in memory: ewe.Pem(cert, key)
// Or DER in memory:         ewe.Der(cert, key, ewe.RsaPrivateKey)
|> ewe.start
```

To refuse clients that do not present a certificate signed by an authority you
name, add [`ewe.with_client_verification`](https://hexdocs.pm/ewe/ewe.html#with_client_verification).
It needs TLS to be configured.

```gleam
|> ewe.with_tls(ewe.Disk("priv/localhost.crt", "priv/localhost.key"))
|> ewe.with_client_verification(ewe.CaCertFile("priv/ca.crt"))
```

<h3 id="http2">HTTP/2</h3>

HTTP/2 is always enabled. Over TLS it is offered through ALPN, and a client that 
does not choose `h2` is served HTTP/1.1. A cleartext connection is served as
HTTP/2 when it starts with the HTTP/2 preface.

<h3 id="sending-a-response"><a target="_blank" href="https://github.com/vshakitskiy/ewe/blob/mistress/examples/src/sending_response.gleam">Sending a Response</a></h3>

A response body is one of the [`ewe.Body`](https://hexdocs.pm/ewe/ewe.html#Body)
variants. `Text`, `Bytes` and `Empty` are built by hand, the rest come from
[`ewe.file`](https://hexdocs.pm/ewe/ewe.html#file),
[`ewe.stream_response`](https://hexdocs.pm/ewe/ewe.html#stream_response),
[`ewe.sse`](https://hexdocs.pm/ewe/ewe.html#sse) and
[`ewe.websocket`](https://hexdocs.pm/ewe/ewe.html#websocket).

```gleam
import ewe
import gleam/bytes_tree
import gleam/crypto
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/result

fn handle_request(
  request: request.Request(ewe.Connection),
) -> response.Response(ewe.Body) {
  case request.path_segments(request) {
    ["hello", name] -> {
      // Text for text responses.
      response.new(200)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.Text("Hello, " <> name <> "!"))
    }
    ["bytes", amount] -> {
      // Bytes for binary responses built from a `BytesTree`.
      let body =
        int.parse(amount)
        |> result.unwrap(0)
        |> crypto.strong_random_bytes
        |> bytes_tree.from_bit_array
        |> ewe.Bytes

      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(body)
    }
    _segments ->
      // Empty for responses with no body like 404 or 204.
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}
```

<h3 id="reading-the-request-body"><a target="_blank" href="https://github.com/vshakitskiy/ewe/blob/mistress/examples/src/reading_body.gleam">Reading the Request Body</a></h3>

[`ewe.read_body`](https://hexdocs.pm/ewe/ewe.html#read_body) reads the whole body
into memory and fails with `ewe.BodyTooLarge` if it is over `limit` bytes.
Trailer fields sent after the body are added to the returned request's headers.

```gleam
fn handle_request(
  request: request.Request(ewe.Connection),
) -> response.Response(ewe.Body) {
  let content_type =
    request.get_header(request, "content-type")
    |> result.unwrap("application/octet-stream")

  case ewe.read_body(request, limit: 10_240) {
    Ok(req) ->
      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_body(ewe.Bytes(bytes_tree.from_bit_array(req.body)))
    Error(ewe.BodyTooLarge) ->
      response.new(413)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.Text("Body too large"))
    Error(ewe.InvalidBody) ->
      response.new(400)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.Text("Invalid request"))
  }
}
```

On HTTP/1, a body the handler did not read is read and discarded after the
response, so the connection can be reused. A body over `auto_drain_limit` causes
the connection to be closed instead.

<h3 id="streaming-bodies"><a target="_blank" href="https://github.com/vshakitskiy/ewe/blob/mistress/examples/src/streaming_bodies.gleam">Streaming Bodies</a></h3>

[`ewe.read_body_chunk`](https://hexdocs.pm/ewe/ewe.html#read_body_chunk) reads
the body a piece at a time, at most `max_chunk_bytes` per call, instead of all 
at once. Each [`ewe.Chunk`](https://hexdocs.pm/ewe/ewe.html#ReadEvent) comes with
the request to pass to the next call.

To send a body in pieces use 
[`ewe.stream_response`](https://hexdocs.pm/ewe/ewe.html#stream_response).
Its function gets an 
[`ewe.ResponseWriter`](https://hexdocs.pm/ewe/ewe.html#ResponseWriter),
writes with [`ewe.send_chunk`](https://hexdocs.pm/ewe/ewe.html#send_chunk) and
must end the response with 
[`ewe.finish_chunk`](https://hexdocs.pm/ewe/ewe.html#finish_chunk) or 
[`ewe.finish_response`](https://hexdocs.pm/ewe/ewe.html#finish_response). It 
runs in the process serving the request.

```gleam
fn handle_stream(
  req: request.Request(ewe.Connection),
  max_chunk_bytes: Int,
) -> response.Response(ewe.Body) {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("application/octet-stream")

  response.new(200)
  |> response.set_header("content-type", content_type)
  |> ewe.stream_response(echo_body(req, _, max_chunk_bytes))
}

// Read the request body one chunk at a time and write each one back out.
//
fn echo_body(
  req: request.Request(ewe.Connection),
  writer: ewe.ResponseWriter,
  max_chunk_bytes: Int,
) -> Result(Nil, ewe.SendError) {
  case ewe.read_body_chunk(req, max_chunk_bytes:, limit: 10_485_760) {
    Ok(ewe.Chunk(data:, request:)) -> {
      use writer <- result.try(ewe.send_chunk(writer, data))
      echo_body(request, writer, max_chunk_bytes)
    }
    Ok(ewe.Done(_request)) -> ewe.finish_response(writer)
    Error(_body_error) -> ewe.finish_response(writer)
  }
}
```

<h3 id="serving-files"><a target="_blank" href="https://github.com/vshakitskiy/ewe/blob/mistress/examples/src/serving_files.gleam">Serving Files</a></h3>

[`ewe.file`](https://hexdocs.pm/ewe/ewe.html#file) prepares a file as a response 
body. Pass the request's body first since how the file is sent depends on the 
connection. `offset` and `limit` send only part of the file.

```gleam
case ewe.file(request.body, resolved, offset: None, limit: None) {
  Ok(file) ->
    response.new(200)
    |> response.set_header("content-type", "application/octet-stream")
    |> response.set_body(file)
  Error(_error) -> not_found()
}
```

<h3 id="client-address"><a target="_blank" href="https://github.com/vshakitskiy/ewe/blob/mistress/examples/src/client_info.gleam">Client Address</a></h3>

[`ewe.get_client_info`](https://hexdocs.pm/ewe/ewe.html#get_client_info) returns
the address the request came from as an
[`ewe.SocketAddress`](https://hexdocs.pm/ewe/ewe.html#SocketAddress). The 
address is read once when the client connects.

```gleam
fn describe_client(connection: ewe.Connection) -> String {
  case ewe.get_client_info(connection) {
    ewe.TcpSocketAddress(ip_address:, port:) -> {
      let host = case ip_address {
        ewe.IpV6(..) -> "[" <> ewe.ip_address_to_string(ip_address) <> "]"
        ewe.IpV4(..) -> ewe.ip_address_to_string(ip_address)
      }

      host <> ":" <> int.to_string(port)
    }
    ewe.UnixSocketAddress(path: "") -> "unix socket"
    ewe.UnixSocketAddress(path:) -> "unix:" <> path
  }
}
```

Behind a proxy this is the proxy's address rather than the browser's. The one the
proxy puts in `x-forwarded-for` is the address to use there. MDN's
[security and privacy concerns](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/X-Forwarded-For#security_and_privacy_concerns)
is worth a read before you rely on it for anything since an address taken on
trust is an address anyone can choose.

<h3 id="websocket"><a target="_blank" href="https://github.com/vshakitskiy/ewe/blob/mistress/examples/src/websocket.gleam">WebSocket</a></h3>

[`ewe.websocket`](https://hexdocs.pm/ewe/ewe.html#websocket) turns a request into
a WebSocket. A request that is not a valid handshake is answered with a 400 and
your handler never runs. Frames from the client and messages from the rest of
your program arrive as [`ewe.WebsocketMessage`](https://hexdocs.pm/ewe/ewe.html#WebsocketMessage)
values. Answer them with [`ewe.send_text_frame`](https://hexdocs.pm/ewe/ewe.html#send_text_frame)
or [`ewe.send_binary_frame`](https://hexdocs.pm/ewe/ewe.html#send_binary_frame)
and say what happens next with
[`ewe.Next`](https://hexdocs.pm/ewe/ewe.html#Next).

On HTTP/1 the request is the usual `Upgrade: websocket` handshake and on HTTP/2
it is the extended `CONNECT` of
[RFC 8441](https://www.rfc-editor.org/rfc/rfc8441) which ewe advertises with
`SETTINGS_ENABLE_CONNECT_PROTOCOL`. To keep WebSockets on HTTP/1 only, turn it
off:

```gleam
|> ewe.with_http2(ewe.Http2Options(..ewe.default_http2_options(), websocket: False))
```

```gleam
fn handle_topic(
  req: request.Request(ewe.Connection),
  pubsub: Subject(pubsub.Message(Broadcast)),
  topic: String,
) -> response.Response(ewe.Body) {
  ewe.websocket(
    request: req,
    // Called once. The selector is where you add whatever the rest of your
    // program sends to this connection.
    on_init: fn(_conn, selector) {
      let client = process.new_subject()
      pubsub.subscribe(pubsub, topic:, client:)

      let state = WebsocketState(pubsub:, topic:, client:)
      let selector = process.select(selector, client)

      #(state, selector)
    },
    handler: handle_websocket_message,
    // Called once however the WebSocket ended.
    on_close: fn(_conn, state) {
      pubsub.unsubscribe(state.pubsub, topic: state.topic, client: state.client)
    },
  )
}

fn handle_websocket_message(
  conn: ewe.WebsocketConnection,
  state: WebsocketState,
  message: ewe.WebsocketMessage(Broadcast),
) -> ewe.Next(WebsocketState, Broadcast) {
  case message {
    ewe.TextFrame(text) -> {
      pubsub.publish(state.pubsub, topic: state.topic, message: Text(text))
      ewe.continue(state)
    }

    ewe.BinaryFrame(data) -> {
      pubsub.publish(state.pubsub, topic: state.topic, message: Bytes(data))
      ewe.continue(state)
    }

    // A message from the rest of the program.
    ewe.UserMessage(broadcast) -> {
      let sent = case broadcast {
        Text(text) -> ewe.send_text_frame(conn, text)
        Bytes(data) -> ewe.send_binary_frame(conn, data)
      }

      case sent {
        Ok(Nil) -> ewe.continue(state)
        Error(_send_error) ->
          ewe.stop_abnormal("Failed to send a frame")
      }
    }
  }
}
```

Ping and pong frames are answered by the server and never reach the handler. To
start the closing handshake yourself, return
[`ewe.send_close_frame`](https://hexdocs.pm/ewe/ewe.html#send_close_frame) with a
[`ewe.CloseReason`](https://hexdocs.pm/ewe/ewe.html#CloseReason). No frame can be
sent after it.

<h3 id="server-sent-events"><a target="_blank" href="https://github.com/vshakitskiy/ewe/blob/mistress/examples/src/sse.gleam">Server-Sent Events</a></h3>

[`ewe.sse`](https://hexdocs.pm/ewe/ewe.html#sse) turns a response into an SSE
stream which runs until the handler stops it or the client disconnects. Like a
WebSocket, `on_init` receives a selector to add whatever the rest of your program
sends to this stream, `handler` is called for each message it picks up and
`on_close` runs once the stream ends. The `content-type` and `cache-control`
headers the stream needs are set by ewe.

```gleam
response.new(200)
|> ewe.sse(
  on_init: fn(_conn, selector) {
    let client = process.new_subject()
    pubsub.subscribe(pubsub, topic:, client:)

    #(client, process.select(selector, client))
  },
  handler: fn(conn, client, message) {
    case ewe.send_event(conn, ewe.event(message)) {
      Ok(Nil) -> ewe.continue(client)
      Error(_send_error) -> ewe.stop()
    }
  },
  on_close: fn(_conn, client) {
    pubsub.unsubscribe(pubsub, topic:, client:)
  },
)
```

An event is built with [`ewe.event`](https://hexdocs.pm/ewe/ewe.html#event) and
can carry a name, an id and a reconnection delay through
[`ewe.event_name`](https://hexdocs.pm/ewe/ewe.html#event_name),
[`ewe.event_id`](https://hexdocs.pm/ewe/ewe.html#event_id) and
[`ewe.event_retry`](https://hexdocs.pm/ewe/ewe.html#event_retry).
[`ewe.comment`](https://hexdocs.pm/ewe/ewe.html#comment) sends something clients
ignore which is the usual way to keep an idle stream from being closed by a
proxy.

<h3 id="connection-limits-and-timeouts">Connection Limits and Timeouts</h3>

Every connection is held to a set of limits and timeouts. Start with
[`ewe.default_http1_options`](https://hexdocs.pm/ewe/ewe.html#default_http1_options)
or [`ewe.default_http2_options`](https://hexdocs.pm/ewe/ewe.html#default_http2_options),
update the fields you care about and hand the result to
[`ewe.with_http1`](https://hexdocs.pm/ewe/ewe.html#with_http1) or
[`ewe.with_http2`](https://hexdocs.pm/ewe/ewe.html#with_http2). Sizes are in bytes
and timeouts in milliseconds.

```gleam
let http1 =
  ewe.Http1Options(
    ..ewe.default_http1_options(),
    // Refuse a request carrying more than 50 header fields with a 431.
    max_headers: 50,
    // Close a connection that sits idle for 30 seconds.
    idle_timeout: 30_000,
  )

let http2 =
  ewe.Http2Options(
    ..ewe.default_http2_options(),
    // Cap how many streams a client may have open at once.
    max_concurrent_streams: Some(100),
    // Trip a GOAWAY sooner on a client resetting streams in bulk.
    rapid_reset_threshold: 50,
  )

ewe.new(handler: handle_request)
|> ewe.with_http1(http1)
|> ewe.with_http2(http2)
|> ewe.start
```

[`ewe.Http1Options`](https://hexdocs.pm/ewe/ewe.html#Http1Options):

| Field | Default | What it does |
| --- | --- | --- |
| `max_request_line` | `8192` | Longer request lines are refused with a 414. |
| `max_header_line` | `8192` | Longer header lines are refused with a 431. |
| `max_headers` | `100` | Requests carrying more header fields are refused with a 431. |
| `max_chunk_size_line` | `128` | Longer chunk size lines in a chunked body are refused with a 413. |
| `idle_timeout` | `10_000` | How long a connection may stay idle before it is closed. |
| `body_read_timeout` | `10_000` | How long `read_body` and `read_body_chunk` wait for more of the body before failing. |
| `auto_drain_limit` | `1_048_576` | The largest unread body discarded so the connection can be reused. A larger body closes the connection. |
| `auto_drain_chunk_bytes` | `65_536` | How many bytes are read at a time while an unread body is discarded. |

[`ewe.Http2Options`](https://hexdocs.pm/ewe/ewe.html#Http2Options):

| Field | Default | What it does |
| --- | --- | --- |
| `max_concurrent_streams` | `Some(100)` | How many streams a client may have open at once. |
| `initial_window_size` | `262_144` | How much request body a client may send on a new stream before the server allows more. |
| `max_frame_size` | `16_384` | Largest frame accepted, between 16384 and 16777215. |
| `max_header_list_size` | `Some(32_768)` | Requests with larger decoded headers are answered with a 431. |
| `header_table_size` | `4096` | Size of the HPACK table used to decode request headers. |
| `max_continuation_frames` | `100` | How many CONTINUATION frames one header block may use. |
| `max_header_block_bytes` | `65_536` | Largest header block across its HEADERS and CONTINUATION frames. |
| `rapid_reset_window` | `10_000` | The time over which `rapid_reset_threshold` counts resets. |
| `rapid_reset_threshold` | `100` | Most streams reset while their handler is still running, within the window. More resets close the connection. Guards against Rapid Reset (CVE-2023-44487) and MadeYouReset (CVE-2025-8671). |
| `handshake_timeout` | `10_000` | How long the client has to send its SETTINGS and acknowledge ours. |
| `idle_timeout` | `60_000` | How long a connection may stay idle before it is sent GOAWAY and closed. |
| `recv_window_low_water_mark` | `65_536` | When a client can send only this much more on a stream, the server lets it send more. |
| `recv_window_high_water_mark` | `262_144` | How much request body a stream holds before the handler reads it. |
| `websocket` | `True` | Whether a client may open a WebSocket over HTTP/2 with the extended `CONNECT` of RFC 8441. |
| `send_buffer_limit` | `1_048_576` | How much a streamed body, SSE or WebSocket may queue for a slow client before the next write waits. |
| `file_read_threshold` | `1_048_576` | Files up to this size are read into memory, larger ones are sent from disk. |
| `body_read_timeout` | `10_000` | How long `read_body` and `read_body_chunk` wait for more of the body. |

Each read from the socket takes in at most 
[`ewe.buffer_size`](https://hexdocs.pm/ewe/ewe.html#buffer_size) bytes, 64 KiB 
by default. A larger size means fewer reads for clients that send large bodies.

<h3 id="running-under-supervision">Running Under Supervision</h3>

[`ewe.start`](https://hexdocs.pm/ewe/ewe.html#start) runs the server on its own.
When it belongs to a supervision tree next to the rest of your program use
[`ewe.supervised`](https://hexdocs.pm/ewe/ewe.html#supervised) instead, which
returns a child specification.

```gleam
supervisor.new(supervisor.OneForAll)
|> supervisor.add(pubsub.worker(pubsub_name))
|> supervisor.add(
  ewe.new(handler:)
  |> ewe.bind(to: "0.0.0.0")
  |> ewe.listening(on: 8080)
  |> ewe.supervised,
)
|> supervisor.start
```

The line printed on startup comes from [`ewe.on_start`](https://hexdocs.pm/ewe/ewe.html#on_start),
which receives the scheme and the address the server bound to. Replace it to log
it your own way or silence it with [`ewe.quiet`](https://hexdocs.pm/ewe/ewe.html#quiet).

<h3 id="running-as-an-otp-application">Running as an OTP Application</h3>

The examples start the server straight from `main` with a `let assert`, which is
the shortest thing that works while you are trying ewe out. A service is better
off letting the [OTP application](https://www.erlang.org/doc/apps/kernel/application.html)
controller own the supervision tree: it starts before anything else runs, it
brings the tree down in order on shutdown and it is what a release expects.

Point `application_start_module` at a module exporting `start/2` and `stop/1`:

```toml
[erlang]
application_start_module = "my_app"
```

`start` returns the top supervisor's pid, which the application controller then
watches.

```gleam
import gleam/erlang/atom
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor

/// The Erlang/OTP application start callback. Starts the top supervisor and
/// hands its pid back to the application controller.
pub fn start(_type: a, _args: b) -> Result(process.Pid, actor.StartError) {
  case
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(
      ewe.new(handler: handle_request)
      |> ewe.bind(to: "0.0.0.0")
      |> ewe.listening(on: 8080)
      |> ewe.supervised,
    )
    |> supervisor.start
  {
    Ok(actor.Started(pid:, ..)) -> Ok(pid)
    Error(reason) -> Error(reason)
  }
}

/// The Erlang/OTP application stop callback, called once every process in the
/// tree is down. Any final clean up goes here.
pub fn stop(_state: a) -> atom.Atom {
  atom.create("ok")
}

/// The application is already running by the time this is called, so all main
/// has left to do is keep the node alive.
pub fn main() {
  process.sleep_forever()
}
```

> [!NOTE]
> `main` still has to sleep. `gleam run` boots the application and then calls it,
> so without it the node exits as soon as it returns.

<h3 id="graceful-shutdown">Graceful Shutdown</h3>

> [!NOTE]
> This only happens when the server is in the supervision tree of an OTP
> application as in [Running as an OTP Application](#running-as-an-otp-application).
> A server started from `main`, even under a supervisor, is killed with the VM
> on SIGTERM.

When OTP stops the server, each connection gets to finish before it is closed.
HTTP/1 connections finish the request they are serving, WebSockets are sent a
close frame with code 1001 (going away), SSE streams end, and HTTP/2 connections
send GOAWAY and wait for their open streams.
[`ewe.shutdown_timeout`](https://hexdocs.pm/ewe/ewe.html#shutdown_timeout) sets
how long that may take, 15 seconds by default.

```gleam
ewe.new(handler: handle_request)
|> ewe.shutdown_timeout(30_000)
|> ewe.supervised
```

<h2 id="examples">Examples</h2>

Most sections above link to a runnable example. They live in [examples](examples/).

<h2 id="api-reference">API Reference</h2>

For detailed API documentation, see [hexdocs.pm/ewe](https://hexdocs.pm/ewe/ewe.html).
