![ewe](https://raw.githubusercontent.com/vshakitskiy/ewe/v5/public/banner.jpg)

# 🐑 ewe

ewe [/juː/] - fluffy HTTP/1 and HTTP/2 web server for Gleam.

[![Package Version](https://img.shields.io/hexpm/v/ewe)](https://hex.pm/packages/ewe)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/ewe/)

## Contents

- [Installation](#installation)
- [Getting Started](#getting-started)
- [Usage](#usage)
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
- [Examples](#examples)
- [API Reference](#api-reference)

Most section headings are links, each one opening the runnable example it is
based on.

## Installation

```sh
gleam add ewe@5 gleam_erlang gleam_otp gleam_http logging
```

## Getting Started

```gleam
import ewe
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  // The acceptor pool wires the listener and the connection factory together
  // through process names. Create them where your program starts and pass them
  // in here.
  //
  let listener_name = process.new_name("listener_name")
  let connection_factory_name = process.new_name("connection_factory_name")

  let assert Ok(_) =
    ewe.new(listener_name:, connection_factory_name:, handler: handle_request)
    |> ewe.bind(to: "0.0.0.0")
    |> ewe.listening(on: 8080)
    |> ewe.start

  process.sleep_forever()
}

fn handle_request(
  _request: request.Request(ewe.Connection),
) -> response.Response(ewe.Body) {
  // When sending a body it is important to include a `content-type` header.
  // You never set `content-length` or `transfer-encoding` yourself, ewe frames
  // the response and writes them for you.
  //
  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(ewe.Text("Hello, World!"))
}
```

A handler takes a [`request.Request(ewe.Connection)`](https://hexdocs.pm/ewe/ewe.html#Connection)
and returns a [`response.Response(ewe.Body)`](https://hexdocs.pm/ewe/ewe.html#Body).
The connection carried by the request is what [`ewe.read_body`](https://hexdocs.pm/ewe/ewe.html#read_body),
[`ewe.file`](https://hexdocs.pm/ewe/ewe.html#file) and [`ewe.websocket`](https://hexdocs.pm/ewe/ewe.html#websocket)
work on.

Instead of a port you can bind a unix domain socket with [`ewe.unix`](https://hexdocs.pm/ewe/ewe.html#unix),
or let the OS pick a free port with [`ewe.listening_random`](https://hexdocs.pm/ewe/ewe.html#listening_random)
and ask for the one it picked with [`ewe.get_server_info`](https://hexdocs.pm/ewe/ewe.html#get_server_info).

## Usage

### [HTTPS](examples/src/https.gleam)

Enable TLS with [`ewe.with_tls`](https://hexdocs.pm/ewe/ewe.html#with_tls), which
takes the certificate source as a [`ewe.Tls`](https://hexdocs.pm/ewe/ewe.html#Tls)
value. The certificate and key are validated on startup and the server crashes if
they are missing or invalid.

```gleam
ewe.new(listener_name:, connection_factory_name:, handler: handle_request)
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

### HTTP/2

HTTP/2 is always enabled on ewe. Over TLS ewe offers it through ALPN and a plain
connection is served as HTTP/2 when it opens with the HTTP/2 preface which is
what a client with prior knowledge sends. An `Upgrade: h2c` request is not
negotiated, it is answered as HTTP/1.1.

> [!NOTE]
> Extended CONNECT is not negotiated yet, so WebSockets over HTTP/2 are not
> supported.

### [Sending a Response](examples/src/sending_response.gleam)

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

### [Reading the Request Body](examples/src/reading_body.gleam)

[`ewe.read_body`](https://hexdocs.pm/ewe/ewe.html#read_body) reads the whole body
into memory up to `limit` bytes. Trailer fields of a chunked request are appended
to the returned request's headers.

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

A body the handler never read is drained by the server so the connection can be
reused. One larger than `auto_drain_limit` closes the connection instead.

### [Streaming Bodies](examples/src/streaming_bodies.gleam)

[`ewe.read_body_chunk`](https://hexdocs.pm/ewe/ewe.html#read_body_chunk) pulls up
to `max_chunk_bytes` per call rather than buffering everything. Each
[`ewe.Chunk`](https://hexdocs.pm/ewe/ewe.html#ReadEvent) carries the request to
feed into the next call.

Going the other way, [`ewe.stream_response`](https://hexdocs.pm/ewe/ewe.html#stream_response)
turns a response into a streamed one. Its handler owns an
[`ewe.ResponseWriter`](https://hexdocs.pm/ewe/ewe.html#ResponseWriter) and must
end by calling [`ewe.finish_chunk`](https://hexdocs.pm/ewe/ewe.html#finish_chunk)
or [`ewe.finish_response`](https://hexdocs.pm/ewe/ewe.html#finish_response) since
that is what closes the stream. The callback runs in the same connection process.

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

### [Serving Files](examples/src/serving_files.gleam)

[`ewe.file`](https://hexdocs.pm/ewe/ewe.html#file) prepares a file as a response
body so you never read one in yourself. `offset` and `limit` serve a byte range,
which is what a range request needs. It takes the connection so it is the
request's body you pass in first.

```gleam
case ewe.file(request.body, resolved, offset: None, limit: None) {
  Ok(file) ->
    response.new(200)
    |> response.set_header("content-type", "application/octet-stream")
    |> response.set_body(file)
  Error(_error) -> not_found()
}
```

> [!NOTE]
> On HTTP/1 `ewe.file` keeps the file open until the response is written, so put
> it on a response you go on to return.

### [Client Address](examples/src/client_info.gleam)

[`ewe.get_client_info`](https://hexdocs.pm/ewe/ewe.html#get_client_info) reads the
address a request came from off its connection as a
[`ewe.SocketAddress`](https://hexdocs.pm/ewe/ewe.html#SocketAddress). It fails
only when the socket is already gone.

```gleam
fn describe_client(connection: ewe.Connection) -> String {
  case ewe.get_client_info(connection) {
    Ok(ewe.TcpSocketAddress(ip_address:, port:)) -> {
      // An IPv6 address is bracketed so the port stays readable next to the
      // colons the address itself is full of.
      let host = case ip_address {
        ewe.IpV6(..) -> "[" <> ewe.ip_address_to_string(ip_address) <> "]"
        ewe.IpV4(..) -> ewe.ip_address_to_string(ip_address)
      }

      host <> ":" <> int.to_string(port)
    }
    Ok(ewe.UnixSocketAddress(path: "")) -> "unix socket"
    Ok(ewe.UnixSocketAddress(path:)) -> "unix:" <> path
    Error(Nil) -> "unknown"
  }
}
```

Behind a proxy this is the proxy's address rather than the browser's. The one the
proxy puts in `x-forwarded-for` is the address to use there but only when the
proxy is yours, since any client can send that header itself.

### [WebSocket](examples/src/websocket.gleam)

[`ewe.websocket`](https://hexdocs.pm/ewe/ewe.html#websocket) turns a request into
a WebSocket. A request that is not a valid handshake is answered with a 400 and
your handler never runs. Frames from the client and messages from the rest of
your program arrive as [`ewe.WebsocketMessage`](https://hexdocs.pm/ewe/ewe.html#WebsocketMessage)
values. Answer them with [`ewe.send_text_frame`](https://hexdocs.pm/ewe/ewe.html#send_text_frame)
or [`ewe.send_binary_frame`](https://hexdocs.pm/ewe/ewe.html#send_binary_frame)
and say what happens next with
[`ewe.WebsocketNext`](https://hexdocs.pm/ewe/ewe.html#WebsocketNext).

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
) -> ewe.WebsocketNext(WebsocketState, Broadcast) {
  case message {
    ewe.TextFrame(text) -> {
      pubsub.publish(state.pubsub, topic: state.topic, message: Text(text))
      ewe.websocket_continue(state)
    }

    ewe.BinaryFrame(data) -> {
      pubsub.publish(state.pubsub, topic: state.topic, message: Bytes(data))
      ewe.websocket_continue(state)
    }

    // A message from the rest of the program.
    ewe.UserMessage(broadcast) -> {
      let sent = case broadcast {
        Text(text) -> ewe.send_text_frame(conn, text)
        Bytes(data) -> ewe.send_binary_frame(conn, data)
      }

      case sent {
        Ok(Nil) -> ewe.websocket_continue(state)
        Error(_send_error) ->
          ewe.websocket_stop_abnormal("Failed to send a frame")
      }
    }
  }
}
```

Ping and pong frames are answered by the server and never reach the handler. To
start the closing handshake yourself, return
[`ewe.send_close_frame`](https://hexdocs.pm/ewe/ewe.html#send_close_frame) with a
[`ewe.CloseReason`](https://hexdocs.pm/ewe/ewe.html#CloseReason). No frame can be
sent after it!

### [Server-Sent Events](examples/src/sse.gleam)

[`ewe.sse`](https://hexdocs.pm/ewe/ewe.html#sse) turns a response into an SSE
stream which runs until the handler stops it or the client disconnects. `on_init`
receives the subject the rest of your program pushes messages to, `handler` is
called for each of those messages and `on_close` runs once the stream ends.
The `content-type` and `cache-control` headers the stream needs are set by ewe.

```gleam
response.new(200)
|> ewe.sse(
  on_init: fn(client) {
    pubsub.subscribe(pubsub, topic:, client:)

    client
  },
  handler: fn(conn, client, message) {
    case ewe.send_event(conn, ewe.event(message)) {
      Ok(Nil) -> ewe.sse_continue(client)
      Error(_send_error) -> ewe.sse_stop()
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

### Connection Limits and Timeouts

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

ewe.new(listener_name:, connection_factory_name:, handler: handle_request)
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
| `max_chunk_size_line` | `128` | Longest chunk size line in a chunked body. |
| `idle_timeout` | `10_000` | How long a connection may sit without sending anything. |
| `body_read_timeout` | `10_000` | How long a single body read waits for the client. |
| `auto_drain_limit` | `1_048_576` | An unread body larger than this closes the connection instead of being drained. |
| `auto_drain_chunk_bytes` | `65_536` | How much of that drain is read at a time. |

[`ewe.Http2Options`](https://hexdocs.pm/ewe/ewe.html#Http2Options), where a value
the protocol does not allow is replaced with the default rather than reaching a
peer:

| Field | Default | What it does |
| --- | --- | --- |
| `max_concurrent_streams` | `None` | How many streams a client may have open at once. |
| `initial_window_size` | `2_097_152` | How much response body a stream may have in flight. |
| `max_frame_size` | `16_384` | Largest frame accepted, between 16384 and 16777215. |
| `max_header_list_size` | `Some(32_768)` | Largest header list accepted. |
| `header_table_size` | `4096` | HPACK dynamic table kept for decoding. |
| `max_continuation_frames` | `100` | How many CONTINUATION frames one header sequence may span. |
| `max_header_block_bytes` | `65_536` | Bytes one header block may total before decoding. |
| `rapid_reset_window` | `10_000` | Window over which client stream resets are counted. |
| `rapid_reset_threshold` | `100` | Resets within that window that trip a GOAWAY which is what keeps Rapid Reset (CVE-2023-44487) in check. |
| `handshake_timeout` | `10_000` | How long a connection may sit in the preface and SETTINGS handshake. |
| `drain_timeout` | `4000` | How long a draining connection waits for its streams after GOAWAY. |
| `recv_window_low_water_mark` | `262_144` | Once a receive window falls to this it is topped back up. |
| `recv_window_high_water_mark` | `2_097_152` | What it is topped up to; a wider gap costs fewer WINDOW_UPDATE round trips. |
| `file_read_threshold` | `1_048_576` | Files at or below this are read into memory, larger ones are streamed from disk. |
| `body_read_timeout` | `10_000` | How long a single body read waits for the client. |

### Running Under Supervision

[`ewe.start`](https://hexdocs.pm/ewe/ewe.html#start) runs the server on its own.
When it belongs to a supervision tree next to the rest of your program use
[`ewe.supervised`](https://hexdocs.pm/ewe/ewe.html#supervised) instead, which
returns a child specification.

```gleam
supervisor.new(supervisor.OneForAll)
|> supervisor.add(pubsub.worker(pubsub_name))
|> supervisor.add(
  ewe.new(listener_name:, connection_factory_name:, handler:)
  |> ewe.bind(to: "0.0.0.0")
  |> ewe.listening(on: 8080)
  |> ewe.supervised,
)
|> supervisor.start
```

The line printed on startup comes from [`ewe.on_start`](https://hexdocs.pm/ewe/ewe.html#on_start),
which receives the scheme and the address the server bound to. Replace it to log
it your own way or silence it with [`ewe.quiet`](https://hexdocs.pm/ewe/ewe.html#quiet).

### Running as an OTP Application

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

`start` returns the pid of the top supervisor to the application controller,
which is the pid it supervises from there on.

```gleam
import gleam/erlang/atom
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor

/// The Erlang/OTP application start callback. Starts the top supervisor and
/// hands its pid back to the application controller.
pub fn start(_type: a, _args: b) -> Result(process.Pid, actor.StartError) {
  let listener_name = process.new_name("listener_name")
  let connection_factory_name = process.new_name("connection_factory_name")

  case
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(
      ewe.new(listener_name:, connection_factory_name:, handler: handle_request)
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

## Examples

Most sections above link to a runnable example. They live in
[examples](examples/), see [its README](examples/README.md) for how to run them.

## API Reference

For detailed API documentation, see [hexdocs.pm/ewe](https://hexdocs.pm/ewe/ewe.html).
