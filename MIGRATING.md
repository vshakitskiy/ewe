# Migrating from v4 to latest

Since v5 that breaks most of the v4 API, there are quite some changes that needs 
to be happened when moving on to the latest version. Luckily the compiler will 
catch most of the changes. It is recommended to see [Behaviour changes](#behaviour-changes) 
as well.

Every example below is v4 on one side and the latest version (which is v7) on 
the other.

## Builder functions

`new` takes two `process.Name`s that helps wiring the acceptor pool's listener 
to its connection factory. Create them once at startup.

```gleam
// v4
ewe.new(handle_request)
|> ewe.with_name(listener_name)

// latest
ewe.new(listener_name:, connection_factory_name:, handler: handle_request)
```

Labels of `bind` and `listening` got renamed:
```gleam
// v4
|> ewe.bind(interface: "0.0.0.0")
|> ewe.listening(port: 8080)

// latest
|> ewe.bind(to: "0.0.0.0")
|> ewe.listening(on: 8080)
```
The default port changed from 8080 to 3000.

Because of the change with providing names for acceptor pool, `with_name` 
function is gone.

`on_crash` still sets the response a crashing handler answers with but its body
must be `Bytes`, `Text` or `Empty`. Any other body is replaced with `Empty` and
logged as a warning when the server starts.

The certificate source is now a value rather than two path arguments.
```gleam
// v4
ewe.enable_tls(builder, certificate_file: "cert.pem", key_file: "key.pem")

// latest
ewe.with_tls(builder, ewe.Disk(cert: "cert.pem", key: "key.pem"))
ewe.with_tls(builder, ewe.Pem(cert: cert_bits, key: key_bits))
ewe.with_tls(builder, ewe.Der(cert: cert_bits, key: key_bits, key_type: ewe.RsaPrivateKey))
```

v4 exposed only `idle_timeout`. Latest version puts every HTTP/1 limit on 
`Http1Options` built by updating the defaults.

```gleam
// v4
ewe.idle_timeout(builder, 30_000)

// latest
ewe.with_http1(
  builder,
  ewe.Http1Options(..ewe.default_http1_options(), idle_timeout: 30_000),
)
```

A value outside the range a field accepts is replaced with the default and
logged as a warning when the server starts.

## Server and client addresses

`SocketAddress` gained a second variant for Unix sockets so now we need to 
pattern match on the type:
```gleam
// v4
let ewe.SocketAddress(ip:, port:) = ewe.get_server_info(listener_name)

// latest
case ewe.get_server_info(process.named_subject(listener_name)) {
  ewe.TcpSocketAddress(ip_address:, port:) -> todo
  ewe.UnixSocketAddress(path:) -> todo
}
```

`get_server_info` takes a `process.Subject(listener.Message)` rather than a
`process.Name`.

`on_start` receives a `SocketAddress`.

Argument labels were dropped from `ip_address_to_string`, `get_client_info` and
`get_server_info`:

```gleam
// v4
ewe.get_client_info(connection:)
ewe.ip_address_to_string(address:)

// latest
ewe.get_client_info(connection)
ewe.ip_address_to_string(address)
```

## Response

`ResponseBody` is now `Body`. The variants standing for a stream carry their
setup data rather than being bare markers so they can no longer be constructed 
by the user without usage of intended functions.

Some records got renamed and removed:
```gleam
// v4:
ewe.TextData(text)
ewe.BytesData(tree)
ewe.BitsData(bits)
ewe.StringTreeData(tree)
ewe.Empty
ewe.File(descriptor:, offset:, size:)
ewe.Chunked
ewe.SSE
ewe.Websocket

// with latest:
ewe.Text(text)
ewe.Bytes(tree)
ewe.Bytes(bytes_tree.from_bit_array(bits))
ewe.Bytes(bytes_tree.from_string_tree(tree))
ewe.Empty
ewe.File(..)
ewe.Streaming(..)
ewe.Sse(..)
ewe.Websocket(..)
```

The `Request` and `Response` aliases were removed. Write the `gleam/http` types
directly:

```gleam
// v4
fn handle(request: ewe.Request) -> ewe.Response

// latest
fn handle(
  request: request.Request(ewe.Connection),
) -> response.Response(ewe.Body)
```

## Files

`file` takes the connection as first argument since how a file reaches the client 
depends on the protocol.

```gleam
// v4
ewe.file("/tmp/report.pdf", offset: None, limit: None)

// latest
let connection = request.body
ewe.file(connection, "/tmp/report.pdf", offset: None, limit: None)
```

`FileError` variants were renamed, and two were added:

```gleam
// v4
ewe.NoEntry
ewe.NoAccess
ewe.IsDirectory
ewe.UnknownFileError(dynamic)

// latest
ewe.NotFound
ewe.AccessDenied
ewe.IsDirectory
ewe.UnknownError
ewe.InvalidOffset
ewe.InvalidLimit
```

## Reading the request body

`read_body` changed only its label:

```gleam
// v4
ewe.read_body(request, bytes_limit: 1_048_576)

// latest
ewe.read_body(request, limit: 1_048_576)
```

`stream_body` is gone, along with the `ewe.Consumer` and `ewe.Stream` types it
returned. `read_body_chunk` replaces them. Call it in a loop, threading the
request it returns.

```gleam
// v4
let assert Ok(consumer) = ewe.stream_body(request)
case consumer(4096) {
  Ok(ewe.Consumed(data, next)) -> todo
  Ok(ewe.Done) -> todo
  Error(_body_error) -> todo
}

// latest
fn count(request: request.Request(ewe.Connection), total: Int) -> Int {
  case ewe.read_body_chunk(request, max_chunk_bytes: 4096, limit: 10_000_000) {
    Ok(ewe.Chunk(data:, request:)) ->
      count(request, total + bit_array.byte_size(data))
    Ok(ewe.Done(_request)) -> total
    Error(_body_error) -> total
  }
}
```

`Done` carries the request with any trailer fields appended to its headers.

## Streaming a response

v4 ran a chunked body as an actor with `on_init`/`handler`/`on_close`. The 
latest version hands the handler a writer to write to directly with no process 
spawned per response.

```gleam
// v4
ewe.chunked_body(
  request,
  response.new(200),
  on_init: fn(subject) { 0 },
  handler: fn(body, state, message) {
    let _ = ewe.send_chunk(body, <<"chunk":utf8>>)
    ewe.chunked_continue(state)
  },
  on_close: fn(_body, _state) { Nil },
)

// latest
response.new(200)
|> response.set_header("content-type", "text/plain")
|> ewe.stream_response(fn(writer) {
  use writer <- result.try(ewe.send_chunk(writer, <<"Hello, ":utf8>>))
  ewe.finish_chunk(writer, <<"Joe!":utf8>>)
})
```

The body must be finished with `finish_chunk` or `finish_response`. A handler
that returns without calling either still has its body closed off but the
connection is dropped rather than reused.

## Server-Sent Events

The names lost their uppercase `SSE` (like `ewe.SSEConnection` to
`ewe.SseConnection`) and `sse` takes the response.

`on_init` no longer receives a subject made by ewe. Like `websocket` it receives
the stream connection and an empty selector to add your own subjects to and
returns the starting state along with that selector. What the handler returns is
now the shared `Next`, so `sse_continue` and `sse_stop` are `continue` and
`stop`.

```gleam
// v4
ewe.sse(
  request,
  on_init: fn(subject) { 0 },
  handler: fn(conn, sent, message) { ewe.sse_continue(sent + 1) },
  on_close: fn(_conn, _sent) { Nil },
)

// latest
response.new(200)
|> ewe.sse(
  on_init: fn(_conn, selector) {
    // Hand `client` to whatever pushes messages to this stream.
    let client = process.new_subject()

    #(0, process.select(selector, client))
  },
  handler: fn(conn, sent, message) {
    case ewe.send_event(conn, ewe.event(message)) {
      Ok(Nil) -> ewe.continue(sent + 1)
      Error(_send_error) -> ewe.stop()
    }
  },
  on_close: fn(_conn, _sent) { Nil },
)
```

## WebSockets

```gleam
// v4
ewe.upgrade_websocket(request, on_init:, handler:, on_close:)

// latest
ewe.websocket(request:, on_init:, handler:, on_close:)
```

The message variants were renamed:
```gleam
// v4
ewe.Text(text)
ewe.Binary(data)
ewe.User(message)

// latest
ewe.TextFrame(text)
ewe.BinaryFrame(data)
ewe.UserMessage(message)
```

`WebsocketNext` is now `Next`, shared with `sse`, and its constructors lost the
prefix:

```gleam
// v4
ewe.websocket_continue(state)
ewe.websocket_continue_with_selector(state, selector)
ewe.websocket_stop()
ewe.websocket_stop_abnormal(reason)

// latest
ewe.continue(state)
ewe.continue_with_selector(state, selector)
ewe.stop()
ewe.stop_abnormal(reason)
```

v4 had one `CloseCode` variant per code, each carrying its own description. The 
latest version splits the code from the description:

```gleam
// v4
ewe.send_close_frame(conn, ewe.NormalClosure("done"))
ewe.send_close_frame(conn, ewe.CustomCloseCode(4000, "bye"))
ewe.send_close_frame(conn, ewe.NoCloseReason)

// latest
ewe.send_close_frame(conn, ewe.CloseReason(ewe.NormalClosure, "done"))
ewe.send_close_frame(conn, ewe.CloseReason(ewe.ApplicationCode(4000), "bye"))
ewe.send_close_frame(conn, ewe.NoCloseReason)
```

`CloseCode` also gained `GoingAway`, `ProtocolError`, `UnsupportedData` and
`MandatoryExtension`.

## Send errors

`send_chunk`, `send_event`, `send_text_frame` and `send_binary_frame` all failed
with a raw `glisten.SocketReason` in v4. The latest version returns its own 
`SendError` so matching on failures no longer needs `glisten` as a direct 
dependency.

```gleam
// v4
case ewe.send_event(conn, event) {
  Ok(Nil) -> todo
  Error(_glisten_socket_reason) -> todo
}

// latest
case ewe.send_event(conn, event) {
  Ok(Nil) -> todo
  Error(ewe.ConnectionClosed) -> todo
  Error(ewe.StreamReset) -> todo
  Error(ewe.SendTimedOut) -> todo
  Error(ewe.SocketError(reason)) -> todo
}
```

`ewe.send_error_to_string` and `ewe.socket_reason_to_string` render either for a
log line.

<h2 id="behaviour-changes">Behaviour changes</h2>

These are the changes of what the server does at runtime.

### Framing headers override the handler. 
v4 set `content-length` and `date` only when the handler had not set them itself 
so a handler could override either. Since v5 ewe drops the handler's 
`content-length`, `transfer-encoding` and `date` and writes its own, 
computing `content-length` or `transfer-encoding: chunked` from the body. 
`connection` is still read for a `close` token.

### Responses are no longer gzipped. 
v4 compressed a response whenever the request carried `accept-encoding: gzip` 
and the handler had not set `content-encoding`, adding `content-encoding`, `vary` 
and a recomputed `content-length`. From v5 ewe does no content encoding at all 
so responses go out uncompressed unless the handler compresses them and sets the 
headers itself.

### Unread request bodies are drained. 
A handler that returns without reading the body leaves ewe to read and discard 
it so the connection can serve the next request. Past `auto_drain_limit` (which 
is 1 MB by default) the connection is closed instead. v4 left the unread bytes 
in the socket where the next read misparsed them as a new request.

### Streaming, SSE and WebSockets no longer get a process of their own.
v4 spawned one per response and handed it the socket. From v5 ewe runs the 
desired stream in the request's process (in connection process on HTTP/1 and in 
stream process on HTTP/2).

### HTTP/2 is on by default.
Plaintext connections opening with the h2c preface are served as HTTP/2 and 
`h2` is offered over ALPN whenever TLS is configured. WebSockets over HTTP/2 need 
the extended `CONNECT` of RFC 8441 which is off until `websocket: True` is set 
on `Http2Options`. Until then such a request is refused as malformed.

## New since v4

- As HTTP/2 is now available, we have new type `Http2Options` with 
  `default_http2_options` and `with_http2` to adjust HTTP/2 options.
- WebSockets run over HTTP/2 as well once `websocket` is turned on in 
  `Http2Options`, with `send_buffer_limit` capping what a stream may leave 
  queued for a client that is not reading before it is reset.
- We support unix sockets via `ewe.unix(path)`
- We can enable client certificate verification via 
  `ewe.with_client_verification` for mTLS.
- In-memory TLS certificates are now alloed with `ewe.Pem` and `ewe.Der`.
- For SSE keepalives there is now `ewe.comment`.
- For sending the last chunk and closing the body in one write for streaming we
  can use `ewe.finish_chunk`.
- An SSE stream can swap the selector it listens on with
  `ewe.continue_with_selector`, which only WebSockets could do before.
