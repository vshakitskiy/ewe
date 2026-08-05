import ewe/internal/clock
import ewe/internal/connection
import ewe/internal/file
import ewe/internal/http1/connection as http1
import ewe/internal/http1/parser
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/response
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import glisten/socket
import glisten/transport
import websocks

pub type EncodeError {
  UnsafeHeader(name: String)
}

type EncodeState {
  EncodeState(tree: bytes_tree.BytesTree, keep_alive: http1.KeepAlive)
}

/// Whatever still has to reach the socket once the head has been written.
pub type Remainder {
  NoRemainder
  RemainderInline(bytes_tree.BytesTree)
  RemainderFile(connection.File)
  RemainderStream(
    handler: fn(connection.ResponseWriter) -> Nil,
    framing: http1.StreamFraming,
  )
  RemainderSse(
    handler: fn(connection.SseConnection) -> connection.Outcome,
    framing: http1.StreamFraming,
  )
  RemainderWebsocket(
    context: websocks.Context,
    handler: fn(connection.WebsocketConnection) -> connection.Outcome,
  )
}

pub type Encoded {
  Encoded(
    head: bytes_tree.BytesTree,
    keep_alive: http1.KeepAlive,
    remainder: Remainder,
  )
}

pub fn encode_response(
  response: response.Response(connection.Body),
  method: http.Method,
  version: parser.Version,
  keep_alive: http1.KeepAlive,
) -> Result(Encoded, EncodeError) {
  use state <- result.try(encode_headers(
    response.headers,
    reserved(response.body),
  ))
  let keep_alive = http1.and_keep_alive(keep_alive, state.keep_alive)
  let status = response.status

  let encoded = case response.body, is_bodyless(status) {
    connection.Websocket(connection.WebsocketMetadata(context:, handler:)),
      _bodyless
    -> switching_protocols(state, status, context, handler)
    body, True -> bodyless(state, status, keep_alive, body)
    body, False -> encode_body(state, status, keep_alive, version, body)
  }

  // A HEAD response keeps the framing headers it would have had minus the body.
  Ok(case method {
    http.Head -> drop_body(encoded)
    _method -> encoded
  })
}

/// These statuses are defined as carrying no body so they get neither one nor
/// a framing header for the client to wait on.
fn is_bodyless(status: Int) -> Bool {
  status == 204 || status == 304 || { status >= 100 && status < 200 }
}

fn bodyless(
  state: EncodeState,
  status: Int,
  keep_alive: http1.KeepAlive,
  body: connection.Body,
) -> Encoded {
  file.release_body(body)
  Encoded(build_head(state, status, keep_alive, <<>>), keep_alive, NoRemainder)
}

/// The handshake's own `connection` and `upgrade` headers are the whole point
/// of the response so no framing header is written and the head is closed off
/// without one.
fn switching_protocols(
  state: EncodeState,
  status: Int,
  context: websocks.Context,
  handler: fn(connection.WebsocketConnection) -> connection.Outcome,
) -> Encoded {
  let head =
    append_date(state.tree)
    |> bytes_tree.append(<<"\r\n":utf8>>)
    |> bytes_tree.prepend(status_line(status))

  Encoded(
    head,
    http1.CloseAfterResponse,
    RemainderWebsocket(context:, handler:),
  )
}

fn encode_body(
  state: EncodeState,
  status: Int,
  keep_alive: http1.KeepAlive,
  version: parser.Version,
  body: connection.Body,
) -> Encoded {
  case body {
    connection.Bytes(tree) ->
      sized(
        state,
        status,
        keep_alive,
        bytes_tree.byte_size(tree),
        RemainderInline(tree),
      )
    connection.Text(text) ->
      sized(
        state,
        status,
        keep_alive,
        string.byte_size(text),
        RemainderInline(bytes_tree.from_string(text)),
      )
    connection.Empty -> sized(state, status, keep_alive, 0, NoRemainder)
    connection.File(data) ->
      sized(state, status, keep_alive, data.length, RemainderFile(data))
    connection.Streaming(connection.StreamingMetadata(handler)) ->
      encode_stream(state, status, keep_alive, version, handler)
    connection.Sse(connection.SseMetadata(handler)) ->
      encode_sse(state, status, keep_alive, version, handler)
    connection.Websocket(..) -> bodyless(state, status, keep_alive, body)
  }
}

/// Anything the body was holding is let go here.
fn drop_body(encoded: Encoded) -> Encoded {
  case encoded.remainder {
    RemainderFile(data) -> file.release(data)
    NoRemainder
    | RemainderInline(..)
    | RemainderStream(..)
    | RemainderSse(..)
    | RemainderWebsocket(..) -> Nil
  }

  Encoded(..encoded, remainder: NoRemainder)
}

fn sized(
  state: EncodeState,
  status: Int,
  keep_alive: http1.KeepAlive,
  length: Int,
  remainder: Remainder,
) -> Encoded {
  let framing = <<
    "content-length: ":utf8,
    int.to_string(length):utf8,
    "\r\n":utf8,
  >>

  Encoded(build_head(state, status, keep_alive, framing), keep_alive, remainder)
}

fn encode_stream(
  state: EncodeState,
  status: Int,
  keep_alive: http1.KeepAlive,
  version: parser.Version,
  handler: fn(connection.ResponseWriter) -> Nil,
) -> Encoded {
  case version {
    parser.Http11 ->
      Encoded(
        build_head(state, status, keep_alive, <<
          "transfer-encoding: chunked\r\n":utf8,
        >>),
        keep_alive,
        RemainderStream(handler:, framing: http1.ChunkedStream),
      )
    // HTTP/1.0 has no chunked encoding, so the close delimits the body instead.
    parser.Http10 ->
      close_delimited(
        state,
        status,
        RemainderStream(handler:, framing: http1.CloseDelimitedStream),
      )
  }
}

/// On HTTP/1.1 the stream is framed as chunked, which proxies handle far better
/// than one delimited only by the close, and which leaves the socket sitting at
/// a known point afterwards. The connection is advertised as reusable on that
/// basis; whether it is handed back is settled once the stream ends. HTTP/1.0
/// has no chunked encoding, so there the close is the framing and the
/// connection cannot survive it.
///
/// The content type is fixed by the format and the no-cache is what keeps
/// intermediaries from buffering the stream, so both are written from constants
/// here rather than built into the handler's header list.
fn encode_sse(
  state: EncodeState,
  status: Int,
  keep_alive: http1.KeepAlive,
  version: parser.Version,
  handler: fn(connection.SseConnection) -> connection.Outcome,
) -> Encoded {
  case version {
    parser.Http11 ->
      Encoded(
        build_head(state, status, keep_alive, <<
          "content-type: text/event-stream\r\ncache-control: no-cache\r\ntransfer-encoding: chunked\r\n":utf8,
        >>),
        keep_alive,
        RemainderSse(handler:, framing: http1.ChunkedStream),
      )
    parser.Http10 ->
      Encoded(
        build_head(state, status, http1.CloseAfterResponse, <<
          "content-type: text/event-stream\r\ncache-control: no-cache\r\n":utf8,
        >>),
        http1.CloseAfterResponse,
        RemainderSse(handler:, framing: http1.CloseDelimitedStream),
      )
  }
}

fn close_delimited(
  state: EncodeState,
  status: Int,
  remainder: Remainder,
) -> Encoded {
  Encoded(
    build_head(state, status, http1.CloseAfterResponse, <<>>),
    http1.CloseAfterResponse,
    remainder,
  )
}

fn build_head(
  state: EncodeState,
  status: Int,
  keep_alive: http1.KeepAlive,
  framing: BitArray,
) -> bytes_tree.BytesTree {
  append_date(state.tree)
  |> append_connection(keep_alive)
  |> bytes_tree.append(framing)
  |> bytes_tree.append(<<"\r\n":utf8>>)
  |> bytes_tree.prepend(status_line(status))
}

pub type ResponseWriter =
  http1.ResponseWriter

const last_chunk = <<"0\r\n\r\n":utf8>>

/// Wraps one piece of a streamed body in whatever delimits it on the wire.
pub fn frame(
  chunk: bytes_tree.BytesTree,
  framing: http1.StreamFraming,
) -> bytes_tree.BytesTree {
  case framing {
    http1.ChunkedStream ->
      bytes_tree.new()
      |> bytes_tree.append_string(int.to_base16(bytes_tree.byte_size(chunk)))
      |> bytes_tree.append(<<"\r\n":utf8>>)
      |> bytes_tree.append_tree(chunk)
      |> bytes_tree.append(<<"\r\n":utf8>>)
    http1.CloseDelimitedStream -> chunk
  }
}

pub fn send_chunk(
  writer: ResponseWriter,
  chunk: BitArray,
) -> Result(ResponseWriter, socket.SocketReason) {
  frame(bytes_tree.from_bit_array(chunk), writer.framing)
  |> write(writer, _)
  |> result.replace(writer)
}

pub fn finish_chunk(
  writer: ResponseWriter,
  chunk: BitArray,
) -> Result(Nil, socket.SocketReason) {
  // The terminator rides along with the last chunk to save a write.
  let bytes = case writer.framing {
    http1.ChunkedStream ->
      bytes_tree.append(
        frame(bytes_tree.from_bit_array(chunk), writer.framing),
        last_chunk,
      )
    http1.CloseDelimitedStream -> bytes_tree.from_bit_array(chunk)
  }

  write(writer, bytes) |> finished(writer, _)
}

pub fn finish_response(
  writer: ResponseWriter,
) -> Result(Nil, socket.SocketReason) {
  end_stream(writer.transport, writer.socket, writer.framing)
  |> finished(writer, _)
}

fn write(
  writer: ResponseWriter,
  bytes: bytes_tree.BytesTree,
) -> Result(Nil, socket.SocketReason) {
  transport.send(writer.transport, writer.socket, bytes)
}

pub fn end_stream(
  transport: transport.Transport,
  socket: socket.Socket,
  framing: http1.StreamFraming,
) -> Result(Nil, socket.SocketReason) {
  case framing {
    http1.ChunkedStream ->
      transport.send(transport, socket, bytes_tree.from_bit_array(last_chunk))
    http1.CloseDelimitedStream -> Ok(Nil)
  }
}

/// The stream is over either way so the connection process is told so even
/// when the last write never landed. One that ended on a failed write leaves
/// nothing to hand back.
fn finished(
  writer: ResponseWriter,
  sent: Result(Nil, socket.SocketReason),
) -> Result(Nil, socket.SocketReason) {
  let keep_alive = case sent {
    Ok(Nil) -> writer.keep_alive
    Error(_reason) -> http1.CloseAfterResponse
  }

  http1.StreamFinished(keep_alive:)
  |> http1.StreamSignal
  |> process.send(writer.self, _)

  sent
}

/// Which headers the encoder writes itself for a body, and so drops from the
/// handler's list rather than emitting twice.
type Reserved {
  Framing
  FramingAndSse
  Handshake
}

fn reserved(body: connection.Body) -> Reserved {
  case body {
    connection.Sse(..) -> FramingAndSse
    connection.Websocket(..) -> Handshake
    connection.Bytes(..)
    | connection.Text(..)
    | connection.Empty
    | connection.File(..)
    | connection.Streaming(..) -> Framing
  }
}

fn encode_headers(
  headers: List(#(String, String)),
  reserved: Reserved,
) -> Result(EncodeState, EncodeError) {
  let initial = EncodeState(bytes_tree.new(), http1.KeepAlive)
  use state, #(name, value) <- list.try_fold(headers, initial)

  // TODO: just trust the handler?
  case name, reserved {
    "date", _reserved -> Ok(state)
    _name, Handshake -> append_header(state, name, value)
    "content-length", _reserved | "transfer-encoding", _reserved -> Ok(state)
    "content-type", FramingAndSse | "cache-control", FramingAndSse -> Ok(state)
    "connection", _reserved ->
      case parser.find_unsafe_header_byte(value) {
        Error(Nil) -> {
          let lowered = value |> bit_array.from_string |> parser.lowercase_ascii
          let keep_alive = case parser.has_token(lowered, <<"close":utf8>>) {
            True -> http1.CloseAfterResponse
            False -> state.keep_alive
          }
          Ok(EncodeState(..state, keep_alive:))
        }
        Ok(_position) -> Error(UnsafeHeader(name))
      }
    _name, _reserved -> append_header(state, name, value)
  }
}

fn append_header(
  state: EncodeState,
  name: String,
  value: String,
) -> Result(EncodeState, EncodeError) {
  case
    parser.find_unsafe_header_byte(name),
    parser.find_unsafe_header_byte(value)
  {
    Error(Nil), Error(Nil) -> {
      let tree =
        bytes_tree.append_string(state.tree, name)
        |> bytes_tree.append(<<": ":utf8, value:utf8, "\r\n":utf8>>)

      Ok(EncodeState(..state, tree:))
    }
    _name, _value -> Error(UnsafeHeader(name))
  }
}

fn append_date(tree: bytes_tree.BytesTree) -> bytes_tree.BytesTree {
  bytes_tree.append(tree, <<"date: ":utf8, clock.get():bits, "\r\n":utf8>>)
}

fn append_connection(
  tree: bytes_tree.BytesTree,
  keep_alive: http1.KeepAlive,
) -> bytes_tree.BytesTree {
  let value = case keep_alive {
    http1.KeepAlive -> <<"keep-alive":utf8>>
    http1.CloseAfterResponse -> <<"close":utf8>>
  }

  bytes_tree.append(tree, <<"connection: ":utf8, value:bits, "\r\n":utf8>>)
}

fn status_line(status: Int) -> BitArray {
  case status {
    100 -> <<"HTTP/1.1 100 Continue\r\n":utf8>>
    101 -> <<"HTTP/1.1 101 Switching Protocols\r\n":utf8>>
    102 -> <<"HTTP/1.1 102 Processing\r\n":utf8>>
    103 -> <<"HTTP/1.1 103 Early Hints\r\n":utf8>>
    200 -> <<"HTTP/1.1 200 OK\r\n":utf8>>
    201 -> <<"HTTP/1.1 201 Created\r\n":utf8>>
    202 -> <<"HTTP/1.1 202 Accepted\r\n":utf8>>
    203 -> <<"HTTP/1.1 203 Non-Authoritative Information\r\n":utf8>>
    204 -> <<"HTTP/1.1 204 No Content\r\n":utf8>>
    205 -> <<"HTTP/1.1 205 Reset Content\r\n":utf8>>
    206 -> <<"HTTP/1.1 206 Partial Content\r\n":utf8>>
    207 -> <<"HTTP/1.1 207 Multi-Status\r\n":utf8>>
    208 -> <<"HTTP/1.1 208 Already Reported\r\n":utf8>>
    226 -> <<"HTTP/1.1 226 IM Used\r\n":utf8>>
    300 -> <<"HTTP/1.1 300 Multiple Choices\r\n":utf8>>
    301 -> <<"HTTP/1.1 301 Moved Permanently\r\n":utf8>>
    302 -> <<"HTTP/1.1 302 Found\r\n":utf8>>
    303 -> <<"HTTP/1.1 303 See Other\r\n":utf8>>
    304 -> <<"HTTP/1.1 304 Not Modified\r\n":utf8>>
    305 -> <<"HTTP/1.1 305 Use Proxy\r\n":utf8>>
    307 -> <<"HTTP/1.1 307 Temporary Redirect\r\n":utf8>>
    308 -> <<"HTTP/1.1 308 Permanent Redirect\r\n":utf8>>
    400 -> <<"HTTP/1.1 400 Bad Request\r\n":utf8>>
    401 -> <<"HTTP/1.1 401 Unauthorized\r\n":utf8>>
    402 -> <<"HTTP/1.1 402 Payment Required\r\n":utf8>>
    403 -> <<"HTTP/1.1 403 Forbidden\r\n":utf8>>
    404 -> <<"HTTP/1.1 404 Not Found\r\n":utf8>>
    405 -> <<"HTTP/1.1 405 Method Not Allowed\r\n":utf8>>
    406 -> <<"HTTP/1.1 406 Not Acceptable\r\n":utf8>>
    407 -> <<"HTTP/1.1 407 Proxy Authentication Required\r\n":utf8>>
    408 -> <<"HTTP/1.1 408 Request Timeout\r\n":utf8>>
    409 -> <<"HTTP/1.1 409 Conflict\r\n":utf8>>
    410 -> <<"HTTP/1.1 410 Gone\r\n":utf8>>
    411 -> <<"HTTP/1.1 411 Length Required\r\n":utf8>>
    412 -> <<"HTTP/1.1 412 Precondition Failed\r\n":utf8>>
    413 -> <<"HTTP/1.1 413 Content Too Large\r\n":utf8>>
    414 -> <<"HTTP/1.1 414 URI Too Long\r\n":utf8>>
    415 -> <<"HTTP/1.1 415 Unsupported Media Type\r\n":utf8>>
    416 -> <<"HTTP/1.1 416 Range Not Satisfiable\r\n":utf8>>
    417 -> <<"HTTP/1.1 417 Expectation Failed\r\n":utf8>>
    418 -> <<"HTTP/1.1 418 I'm a Teapot\r\n":utf8>>
    421 -> <<"HTTP/1.1 421 Misdirected Request\r\n":utf8>>
    422 -> <<"HTTP/1.1 422 Unprocessable Content\r\n":utf8>>
    423 -> <<"HTTP/1.1 423 Locked\r\n":utf8>>
    424 -> <<"HTTP/1.1 424 Failed Dependency\r\n":utf8>>
    425 -> <<"HTTP/1.1 425 Too Early\r\n":utf8>>
    426 -> <<"HTTP/1.1 426 Upgrade Required\r\n":utf8>>
    428 -> <<"HTTP/1.1 428 Precondition Required\r\n":utf8>>
    429 -> <<"HTTP/1.1 429 Too Many Requests\r\n":utf8>>
    431 -> <<"HTTP/1.1 431 Request Header Fields Too Large\r\n":utf8>>
    451 -> <<"HTTP/1.1 451 Unavailable For Legal Reasons\r\n":utf8>>
    500 -> <<"HTTP/1.1 500 Internal Server Error\r\n":utf8>>
    501 -> <<"HTTP/1.1 501 Not Implemented\r\n":utf8>>
    502 -> <<"HTTP/1.1 502 Bad Gateway\r\n":utf8>>
    503 -> <<"HTTP/1.1 503 Service Unavailable\r\n":utf8>>
    504 -> <<"HTTP/1.1 504 Gateway Timeout\r\n":utf8>>
    505 -> <<"HTTP/1.1 505 HTTP Version Not Supported\r\n":utf8>>
    506 -> <<"HTTP/1.1 506 Variant Also Negotiates\r\n":utf8>>
    507 -> <<"HTTP/1.1 507 Insufficient Storage\r\n":utf8>>
    508 -> <<"HTTP/1.1 508 Loop Detected\r\n":utf8>>
    510 -> <<"HTTP/1.1 510 Not Extended\r\n":utf8>>
    511 -> <<"HTTP/1.1 511 Network Authentication Required\r\n":utf8>>
    _other -> <<"HTTP/1.1 ":utf8, int.to_string(status):utf8, " \r\n":utf8>>
  }
}

/// A bare response for a request that never reached a handler, sent on a
/// connection that is closed straight after.
pub fn error_response(status: Int) -> bytes_tree.BytesTree {
  EncodeState(bytes_tree.new(), http1.CloseAfterResponse)
  |> build_head(status, http1.CloseAfterResponse, <<
    "content-length: 0\r\n":utf8,
  >>)
}

pub fn internal_server_error() -> bytes_tree.BytesTree {
  error_response(500)
}
