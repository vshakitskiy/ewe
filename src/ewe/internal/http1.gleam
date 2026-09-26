import ewe/internal/connection
import ewe/internal/file
import ewe/internal/http1/connection as http1
import ewe/internal/http1/encoder
import ewe/internal/http1/parser
import ewe/internal/rescue
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/option
import gleam/result
import logging
import tup
import tup/socket

pub type State {
  State(
    handler: connection.Handler,
    self: process.Subject(connection.Message),
    buffer: BitArray,
    idle_timer: option.Option(process.Timer),
    options: http1.Options,
  )
}

pub type Next {
  Continue(State)
  Close
  CloseAbnormal(reason: String)
}

type Sent {
  SentKeepAlive
  SentClose
  SentAbnormal(reason: String)
}

pub fn handle_message(state: State, connection: tup.Connection) -> Next {
  connection.cancel_timer(state.idle_timer)

  case parser.parse(state.buffer, state.options) {
    Ok(parser.Complete(head, metadata, remaining)) ->
      handle_request(state, connection, head, metadata, remaining)
    Ok(parser.Incomplete) -> {
      let idle_timer =
        connection.start_idle_timer(state.self, state.options.idle_timeout)
      Continue(State(..state, idle_timer:))
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "Failed to parse HTTP/1.x request: " <> parser.error_to_string(error),
      )

      case error {
        parser.BadVersion -> Nil
        _other ->
          parser.error_to_status(error)
          |> encoder.error_response
          |> refuse(connection, _)
      }

      Close
    }
  }
}

fn handle_request(
  state: State,
  connection: tup.Connection,
  head: parser.Head,
  metadata: parser.Metadata,
  remaining: BitArray,
) -> Next {
  let self = process.new_subject()
  let #(transport, socket) = tup.socket(connection)

  let body_connection =
    http1.Connection(
      transport:,
      socket:,
      peer: tup.peer(connection),
      self:,
      buffer: remaining,
      framing: metadata.framing,
      read: 0,
      chunk_remaining: 0,
      options: state.options,
      upgrade: metadata.upgrade,
    )

  let request = to_request(head, connection, body_connection)

  case rescue.run(fn() { state.handler.respond(request) }) {
    Error(details) -> {
      logging.log(
        logging.Error,
        "Caught a crash in the request handler: " <> details,
      )

      let _sent =
        respond(
          connection,
          state.handler.on_crash,
          head,
          http1.CloseAfterResponse,
          self,
        )
      Close
    }
    Ok(response) -> {
      let drained = drain_messages(self)
      let ResolvedBody(buffer, body_keep_alive) =
        resolve_body(body_connection, drained.body, state.options)
      let keep_alive =
        http1.and_keep_alive(metadata.keep_alive, body_keep_alive)

      case respond(connection, response, head, keep_alive, self) {
        Ok(SentKeepAlive) -> await_next_request(state, buffer, connection)
        Ok(SentClose) | Error(_reason) -> Close
        Ok(SentAbnormal(reason)) -> CloseAbnormal(reason)
      }
    }
  }
}

fn respond(
  connection: tup.Connection,
  response: response.Response(connection.Body),
  head: parser.Head,
  keep_alive: http1.KeepAlive,
  self: process.Subject(http1.Signal),
) -> Result(Sent, socket.SocketError) {
  case
    encoder.encode_response(response, head.method, head.version, keep_alive)
  {
    Ok(encoded) -> {
      let #(transport, socket) = tup.socket(connection)
      send_response(encoded, transport, socket, self)
    }
    Error(encoder.UnsafeHeader(name)) -> {
      logging.log(
        logging.Error,
        "Handler produced an unsafe response header: " <> name,
      )
      file.release_body(response.body)

      refuse(connection, encoder.internal_server_error())
      Ok(SentClose)
    }
  }
}

fn refuse(connection: tup.Connection, response: bytes_tree.BytesTree) -> Nil {
  let #(transport, socket) = tup.socket(connection)
  let _sent = socket.send(transport, socket, response)

  Nil
}

fn await_next_request(
  state: State,
  buffer: BitArray,
  connection: tup.Connection,
) -> Next {
  case buffer {
    <<>> -> {
      let idle_timer =
        connection.start_idle_timer(state.self, state.options.idle_timeout)
      Continue(State(..state, buffer:, idle_timer:))
    }
    _buffer ->
      State(..state, buffer:, idle_timer: option.None)
      |> handle_message(connection)
  }
}

fn to_request(
  head: parser.Head,
  connection: tup.Connection,
  body: http1.Connection,
) -> request.Request(connection.Connection) {
  let scheme = case tup.socket(connection) {
    #(socket.Tcp, _socket) -> http.Http
    #(socket.Ssl, _socket) -> http.Https
  }

  request.Request(
    method: head.method,
    headers: head.headers,
    body: connection.Http1(body),
    scheme:,
    host: head.host,
    port: head.port,
    path: head.path,
    query: head.query,
  )
}

fn send_response(
  encoded: encoder.Encoded,
  transport: socket.Transport,
  socket: socket.Socket,
  self: process.Subject(http1.Signal),
) -> Result(Sent, socket.SocketError) {
  let encoder.Encoded(head:, keep_alive:, remainder:) = encoded

  case remainder {
    encoder.NoRemainder -> {
      use Nil <- result.try(socket.send(transport, socket, head))
      Ok(to_sent(keep_alive))
    }
    encoder.RemainderInline(body) -> {
      use Nil <- result.try(socket.send(
        transport,
        socket,
        bytes_tree.append_tree(head, body),
      ))
      Ok(to_sent(keep_alive))
    }
    encoder.RemainderFile(data) ->
      case socket.send(transport, socket, head) {
        Error(reason) -> {
          file.release(data)
          Error(reason)
        }
        Ok(Nil) -> {
          use Nil <- result.try(file.send(transport, socket, data))
          Ok(to_sent(keep_alive))
        }
      }
    encoder.RemainderStream(handler: stream_handler, framing:) -> {
      use Nil <- result.try(socket.send(transport, socket, head))

      let writer =
        connection.Http1Writer(http1.ResponseWriter(
          transport:,
          socket:,
          self:,
          framing:,
          keep_alive:,
        ))

      case rescue.run(fn() { stream_handler(writer) }) {
        Error(details) -> {
          logging.log(
            logging.Error,
            "Caught a crash in the streaming handler: " <> details,
          )
          Ok(SentClose)
        }
        Ok(Nil) -> {
          let drained = drain_messages(self)
          case drained.stream {
            option.Some(http1.StreamFinished(keep_alive:)) ->
              Ok(to_sent(keep_alive))
            option.None -> {
              let _sent = encoder.end_stream(transport, socket, framing)
              Ok(SentClose)
            }
          }
        }
      }
    }
    encoder.RemainderWebsocket(context:, handler: websocket_handler) -> {
      use Nil <- result.try(socket.send(transport, socket, head))

      let outcome =
        http1.WebsocketConnection(transport:, socket:, context:)
        |> connection.Http1Websocket
        |> websocket_handler

      case outcome {
        connection.Stopped -> Ok(SentClose)
        connection.StoppedAbnormal(reason) -> Ok(SentAbnormal(reason))
      }
    }
    encoder.RemainderSse(handler: sse_handler, framing:) -> {
      use Nil <- result.try(socket.send(transport, socket, head))

      let outcome =
        http1.SseConnection(transport:, socket:, self:, framing:)
        |> connection.Http1Sse
        |> sse_handler

      let _sent = encoder.end_stream(transport, socket, framing)

      let drained = drain_messages(self)
      let stream_keep_alive = case drained.stream {
        option.Some(http1.StreamFinished(keep_alive:)) -> keep_alive
        option.None -> http1.CloseAfterResponse
      }

      case outcome {
        connection.StoppedAbnormal(reason) -> Ok(SentAbnormal(reason))
        connection.Stopped ->
          http1.and_keep_alive(keep_alive, stream_keep_alive)
          |> to_sent
          |> Ok
      }
    }
  }
}

fn to_sent(keep_alive: http1.KeepAlive) -> Sent {
  case keep_alive {
    http1.KeepAlive -> SentKeepAlive
    http1.CloseAfterResponse -> SentClose
  }
}

type ResolvedBody {
  ResolvedBody(leftover: BitArray, keep_alive: http1.KeepAlive)
}

fn resolve_body(
  conn: http1.Connection,
  drained: option.Option(http1.BodySignal),
  options: http1.Options,
) -> ResolvedBody {
  case drained {
    option.Some(http1.BodyDrained(leftover)) ->
      ResolvedBody(leftover, http1.KeepAlive)
    option.Some(http1.BodyAbandoned) ->
      ResolvedBody(<<>>, http1.CloseAfterResponse)
    option.Some(http1.BodyProgress(buffer:, read:, chunk_remaining:)) ->
      http1.Connection(..conn, buffer:, read:, chunk_remaining:)
      |> drain_remaining(options)
    option.None -> drain_remaining(conn, options)
  }
}

type Drained {
  Drained(
    body: option.Option(http1.BodySignal),
    stream: option.Option(http1.StreamSignal),
  )
}

fn drain_messages(self: process.Subject(http1.Signal)) -> Drained {
  do_drain_messages(self, Drained(body: option.None, stream: option.None))
}

fn do_drain_messages(
  self: process.Subject(http1.Signal),
  acc: Drained,
) -> Drained {
  case process.receive(self, 0) {
    Ok(http1.BodySignal(signal)) ->
      do_drain_messages(self, Drained(..acc, body: option.Some(signal)))
    Ok(http1.StreamSignal(signal)) ->
      do_drain_messages(self, Drained(..acc, stream: option.Some(signal)))
    Error(Nil) -> acc
  }
}

fn drain_remaining(
  conn: http1.Connection,
  options: http1.Options,
) -> ResolvedBody {
  let http1.Connection(read:, ..) = conn
  do_drain_remaining(conn, read + options.auto_drain_limit, options)
}

fn do_drain_remaining(
  conn: http1.Connection,
  limit: Int,
  options: http1.Options,
) -> ResolvedBody {
  case pull_chunk(conn, options.auto_drain_chunk_bytes, limit) {
    Ok(PulledChunk(_data, next)) -> do_drain_remaining(next, limit, options)
    Ok(PulledDone(_trailers, leftover)) ->
      ResolvedBody(leftover, http1.KeepAlive)
    Error(_reason) -> ResolvedBody(<<>>, http1.CloseAfterResponse)
  }
}

pub type BodyError {
  BodyTooLarge
  InvalidBody
}

pub fn read_body(
  conn: http1.Connection,
  limit: Int,
) -> Result(#(BitArray, List(#(String, String))), BodyError) {
  let http1.Connection(self:, framing:, ..) = conn

  case framing, consume_body(conn, limit, bytes_tree.new()) {
    _framing, Ok(#(body, trailers, leftover)) -> {
      send_body_signal(self, http1.BodyDrained(leftover:))
      Ok(#(body, trailers))
    }
    http1.Fixed(_length), Error(BodyTooLarge) -> Error(BodyTooLarge)
    _framing, Error(error) -> {
      send_body_signal(self, http1.BodyAbandoned)
      Error(error)
    }
  }
}

fn send_body_signal(
  self: process.Subject(http1.Signal),
  signal: http1.BodySignal,
) -> Nil {
  process.send(self, http1.BodySignal(signal))
}

pub type ChunkRead {
  Chunk(data: BitArray, connection: http1.Connection)
  Done(trailers: List(#(String, String)))
}

pub fn read_body_chunk(
  conn: http1.Connection,
  max_chunk_bytes max_chunk_bytes: Int,
  limit limit: Int,
) -> Result(ChunkRead, BodyError) {
  let self = conn.self

  case pull_chunk(conn, max_chunk_bytes, limit) {
    Ok(PulledChunk(data, next)) -> {
      let http1.Connection(buffer:, read:, chunk_remaining:, ..) = next
      send_body_signal(
        self,
        http1.BodyProgress(buffer:, read:, chunk_remaining:),
      )

      Ok(Chunk(data, next))
    }
    Ok(PulledDone(trailers, leftover)) -> {
      send_body_signal(self, http1.BodyDrained(leftover:))

      Ok(Done(trailers))
    }
    Error(error) -> {
      send_body_signal(self, http1.BodyAbandoned)

      Error(error)
    }
  }
}

fn consume_body(
  conn: http1.Connection,
  limit: Int,
  acc: bytes_tree.BytesTree,
) -> Result(#(BitArray, List(#(String, String)), BitArray), BodyError) {
  case pull_chunk(conn, limit, limit) {
    Ok(PulledChunk(data, next)) ->
      consume_body(next, limit, bytes_tree.append(acc, data))
    Ok(PulledDone(trailers, leftover)) ->
      Ok(#(bytes_tree.to_bit_array(acc), trailers, leftover))
    Error(error) -> Error(error)
  }
}

fn to_body_result(
  result: Result(a, parser.ParseError),
) -> Result(a, BodyError) {
  case result {
    Ok(value) -> Ok(value)
    Error(parser.ChunkTooLarge) -> Error(BodyTooLarge)
    Error(_other) -> Error(InvalidBody)
  }
}

pub type Pulled {
  PulledChunk(data: BitArray, connection: http1.Connection)
  PulledDone(trailers: List(#(String, String)), leftover: BitArray)
}

pub fn pull_chunk(
  conn: http1.Connection,
  max_chunk_bytes: Int,
  limit: Int,
) -> Result(Pulled, BodyError) {
  let http1.Connection(buffer:, framing:, read:, chunk_remaining:, ..) = conn

  case framing {
    http1.NoBody -> Ok(PulledDone([], buffer))
    http1.Fixed(length) if length > limit -> Error(BodyTooLarge)
    http1.Fixed(length) ->
      pull_fixed_chunk(conn, length, read, max_chunk_bytes) |> to_body_result
    http1.Chunked ->
      pull_chunked_chunk(conn, limit, read, chunk_remaining, max_chunk_bytes)
      |> to_body_result
  }
}

fn pull_fixed_chunk(
  conn: http1.Connection,
  length: Int,
  read: Int,
  max_chunk_bytes: Int,
) -> Result(Pulled, parser.ParseError) {
  let http1.Connection(transport:, socket:, buffer:, ..) = conn

  case length - read {
    0 -> Ok(PulledDone([], buffer))
    remaining -> {
      let want = int.min(remaining, max_chunk_bytes)
      use #(data, leftover) <- result.try(read_exact(
        transport,
        socket,
        buffer,
        want,
        conn.options.body_read_timeout,
      ))
      let conn = http1.Connection(..conn, buffer: leftover, read: read + want)
      Ok(PulledChunk(data, conn))
    }
  }
}

fn read_exact(
  transport: socket.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  length: Int,
  timeout: Int,
) -> Result(#(BitArray, BitArray), parser.ParseError) {
  case buffer {
    <<data:bytes-size(length), leftover:bits>> -> Ok(#(data, leftover))
    _buffer ->
      case
        socket.receive(
          transport,
          socket,
          length - bit_array.byte_size(buffer),
          socket.Milliseconds(timeout),
        )
      {
        Ok(more) -> Ok(#(connection.append_buffer(buffer, more), <<>>))
        Error(_reason) -> Error(parser.BodyReadFailed)
      }
  }
}

fn pull_chunked_chunk(
  conn: http1.Connection,
  limit: Int,
  read: Int,
  chunk_remaining: Int,
  max_chunk_bytes: Int,
) -> Result(Pulled, parser.ParseError) {
  let http1.Connection(transport:, socket:, buffer:, options:, ..) = conn

  case chunk_remaining {
    0 -> {
      use #(size, buffer) <- result.try(
        pull_until(
          transport,
          socket,
          buffer,
          options.body_read_timeout,
          parse_chunk_line(_, options),
        ),
      )

      case size {
        0 -> {
          use #(trailers, _state, buffer) <- result.try({
            use buffer <- pull_until(
              transport,
              socket,
              buffer,
              options.body_read_timeout,
            )
            parser.parse_headers(
              buffer,
              [],
              0,
              parser.initial_header_state(),
              options,
            )
          })

          Ok(PulledDone(trailers, buffer))
        }
        size if read + size > limit -> Error(parser.ChunkTooLarge)
        size ->
          http1.Connection(..conn, buffer:)
          |> take_chunk_slice(read, size, max_chunk_bytes)
      }
    }
    remaining -> take_chunk_slice(conn, read, remaining, max_chunk_bytes)
  }
}

fn take_chunk_slice(
  conn: http1.Connection,
  read: Int,
  chunk_remaining: Int,
  max_chunk_bytes: Int,
) -> Result(Pulled, parser.ParseError) {
  let http1.Connection(transport:, socket:, buffer:, ..) = conn

  let want = int.min(chunk_remaining, max_chunk_bytes)
  let slice = case want == chunk_remaining {
    True -> LastSlice
    False -> PartialSlice
  }

  use #(data, buffer) <- result.try({
    use buffer <- pull_until(
      transport,
      socket,
      buffer,
      conn.options.body_read_timeout,
    )
    take_chunk_prefix(buffer, want, slice)
  })

  let conn =
    http1.Connection(
      ..conn,
      buffer:,
      read: read + want,
      chunk_remaining: chunk_remaining - want,
    )
  Ok(PulledChunk(data, conn))
}

fn pull_until(
  transport: socket.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  timeout: Int,
  step: fn(BitArray) -> parser.Step(a),
) -> Result(a, parser.ParseError) {
  case step(buffer) {
    parser.StepDone(value) -> Ok(value)
    parser.ParseError(error) -> Error(error)
    parser.More ->
      case socket.receive(transport, socket, 0, socket.Milliseconds(timeout)) {
        Ok(more) ->
          pull_until(
            transport,
            socket,
            connection.append_buffer(buffer, more),
            timeout,
            step,
          )
        Error(_reason) -> Error(parser.BodyReadFailed)
      }
  }
}

fn parse_chunk_line(
  buffer: BitArray,
  options: http1.Options,
) -> parser.Step(#(Int, BitArray)) {
  use #(line, remaining) <- parser.try_step(parser.extract_line(
    buffer,
    options.max_chunk_size_line,
    parser.ChunkSizeLineTooLong,
    parser.BadChunkSize,
  ))
  use size <- parser.try_step(parse_chunk_size(line))
  parser.StepDone(#(size, remaining))
}

fn parse_chunk_size(line: BitArray) -> parser.Step(Int) {
  case parse_hex_digits(line, 0, False) {
    Ok(size) -> parser.StepDone(size)
    Error(Nil) -> parser.ParseError(parser.BadChunkSize)
  }
}

fn parse_hex_digits(bits: BitArray, acc: Int, any: Bool) -> Result(Int, Nil) {
  case bits {
    <<byte, remaining:bits>> if byte >= 48 && byte <= 57 ->
      parse_hex_digits(remaining, acc * 16 + { byte - 48 }, True)
    <<byte, remaining:bits>> if byte >= 97 && byte <= 102 ->
      parse_hex_digits(remaining, acc * 16 + { byte - 87 }, True)
    <<byte, remaining:bits>> if byte >= 65 && byte <= 70 ->
      parse_hex_digits(remaining, acc * 16 + { byte - 55 }, True)
    _bits if any -> Ok(acc)
    _bits -> Error(Nil)
  }
}

type Slice {
  LastSlice
  PartialSlice
}

fn take_chunk_prefix(
  buffer: BitArray,
  want: Int,
  slice: Slice,
) -> parser.Step(#(BitArray, BitArray)) {
  case slice {
    LastSlice ->
      case buffer {
        <<data:bytes-size(want), "\r\n":utf8, remaining:bits>> ->
          parser.StepDone(#(data, remaining))
        _buffer ->
          case bit_array.byte_size(buffer) < want + 2 {
            True -> parser.More
            False -> parser.ParseError(parser.BadChunkFraming)
          }
      }
    PartialSlice ->
      case buffer {
        <<data:bytes-size(want), remaining:bits>> ->
          parser.StepDone(#(data, remaining))
        _buffer -> parser.More
      }
  }
}

pub type SocketEvent(user_message) {
  UserMessage(user_message)
  Packet(BitArray)
  Closed
  Failed(reason: String)
  Exhausted
  Exited(connection.Exit)
}

pub fn socket_selector(
  messages: process.Selector(user_message),
) -> process.Selector(SocketEvent(user_message)) {
  process.map_selector(messages, UserMessage)
  |> process.select_record(atom.create("tcp"), 2, packet)
  |> process.select_record(atom.create("ssl"), 2, packet)
  |> process.select_record(atom.create("tcp_closed"), 1, closed)
  |> process.select_record(atom.create("ssl_closed"), 1, closed)
  |> process.select_record(atom.create("tcp_error"), 2, failed)
  |> process.select_record(atom.create("ssl_error"), 2, failed)
  |> process.select_record(atom.create("tcp_passive"), 1, exhausted)
  |> process.select_record(atom.create("ssl_passive"), 1, exhausted)
  |> connection.select_exits(Exited)
}

fn packet(record: dynamic.Dynamic) -> SocketEvent(user_message) {
  Packet(socket_payload(record))
}

fn closed(_record: dynamic.Dynamic) -> SocketEvent(user_message) {
  Closed
}

fn failed(record: dynamic.Dynamic) -> SocketEvent(user_message) {
  socket_error_reason(record)
  |> socket.describe_error
  |> Failed
}

fn exhausted(_record: dynamic.Dynamic) -> SocketEvent(user_message) {
  Exhausted
}

pub fn activate(
  transport: socket.Transport,
  socket: socket.Socket,
) -> Result(Nil, socket.SocketError) {
  socket.set_options(transport, socket, [
    socket.Active(socket.Packets(http1.active_count)),
  ])
  |> result.replace_error(socket.Closed)
}

@external(erlang, "ewe_ffi", "socket_error_reason")
fn socket_error_reason(record: dynamic.Dynamic) -> socket.SocketError

@external(erlang, "ewe_ffi", "socket_payload")
fn socket_payload(record: dynamic.Dynamic) -> BitArray
