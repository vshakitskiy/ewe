import ewe/internal/clock
import ewe/internal/connection
import ewe/internal/file
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import glisten
import glisten/internal/handler
import glisten/socket
import glisten/transport
import logging

pub type State {
  State(
    handler: fn(request.Request(connection.Connection)) ->
      response.Response(connection.Body),
    buffer: BitArray,
    idle_timer: option.Option(process.Timer),
  )
}

pub const idle_timeout = 10_000

pub type Next {
  Continue(State)
  Close
}

pub fn handle_message(
  state: State,
  connection: glisten.Connection(connection.Message),
) -> Next {
  case state.idle_timer {
    option.Some(timer) -> process.cancel_timer(timer)
    option.None -> process.TimerNotFound
  }

  case parse(state.buffer) {
    Ok(Complete(head, metadata, remaining)) -> {
      let scheme = case connection.transport {
        transport.Tcp -> http.Http
        transport.Ssl -> http.Https
      }

      let self = process.new_subject()

      let body_connection =
        connection.Http1Connection(
          transport: connection.transport,
          socket: connection.socket,
          self:,
          buffer: remaining,
          framing: metadata.framing,
          read: 0,
          chunk_remaining: 0,
        )

      let request =
        request.Request(
          method: head.method,
          headers: head.headers,
          body: connection.Http1(body_connection),
          scheme:,
          host: head.host,
          port: head.port,
          path: head.path,
          query: head.query,
        )

      let response = state.handler(request)

      let drained = drain_messages(self)

      let #(buffer, body_drained) = resolve_body(body_connection, drained.body)

      let metadata =
        Metadata(..metadata, keep_alive: metadata.keep_alive && body_drained)

      let sent = case
        encode_response(response, head.method, head.version, metadata)
      {
        Ok(Encoded(bytes:, keep_alive:, file: file_body, stream:)) -> {
          use Nil <- result.try(transport.send(
            connection.transport,
            connection.socket,
            bytes,
          ))

          case file_body, stream {
            option.None, option.None -> Ok(keep_alive)
            option.Some(data), option.None ->
              case file.send(connection.transport, connection.socket, data) {
                Ok(Nil) -> Ok(keep_alive)
                Error(reason) -> Error(reason)
              }
            option.None, option.Some(Stream(handler: stream_handler, chunked:))
            -> {
              connection.Http1Writer(connection.Http1ResponseWriter(
                transport: connection.transport,
                socket: connection.socket,
                self:,
                chunked:,
                keep_alive:,
              ))
              |> stream_handler

              let stream_drained = drain_messages(self)
              let stream_keep_alive = case stream_drained.stream {
                option.Some(connection.StreamFinished(keep_alive:)) ->
                  keep_alive
                option.None -> {
                  // The handler never called finish_chunk or finish_response.
                  // Every chunk sent so far already closed its own framing,
                  // so writing the terminator now still leaves the wire in
                  // a valid state... But the connection can't be trusted
                  // enough to reuse, so it closes regardless.
                  case chunked {
                    True -> {
                      let _ =
                        transport.send(
                          connection.transport,
                          connection.socket,
                          bytes_tree.from_bit_array(<<"0\r\n\r\n":utf8>>),
                        )
                      Nil
                    }
                    False -> Nil
                  }
                  False
                }
                option.Some(connection.BodyDrained(..))
                | option.Some(connection.BodyAbandoned)
                | option.Some(connection.BodyProgress(..)) ->
                  panic as "drain_messages routes body messages to the other slot"
              }

              Ok(keep_alive && stream_keep_alive)
            }
            option.Some(_file), option.Some(_stream) ->
              panic as "encode_response never sets both file and stream"
          }
        }
        Error(UnsafeHeader(name)) -> {
          logging.log(
            logging.Error,
            "Handler produced an unsafe response header: " <> name,
          )

          use Nil <- result.try(transport.send(
            connection.transport,
            connection.socket,
            internal_server_error(),
          ))

          Ok(False)
        }
      }

      case sent {
        Ok(True) -> {
          let timer =
            process.send_after(
              connection.subject,
              idle_timeout,
              handler.User(connection.Timeout),
            )

          State(..state, buffer:, idle_timer: option.Some(timer))
          |> Continue
        }
        Ok(False) -> Close
        Error(_reason) -> Close
      }
    }
    Ok(Incomplete) -> {
      let timer =
        process.send_after(
          connection.subject,
          idle_timeout,
          handler.User(connection.Timeout),
        )

      Continue(State(..state, idle_timer: option.Some(timer)))
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "Failed to parse HTTP/1.x request: " <> error_to_string(error),
      )

      Close
    }
  }
}

/// Errors from consuming a request body via `read_body`.
pub type BodyError {
  /// A `Fixed` body's declared length alone exceeds `limit`, so nothing was
  /// read; or a `Chunked` body's running total went over `limit` mid-stream,
  /// so the connection is no longer reusable.
  BodyTooLarge
  /// The body couldn't be fully read off the socket: closed, timed out, or
  /// malformed chunked framing.
  InvalidBody
}

pub type Connection =
  connection.Http1Connection

const body_read_timeout = 10_000

// Cap for auto draining a body the handler never read, so the connection can
// still be reused for the next request. Bodies bigger than this force a
// close instead of an unbounded drain.
const auto_drain_limit = 1_048_576

/// Reads the entire request body into memory, up to `limit` bytes, along with
/// any chunked trailer fields. Blocks until the full body has arrived. 
/// `Fixed` and `NoBody` requests never have trailers.
pub fn read_body(
  conn: Connection,
  limit: Int,
) -> Result(#(BitArray, List(#(String, String))), BodyError) {
  let connection.Http1Connection(
    transport:,
    socket:,
    self:,
    buffer:,
    framing:,
    ..,
  ) = conn

  case framing, consume_body(transport, socket, buffer, framing, limit) {
    _framing, Ok(#(body, trailers, leftover)) -> {
      process.send(self, connection.BodyDrained(leftover:))
      Ok(#(body, trailers))
    }
    connection.Fixed(_length), Error(BodyTooLarge) -> Error(BodyTooLarge)
    _framing, Error(error) -> {
      process.send(self, connection.BodyAbandoned)
      Error(error)
    }
  }
}

/// The result of one `read_body_chunk` call.
pub type ChunkRead {
  /// `max_chunk_bytes` of body data. Feed `connection` into the next call.
  Chunk(data: BitArray, connection: Connection)
  /// The body is fully consumed. Carries any chunked trailer fields. `Fixed` 
  /// and `NoBody` requests never have trailers.
  Done(trailers: List(#(String, String)))
}

/// Pulls up to `max_chunk_bytes` of body per call instead of buffering the 
/// whole body, capped overall at `limit`. Feed the connection carried by 
/// `Chunk` into the next call. Ends with `Done` once the body, and any chunked 
/// trailers, are fully consumed.
pub fn read_body_chunk(
  conn: Connection,
  max_chunk_bytes max_chunk_bytes: Int,
  limit limit: Int,
) -> Result(ChunkRead, BodyError) {
  let connection.Http1Connection(self:, buffer:, read:, chunk_remaining:, ..) =
    conn

  case pull_chunk(conn, max_chunk_bytes, limit) {
    Ok(PulledChunk(data, next)) -> {
      connection.BodyProgress(buffer:, read:, chunk_remaining:)
      |> process.send(self, _)

      Ok(Chunk(data, next))
    }
    Ok(PulledDone(trailers, leftover)) -> {
      process.send(self, connection.BodyDrained(leftover:))

      Ok(Done(trailers))
    }
    Error(error) -> {
      process.send(self, connection.BodyAbandoned)

      Error(error)
    }
  }
}

// Cap on how much is pulled off the wire per step while blind draining an 
// abandoned body. Unrelated to any caller supplied `max_chunk_bytes`.
const auto_drain_chunk_bytes = 65_536

// Reconciles what the handler did with the request body so the connection can
// be safely reused. Replays whatever `read_body`/`read_body_chunk` last
// reported about themselves via a message to `conn.self`, drained by
// `drain_messages` into `drained.body`:
// - `BodyDrained`: the body was fully consumed, use its leftover directly.
// - `BodyAbandoned`: the read failed mid-body, the connection can't be reused.
// - `BodyProgress` or nothing at all: the handler stopped reading or never
//   started, so drain whatever's left from that point, up to `auto_drain_limit`
//   more bytes, so a well behaved client isn't punished with a dropped
//   connection just because the handler didn't care about its body.
fn resolve_body(
  conn: Connection,
  drained: option.Option(connection.Http1Signal),
) -> #(BitArray, Bool) {
  case drained {
    option.Some(connection.BodyDrained(leftover)) -> #(leftover, True)
    option.Some(connection.BodyAbandoned) -> #(<<>>, False)
    option.Some(connection.BodyProgress(buffer:, read:, chunk_remaining:)) ->
      connection.Http1Connection(..conn, buffer:, read:, chunk_remaining:)
      |> drain_remaining
    option.None -> drain_remaining(conn)
    option.Some(connection.StreamFinished(..)) ->
      panic as "drain_messages routes stream messages to the other slot"
  }
}

// The latest body read and response stream outcome messages currently queued
// for a request's own private subject, drained in one pass so a handler that
// both reads a request body and streams a response doesn't lose one outcome
// to the other.
type Drained {
  Drained(
    body: option.Option(connection.Http1Signal),
    stream: option.Option(connection.Http1Signal),
  )
}

// Selectively receives every message already queued for `self`, keeping only
// the last one of each kind.
fn drain_messages(self: process.Subject(connection.Http1Signal)) -> Drained {
  do_drain_messages(self, Drained(body: option.None, stream: option.None))
}

fn do_drain_messages(
  self: process.Subject(connection.Http1Signal),
  acc: Drained,
) -> Drained {
  case process.receive(self, 0) {
    Ok(connection.StreamFinished(..) as message) ->
      do_drain_messages(self, Drained(..acc, stream: option.Some(message)))
    Ok(message) ->
      do_drain_messages(self, Drained(..acc, body: option.Some(message)))
    Error(Nil) -> acc
  }
}

// Drains whatever's left of `conn`'s body, up to `auto_drain_limit` more bytes 
// past however much has already been read.
fn drain_remaining(conn: Connection) -> #(BitArray, Bool) {
  let connection.Http1Connection(read:, ..) = conn
  do_drain_remaining(conn, read + auto_drain_limit)
}

fn do_drain_remaining(conn: Connection, limit: Int) -> #(BitArray, Bool) {
  case pull_chunk(conn, auto_drain_chunk_bytes, limit) {
    Ok(PulledChunk(_data, next)) -> do_drain_remaining(next, limit)
    Ok(PulledDone(_trailers, leftover)) -> #(leftover, True)
    Error(_reason) -> #(<<>>, False)
  }
}

// Consumes exactly the declared body from `buffer`, pulling more from the 
// socket as needed, and splits off whatever comes right after it, along with
// any chunked trailer fields.
fn consume_body(
  transport: transport.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  framing: connection.Framing,
  limit: Int,
) -> Result(#(BitArray, List(#(String, String)), BitArray), BodyError) {
  case framing {
    connection.NoBody -> Ok(#(<<>>, [], buffer))
    connection.Fixed(length) if length > limit -> Error(BodyTooLarge)
    connection.Fixed(length) ->
      read_fixed(transport, socket, buffer, length) |> to_body_result
    connection.Chunked ->
      read_chunked(transport, socket, buffer, limit, bytes_tree.new(), 0)
      |> to_body_result
  }
}

fn to_body_result(result: Result(a, ParseError)) -> Result(a, BodyError) {
  case result {
    Ok(value) -> Ok(value)
    Error(ChunkTooLarge) -> Error(BodyTooLarge)
    Error(_other) -> Error(InvalidBody)
  }
}

// A `Content-Length` body. Whatever's missing beyond `buffer` is read in a
// single exact size call, since the socket blocks until exactly that many
// bytes arrive or the connection drops.
fn read_fixed(
  transport: transport.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  length: Int,
) -> Result(#(BitArray, List(#(String, String)), BitArray), ParseError) {
  case buffer {
    <<body:bytes-size(length), leftover:bits>> -> Ok(#(body, [], leftover))
    _ -> {
      case
        transport.receive_timeout(
          transport,
          socket,
          length - bit_array.byte_size(buffer),
          body_read_timeout,
        )
      {
        Ok(more) -> Ok(#(<<buffer:bits, more:bits>>, [], <<>>))
        Error(_reason) -> Error(BodyReadFailed)
      }
    }
  }
}

// A `Transfer-Encoding: chunked` body. Each call advances by one chunk or 
// trailers, pulling more from the socket only for whichever piece is currently 
// short.
fn read_chunked(
  transport: transport.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  limit: Int,
  acc: bytes_tree.BytesTree,
  total: Int,
) -> Result(#(BitArray, List(#(String, String)), BitArray), ParseError) {
  use #(size, remaining) <- result.try(pull_until(
    transport,
    socket,
    buffer,
    parse_chunk_line,
  ))

  case size {
    0 -> {
      use #(trailers, _state, remaining) <- result.try({
        use buffer <- pull_until(transport, socket, remaining)
        parse_headers(buffer, [], 0, initial_header_state())
      })

      Ok(#(bytes_tree.to_bit_array(acc), trailers, remaining))
    }
    size -> {
      let total = total + size
      case total > limit {
        True -> Error(ChunkTooLarge)
        False -> {
          use #(data, remaining) <- result.try({
            use buffer <- pull_until(transport, socket, remaining)
            take_chunk_prefix(buffer, size, True)
          })

          read_chunked(
            transport,
            socket,
            remaining,
            limit,
            bytes_tree.append(acc, data),
            total,
          )
        }
      }
    }
  }
}

// The result of pulling one step of a streamed body.
type Pulled {
  PulledChunk(data: BitArray, connection: Connection)
  PulledDone(trailers: List(#(String, String)), leftover: BitArray)
}

// Pulls at most `max_chunk_bytes` of body off `conn`, capped overall at `limit`. 
// Mirrors `consume_body`, but advances by one bounded slice instead of reading 
// the whole declared body.
fn pull_chunk(
  conn: Connection,
  max_chunk_bytes: Int,
  limit: Int,
) -> Result(Pulled, BodyError) {
  let connection.Http1Connection(buffer:, framing:, read:, chunk_remaining:, ..) =
    conn

  case framing {
    connection.NoBody -> Ok(PulledDone([], buffer))
    connection.Fixed(length) if length > limit -> Error(BodyTooLarge)
    connection.Fixed(length) ->
      pull_fixed_chunk(conn, length, read, max_chunk_bytes) |> to_body_result
    connection.Chunked ->
      pull_chunked_chunk(conn, limit, read, chunk_remaining, max_chunk_bytes)
      |> to_body_result
  }
}

// A `Content-Length` body. Takes `min(remaining, max_chunk_bytes)`, since 
// there's no wire framing inside the payload itself to bound a single pull to 
// less than that.
fn pull_fixed_chunk(
  conn: Connection,
  length: Int,
  read: Int,
  max_chunk_bytes: Int,
) -> Result(Pulled, ParseError) {
  let connection.Http1Connection(transport:, socket:, buffer:, ..) = conn

  case length - read {
    0 -> Ok(PulledDone([], buffer))
    remaining -> {
      let want = int.min(remaining, max_chunk_bytes)
      use #(data, _trailers, leftover) <- result.try(read_fixed(
        transport,
        socket,
        buffer,
        want,
      ))
      let conn =
        connection.Http1Connection(..conn, buffer: leftover, read: read + want)
      Ok(PulledChunk(data, conn))
    }
  }
}

// A `Transfer-Encoding: chunked` body. At a chunk boundary, parses the next
// chunk-size line or the trailer section. Otherwise resumes taking a bounded 
// slice out of the chunk already in progress.
fn pull_chunked_chunk(
  conn: Connection,
  limit: Int,
  read: Int,
  chunk_remaining: Int,
  max_chunk_bytes: Int,
) -> Result(Pulled, ParseError) {
  let connection.Http1Connection(transport:, socket:, buffer:, ..) = conn

  case chunk_remaining {
    0 -> {
      use #(size, buffer) <- result.try(pull_until(
        transport,
        socket,
        buffer,
        parse_chunk_line,
      ))

      case size {
        0 -> {
          use #(trailers, _state, buffer) <- result.try({
            use buffer <- pull_until(transport, socket, buffer)
            parse_headers(buffer, [], 0, initial_header_state())
          })

          Ok(PulledDone(trailers, buffer))
        }
        size if read + size > limit -> Error(ChunkTooLarge)
        size ->
          connection.Http1Connection(..conn, buffer:)
          |> take_chunk_slice(read, size, max_chunk_bytes)
      }
    }
    remaining -> take_chunk_slice(conn, read, remaining, max_chunk_bytes)
  }
}

fn take_chunk_slice(
  conn: Connection,
  read: Int,
  chunk_remaining: Int,
  max_chunk_bytes: Int,
) -> Result(Pulled, ParseError) {
  let connection.Http1Connection(transport:, socket:, buffer:, ..) = conn

  let want = int.min(chunk_remaining, max_chunk_bytes)
  let final_slice = want == chunk_remaining

  use #(data, buffer) <- result.try({
    use buffer <- pull_until(transport, socket, buffer)
    take_chunk_prefix(buffer, want, final_slice)
  })

  let conn =
    connection.Http1Connection(
      ..conn,
      buffer:,
      read: read + want,
      chunk_remaining: chunk_remaining - want,
    )
  Ok(PulledChunk(data, conn))
}

// Runs `step` against `buffer`, pulling more bytes from the socket only when
// `step` itself reports it's short.
fn pull_until(
  transport: transport.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  step: fn(BitArray) -> Step(a),
) -> Result(a, ParseError) {
  case step(buffer) {
    StepDone(value) -> Ok(value)
    ParseError(error) -> Error(error)
    More ->
      case transport.receive_timeout(transport, socket, 0, body_read_timeout) {
        Ok(more) ->
          pull_until(transport, socket, <<buffer:bits, more:bits>>, step)
        Error(_reason) -> Error(BodyReadFailed)
      }
  }
}

fn parse_chunk_line(buffer: BitArray) -> Step(#(Int, BitArray)) {
  use #(line, remaining) <- try_step(extract_line(
    buffer,
    max_chunk_size_line,
    ChunkSizeLineTooLong,
    BadChunkSize,
  ))
  use size <- try_step(parse_chunk_size(line))
  StepDone(#(size, remaining))
}

// Chunk-size lines may carry `;extensions`. Only the hex size before them 
// matters here
fn parse_chunk_size(line: BitArray) -> Step(Int) {
  case parse_hex_digits(line, 0, False) {
    Ok(size) -> StepDone(size)
    Error(Nil) -> ParseError(BadChunkSize)
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

// Takes `want` bytes off the front of a chunk's data. `final_slice` marks 
// whether `want` reaches the end of the chunk, in which case the trailing CRLF 
// is expected right after and consumed too. Otherwise `want` is just a prefix 
// of a bigger chunk still being streamed across calls.
fn take_chunk_prefix(
  buffer: BitArray,
  want: Int,
  final_slice: Bool,
) -> Step(#(BitArray, BitArray)) {
  case final_slice {
    True ->
      case buffer {
        <<data:bytes-size(want), "\r\n":utf8, remaining:bits>> ->
          StepDone(#(data, remaining))
        _buffer ->
          case bit_array.byte_size(buffer) < want + 2 {
            True -> More
            False -> ParseError(BadChunkFraming)
          }
      }
    False ->
      case buffer {
        <<data:bytes-size(want), remaining:bits>> ->
          StepDone(#(data, remaining))
        _buffer -> More
      }
  }
}

/// Errors that can occur while turning a handler's `response.Response` into 
/// wire bytes.
pub type EncodeError {
  /// A header name or value contained a CR, LF, or NUL byte, which would let 
  /// it inject a new header or terminate the header block early.
  UnsafeHeader(name: String)
}

// Threaded through the pass over `response.headers` with the tree built so far 
// and whether the handler's own `connection` header asked to close.
type EncodeState {
  EncodeState(tree: bytes_tree.BytesTree, force_close: Bool)
}

fn initial_encode_state() -> EncodeState {
  EncodeState(tree: bytes_tree.new(), force_close: False)
}

/// A `Streaming` body's handler, plus whether its chunks get
/// `Transfer-Encoding: chunked` framing (HTTP/1.1) or written raw
/// (HTTP/1.0, which has no chunked encoding).
pub type Stream {
  Stream(handler: fn(connection.ResponseWriter) -> Nil, chunked: Bool)
}

/// The result of encoding a response. `bytes` is ready for a single
/// `transport.send`. `file` and `stream`, when present, still need handling
/// separately since neither is loaded into `bytes`; `encode_response` never
/// sets both.
pub type Encoded {
  Encoded(
    bytes: bytes_tree.BytesTree,
    keep_alive: Bool,
    file: option.Option(connection.File),
    stream: option.Option(Stream),
  )
}

/// Builds the response as a `BytesTree`. `Bytes`, `Text` and `Empty` bodies
/// are folded straight into it, so the whole response goes out in a single
/// `transport.send`. A `Streaming` body's handler isn't run here -- like
/// `File`, the caller runs it separately, only after sending `bytes`.
pub fn encode_response(
  response: response.Response(connection.Body),
  method: http.Method,
  version: Version,
  metadata: Metadata,
) -> Result(Encoded, EncodeError) {
  use state <- result.try(encode_headers(response.headers))
  let keep_alive = metadata.keep_alive && !state.force_close

  case response.body {
    connection.Streaming(handler) ->
      Ok(encode_stream(state, response, keep_alive, version, method, handler))
    _other_body -> {
      let length = body_length(response.body)
      let head =
        state.tree
        |> append_date()
        |> append_connection(keep_alive)
        |> bytes_tree.prepend(status_line(response.status))
        |> bytes_tree.append_string("content-length: " <> int.to_string(length))
        |> bytes_tree.append(<<"\r\n\r\n":utf8>>)

      case method, response.body {
        http.Head, _body ->
          Ok(Encoded(head, keep_alive, option.None, option.None))
        _method, connection.File(data) ->
          Ok(Encoded(head, keep_alive, option.Some(data), option.None))
        _method, connection.Bytes(tree) ->
          Ok(Encoded(
            bytes_tree.append_tree(head, tree),
            keep_alive,
            option.None,
            option.None,
          ))
        _method, connection.Text(text) ->
          Ok(Encoded(
            bytes_tree.append_string(head, text),
            keep_alive,
            option.None,
            option.None,
          ))
        _method, connection.Empty ->
          Ok(Encoded(head, keep_alive, option.None, option.None))
        _method, connection.Streaming(..) ->
          panic as "the Streaming body is handled above"
      }
    }
  }
}

// Builds the head for a `Streaming` body: `Transfer-Encoding: chunked` on
// HTTP/1.1, or a close-delimited body with no chunk framing on HTTP/1.0,
// which has no chunked encoding. `HEAD` never gets a body, mirroring how
// `encode_response` skips one for every other body type, so `handler` is
// simply never run.
fn encode_stream(
  state: EncodeState,
  response: response.Response(connection.Body),
  keep_alive: Bool,
  version: Version,
  method: http.Method,
  handler: fn(connection.ResponseWriter) -> Nil,
) -> Encoded {
  case version {
    Http11 -> {
      let head =
        state.tree
        |> append_date()
        |> append_connection(keep_alive)
        |> bytes_tree.prepend(status_line(response.status))
        |> bytes_tree.append_string("transfer-encoding: chunked")
        |> bytes_tree.append(<<"\r\n\r\n":utf8>>)

      case method {
        http.Head -> Encoded(head, keep_alive, option.None, option.None)
        _method ->
          Encoded(
            head,
            keep_alive,
            option.None,
            option.Some(Stream(handler, True)),
          )
      }
    }
    Http10 -> {
      let head =
        state.tree
        |> append_date()
        |> append_connection(False)
        |> bytes_tree.prepend(status_line(response.status))
        |> bytes_tree.append(<<"\r\n":utf8>>)

      case method {
        http.Head -> Encoded(head, False, option.None, option.None)
        _method ->
          Encoded(head, False, option.None, option.Some(Stream(handler, False)))
      }
    }
  }
}

/// How a streamed response writes its body chunks to the wire.
pub type ResponseWriter =
  connection.Http1ResponseWriter

fn chunk_frame(chunk: BitArray) -> bytes_tree.BytesTree {
  bytes_tree.new()
  |> bytes_tree.append_string(int.to_base16(bit_array.byte_size(chunk)))
  |> bytes_tree.append(<<"\r\n":utf8>>)
  |> bytes_tree.append(chunk)
  |> bytes_tree.append(<<"\r\n":utf8>>)
}

/// Sends one response body chunk. Framed as one `Transfer-Encoding: chunked`
/// piece on HTTP/1.1, written raw otherwise. For the last chunk, use
/// `finish_chunk` instead: it closes the stream in the same round trip.
pub fn send_chunk(writer: ResponseWriter, chunk: BitArray) -> ResponseWriter {
  let bytes = case writer.chunked {
    True -> chunk_frame(chunk)
    False -> bytes_tree.from_bit_array(chunk)
  }
  let _ = transport.send(writer.transport, writer.socket, bytes)
  writer
}

/// Sends `chunk` as the final response body chunk and closes the stream.
pub fn finish_chunk(writer: ResponseWriter, chunk: BitArray) -> Nil {
  let bytes = case writer.chunked {
    True -> bytes_tree.append(chunk_frame(chunk), <<"0\r\n\r\n":utf8>>)
    False -> bytes_tree.from_bit_array(chunk)
  }
  let _ = transport.send(writer.transport, writer.socket, bytes)
  finish(writer)
}

/// Closes the stream with no further data. Use `finish_chunk` instead if
/// there's one last chunk to send.
pub fn finish_response(writer: ResponseWriter) -> Nil {
  case writer.chunked {
    True -> {
      let _ =
        transport.send(
          writer.transport,
          writer.socket,
          bytes_tree.from_bit_array(<<"0\r\n\r\n":utf8>>),
        )
      Nil
    }
    False -> Nil
  }
  finish(writer)
}

fn finish(writer: ResponseWriter) -> Nil {
  process.send(
    writer.self,
    connection.StreamFinished(keep_alive: writer.keep_alive),
  )
}

// Builds the header block.
fn encode_headers(
  headers: List(#(String, String)),
) -> Result(EncodeState, EncodeError) {
  use state, #(name, value) <- list.try_fold(headers, initial_encode_state())
  case name {
    "content-length" | "transfer-encoding" | "date" -> Ok(state)
    "connection" ->
      case find_unsafe_header_byte(value) {
        Error(Nil) -> {
          let lowered = value |> bit_array.from_string |> lowercase_ascii
          let force_close =
            state.force_close || has_token(lowered, <<"close":utf8>>)
          Ok(EncodeState(..state, force_close:))
        }
        Ok(_position) -> Error(UnsafeHeader(name))
      }
    _name ->
      case find_unsafe_header_byte(name), find_unsafe_header_byte(value) {
        Error(Nil), Error(Nil) -> {
          let tree =
            bytes_tree.append_string(state.tree, name)
            |> bytes_tree.append(<<": ":utf8>>)
            |> bytes_tree.append_string(value)
            |> bytes_tree.append(<<"\r\n":utf8>>)

          Ok(EncodeState(..state, tree:))
        }
        _other, _other -> Error(UnsafeHeader(name))
      }
  }
}

// Fills in `Date` from the shared clock (RFC 9110 §6.6.1). The clock actor 
// refreshes the cached value once a second.
fn append_date(tree: bytes_tree.BytesTree) -> bytes_tree.BytesTree {
  bytes_tree.append_string(tree, "date: ")
  |> bytes_tree.append(clock.get())
  |> bytes_tree.append(<<"\r\n":utf8>>)
}

fn append_connection(
  tree: bytes_tree.BytesTree,
  keep_alive: Bool,
) -> bytes_tree.BytesTree {
  let value = case keep_alive {
    True -> <<"keep-alive":utf8>>
    False -> <<"close":utf8>>
  }

  bytes_tree.append(tree, <<"connection: ":utf8>>)
  |> bytes_tree.append(value)
  |> bytes_tree.append(<<"\r\n":utf8>>)
}

// Precomputed `HTTP/1.1 NNN Reason\r\n` literals for every standard status 
// code. Codes with no registered meaning in this range fall through to the 
// general form with an empty reason phrase.
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

fn body_length(body: connection.Body) -> Int {
  case body {
    connection.Bytes(tree) -> bytes_tree.byte_size(tree)
    connection.Text(text) -> string.byte_size(text)
    connection.Empty -> 0
    connection.File(data) -> data.length
    connection.Streaming(..) -> panic as "the Streaming body is handled above"
  }
}

fn internal_server_error() -> bytes_tree.BytesTree {
  bytes_tree.new()
  |> bytes_tree.append(<<
    "HTTP/1.1 500 Internal Server Error\r\ndate: ":utf8,
  >>)
  |> bytes_tree.append(clock.get())
  |> bytes_tree.append(<<
    "\r\nconnection: close\r\ncontent-length: 0\r\n\r\n":utf8,
  >>)
}

pub type Version {
  Http10
  Http11
}

/// The parsed request line and headers. Does not include the body. Carries
/// everything `request.Request` needs besides `scheme` and `body`, which
/// only the caller can supply.
pub type Head {
  Head(
    method: http.Method,
    host: String,
    port: option.Option(Int),
    path: String,
    query: option.Option(String),
    version: Version,
    headers: List(#(String, String)),
  )
}

/// Cheap conclusions drawn from `Head.headers` in one pass.
pub type Metadata {
  Metadata(
    framing: connection.Framing,
    keep_alive: Bool,
    upgrade: option.Option(String),
  )
}

pub type ParseError {
  RequestLineTooLong
  BadRequestLine
  BadMethod
  BadTarget
  BadVersion
  HeaderLineTooLong
  BadHeader
  TooManyHeaders
  DuplicateContentLength
  BadContentLength
  DuplicateHost
  BadHost
  MissingHost
  AmbiguousFraming
  ChunkSizeLineTooLong
  BadChunkSize
  BadChunkFraming
  ChunkTooLarge
  BodyReadFailed
}

pub fn error_to_string(error: ParseError) -> String {
  case error {
    RequestLineTooLong ->
      "request line exceeds " <> int.to_string(max_request_line) <> " bytes"
    BadRequestLine -> "malformed request line"
    BadMethod -> "invalid request method"
    BadTarget -> "invalid request target"
    BadVersion -> "unsupported or malformed HTTP version"
    HeaderLineTooLong ->
      "header line exceeds " <> int.to_string(max_header_line) <> " bytes"
    BadHeader -> "malformed header line"
    TooManyHeaders ->
      "too many headers (max " <> int.to_string(max_headers) <> ")"
    DuplicateContentLength -> "duplicate Content-Length header"
    BadContentLength -> "invalid Content-Length value"
    DuplicateHost -> "duplicate Host header"
    BadHost -> "invalid Host header"
    MissingHost -> "missing required Host header"
    AmbiguousFraming ->
      "conflicting Content-Length and Transfer-Encoding headers"
    ChunkSizeLineTooLong ->
      "chunk size line exceeds "
      <> int.to_string(max_chunk_size_line)
      <> " bytes"
    BadChunkSize -> "malformed chunk size"
    BadChunkFraming -> "malformed chunk data framing"
    ChunkTooLarge -> "chunked body exceeds size limit"
    BodyReadFailed -> "failed to read request body from the socket"
  }
}

pub type Parsed {
  Complete(head: Head, metadata: Metadata, remaining: BitArray)
  Incomplete
}

const max_request_line = 8192

const max_header_line = 8192

const max_headers = 100

const max_chunk_size_line = 128

/// Parses as much of a request head as `buffer` contains.
pub fn parse(buffer: BitArray) -> Result(Parsed, ParseError) {
  let step = {
    use #(method, target, version, remaining) <- try_step(parse_request_line(
      buffer,
    ))

    use #(headers, state, remaining) <- try_step(parse_headers(
      remaining,
      [],
      0,
      initial_header_state(),
    ))

    use #(host, port, path, query) <- try_step(resolve_target(
      method,
      target,
      version,
      state.host,
    ))

    use metadata <- try_step(resolve_metadata(state, version))

    StepDone(Complete(
      Head(method:, host:, port:, path:, query:, version:, headers:),
      metadata,
      remaining,
    ))
  }

  case step {
    StepDone(parsed) -> Ok(parsed)
    More -> Ok(Incomplete)
    ParseError(error) -> Error(error)
  }
}

type Step(a) {
  StepDone(a)
  More
  ParseError(ParseError)
}

fn try_step(step: Step(a), next: fn(a) -> Step(b)) -> Step(b) {
  case step {
    StepDone(value) -> next(value)
    More -> More
    ParseError(error) -> ParseError(error)
  }
}

fn parse_request_line(
  buffer: BitArray,
) -> Step(#(http.Method, BitArray, Version, BitArray)) {
  use #(line, remaining) <- try_step(extract_line(
    buffer,
    max_request_line,
    RequestLineTooLong,
    BadRequestLine,
  ))

  use #(method, target_and_version) <- try_step(parse_method(line))

  use #(target, version) <- try_step(parse_target_version(target_and_version))

  StepDone(#(method, target, version, remaining))
}

fn parse_method(line: BitArray) -> Step(#(http.Method, BitArray)) {
  case line {
    <<"GET ":utf8, remaining:bits>> -> StepDone(#(http.Get, remaining))
    <<"POST ":utf8, remaining:bits>> -> StepDone(#(http.Post, remaining))
    <<"PUT ":utf8, remaining:bits>> -> StepDone(#(http.Put, remaining))
    <<"DELETE ":utf8, remaining:bits>> -> StepDone(#(http.Delete, remaining))
    <<"HEAD ":utf8, remaining:bits>> -> StepDone(#(http.Head, remaining))
    <<"OPTIONS ":utf8, remaining:bits>> -> StepDone(#(http.Options, remaining))
    <<"PATCH ":utf8, remaining:bits>> -> StepDone(#(http.Patch, remaining))
    <<"TRACE ":utf8, remaining:bits>> -> StepDone(#(http.Trace, remaining))
    <<"CONNECT ":utf8, remaining:bits>> -> StepDone(#(http.Connect, remaining))
    _other -> parse_other_method(line)
  }
}

fn parse_other_method(line: BitArray) -> Step(#(http.Method, BitArray)) {
  case find_space(line) {
    Error(Nil) -> ParseError(BadRequestLine)
    Ok(position) ->
      case line {
        <<name:bytes-size(position), " ":utf8, remaining:bits>> ->
          case bit_array_to_string(name) {
            Error(Nil) -> ParseError(BadMethod)
            Ok(name) ->
              case http.parse_method(name) {
                Ok(method) -> StepDone(#(method, remaining))
                Error(Nil) -> ParseError(BadMethod)
              }
          }
        _line -> ParseError(BadRequestLine)
      }
  }
}

fn parse_target_version(bits: BitArray) -> Step(#(BitArray, Version)) {
  let size = bit_array.byte_size(bits)

  case size < 10 {
    True -> ParseError(BadRequestLine)
    False -> {
      let target_size = size - 9
      case bits {
        <<target:bytes-size(target_size), " HTTP/1.1":utf8>> ->
          StepDone(#(target, Http11))
        <<target:bytes-size(target_size), " HTTP/1.0":utf8>> ->
          StepDone(#(target, Http10))
        _bits -> ParseError(BadVersion)
      }
    }
  }
}

// path[?query]. Used for every method except CONNECT.
fn split_target(target: BitArray) -> Step(#(String, option.Option(String))) {
  case find_question(target) {
    Error(Nil) -> {
      use path <- try_step(decode_component(target, BadTarget))
      StepDone(#(path, option.None))
    }
    Ok(position) -> {
      let size = bit_array.byte_size(target)

      case target {
        <<
          path:bytes-size(position),
          "?":utf8,
          query:bytes-size(size - position - 1),
        >> -> {
          use path <- try_step(decode_component(path, BadTarget))
          use query <- try_step(decode_component(query, BadTarget))
          StepDone(#(path, option.Some(query)))
        }
        _target -> ParseError(BadTarget)
      }
    }
  }
}

fn decode_component(bits: BitArray, on_error: ParseError) -> Step(String) {
  case bit_array_to_string(bits) {
    Ok(value) -> StepDone(value)
    Error(Nil) -> ParseError(on_error)
  }
}

// A path must be an absolute path except the "*" asterisk-form, which is only
// valid for OPTIONS (RFC 9112 §3.2).
fn validate_path(method: http.Method, path: String) -> Step(String) {
  case path, method {
    "*", http.Options -> StepDone(path)
    "/" <> _remaining, _method -> StepDone(path)
    _path, _method -> ParseError(BadTarget)
  }
}

// CONNECT's target is authority-form, every other method uses origin-form and
// gets its host from the Host header.
fn resolve_target(
  method: http.Method,
  target: BitArray,
  version: Version,
  header_host: option.Option(#(String, option.Option(Int))),
) -> Step(#(String, option.Option(Int), String, option.Option(String))) {
  case method {
    http.Connect ->
      // `target` is unvalidated wire bytes, so the host must go through real 
      // UTF-8 validation here.
      case split_host_port(target) {
        Ok(#(host, option.Some(_port) as port)) ->
          case bit_array_to_string(host) {
            Ok(host) -> StepDone(#(host, port, "", option.None))
            Error(Nil) -> ParseError(BadTarget)
          }
        Ok(#(_host, option.None)) -> ParseError(BadTarget)
        Error(Nil) -> ParseError(BadTarget)
      }
    _method -> {
      use #(path, query) <- try_step(split_target(target))
      use path <- try_step(validate_path(method, path))
      use #(host, port) <- try_step(resolve_host(version, header_host))
      StepDone(#(host, port, path, query))
    }
  }
}

// The `Host` header is required for HTTP/1.1 (RFC 9112 §3.2), optional for
// HTTP/1.0.
fn resolve_host(
  version: Version,
  header_host: option.Option(#(String, option.Option(Int))),
) -> Step(#(String, option.Option(Int))) {
  case header_host, version {
    option.Some(host_port), _version -> StepDone(host_port)
    option.None, Http10 -> StepDone(#("", option.None))
    option.None, Http11 -> ParseError(MissingHost)
  }
}

// Splits a `host[:port]` authority, respecting IPv6 literals in brackets.
// Returns the host as raw bytes, callers decide how to turn it into a
// `String`, since one of them already knows the bytes are valid UTF-8 and 
// the other doesn't.
fn split_host_port(
  value: BitArray,
) -> Result(#(BitArray, option.Option(Int)), Nil) {
  case value {
    <<"[":utf8, _remaining:bits>> -> split_bracketed_host(value)
    _value ->
      case find_colon(value) {
        Error(Nil) -> Ok(#(value, option.None))
        Ok(position) -> {
          let size = bit_array.byte_size(value)
          case value {
            <<
              host:bytes-size(position),
              ":":utf8,
              port:bytes-size(size - position - 1),
            >> ->
              case parse_port(port) {
                Ok(port) -> Ok(#(host, option.Some(port)))
                Error(Nil) -> Error(Nil)
              }
            _value -> Error(Nil)
          }
        }
      }
  }
}

fn split_bracketed_host(
  value: BitArray,
) -> Result(#(BitArray, option.Option(Int)), Nil) {
  case find_close_bracket(value) {
    Error(Nil) -> Error(Nil)
    Ok(position) -> {
      let size = bit_array.byte_size(value)

      case value {
        <<
          host:bytes-size(position + 1),
          remaining:bytes-size(size - position - 1),
        >> ->
          case remaining {
            <<>> -> Ok(#(host, option.None))
            <<":":utf8, port:bits>> ->
              case parse_port(port) {
                Ok(port) -> Ok(#(host, option.Some(port)))
                Error(Nil) -> Error(Nil)
              }
            _remaining -> Error(Nil)
          }
        _value -> Error(Nil)
      }
    }
  }
}

fn parse_port(bits: BitArray) -> Result(Int, Nil) {
  case bits {
    <<>> -> Error(Nil)
    _bits -> parse_port_digits(bits, 0)
  }
}

fn parse_port_digits(bits: BitArray, acc: Int) -> Result(Int, Nil) {
  case bits {
    <<>> ->
      case acc <= 65_535 {
        True -> Ok(acc)
        False -> Error(Nil)
      }
    <<byte, remaining:bits>> if byte >= 48 && byte <= 57 ->
      parse_port_digits(remaining, acc * 10 + { byte - 48 })
    _bits -> Error(Nil)
  }
}

// Threaded through `parse_headers`. 
type HeaderState {
  HeaderState(
    content_length: option.Option(Int),
    chunked: Bool,
    connection: option.Option(Bool),
    connection_upgrade: Bool,
    upgrade: option.Option(String),
    host: option.Option(#(String, option.Option(Int))),
  )
}

fn initial_header_state() -> HeaderState {
  HeaderState(
    content_length: option.None,
    chunked: False,
    connection: option.None,
    connection_upgrade: False,
    upgrade: option.None,
    host: option.None,
  )
}

// HTTP/1.1 connections default to persistent, HTTP/1.0 ones default to
// closing (RFC 9112 §9.3); an explicit `Connection` header overrides
// either default. A message framed by both `Content-Length` and
// `Transfer-Encoding` is rejected outright, since the two disagree on
// where the body ends. (RFC 9112 §6.1).
fn resolve_metadata(state: HeaderState, version: Version) -> Step(Metadata) {
  case state.content_length, state.chunked {
    option.Some(_length), True -> ParseError(AmbiguousFraming)
    content_length, chunked -> {
      let framing = case content_length, chunked {
        option.Some(length), False -> connection.Fixed(length)
        option.None, True -> connection.Chunked
        option.None, False -> connection.NoBody
        option.Some(_length), True ->
          panic as "AmbiguousFraming already rejected above"
      }
      let keep_alive = case state.connection, version {
        option.Some(keep_alive), _version -> keep_alive
        option.None, Http11 -> True
        option.None, Http10 -> False
      }
      let upgrade = case state.connection_upgrade {
        True -> state.upgrade
        False -> option.None
      }
      StepDone(Metadata(framing:, keep_alive:, upgrade:))
    }
  }
}

fn parse_headers(
  buffer: BitArray,
  acc: List(#(String, String)),
  count: Int,
  state: HeaderState,
) -> Step(#(List(#(String, String)), HeaderState, BitArray)) {
  use #(line, remaining) <- try_step(extract_line(
    buffer,
    max_header_line,
    HeaderLineTooLong,
    BadHeader,
  ))

  case line {
    <<>> -> StepDone(#(list.reverse(acc), state, remaining))
    _line if count >= max_headers -> ParseError(TooManyHeaders)
    _line -> {
      use #(header, state) <- try_step(parse_header_line(line, state))
      parse_headers(remaining, [header, ..acc], count + 1, state)
    }
  }
}

fn parse_header_line(
  line: BitArray,
  state: HeaderState,
) -> Step(#(#(String, String), HeaderState)) {
  case find_colon(line) {
    Error(Nil) -> ParseError(BadHeader)
    Ok(0) -> ParseError(BadHeader)
    Ok(position) ->
      case line {
        <<name:bytes-size(position), ":":utf8, value:bits>> -> {
          let name = lowercase_ascii(name)
          let value = trim_ows(value)
          case bit_array_to_string(name), bit_array_to_string(value) {
            Ok(name), Ok(value) -> {
              use state <- try_step(classify(name, value, state))
              StepDone(#(#(name, value), state))
            }
            _other, _other -> ParseError(BadHeader)
          }
        }
        _bad -> ParseError(BadHeader)
      }
  }
}

// Updates `content_length`, `chunked`, `connection`, `connection_upgrade`,
// `upgrade`, and `host` from a single already decoded header.
fn classify(
  name: String,
  value: String,
  state: HeaderState,
) -> Step(HeaderState) {
  case name {
    "content-length" ->
      case state.content_length {
        option.Some(_length) -> ParseError(DuplicateContentLength)
        option.None ->
          case int.parse(value) {
            Ok(length) if length >= 0 ->
              StepDone(
                HeaderState(..state, content_length: option.Some(length)),
              )
            _bad -> ParseError(BadContentLength)
          }
      }
    "transfer-encoding" -> {
      let lowered = value |> bit_array.from_string |> lowercase_ascii
      let chunked = state.chunked || has_token(lowered, <<"chunked":utf8>>)
      StepDone(HeaderState(..state, chunked:))
    }
    "connection" -> {
      let lowered = value |> bit_array.from_string |> lowercase_ascii
      let connection = case has_token(lowered, <<"close":utf8>>) {
        True -> option.Some(False)
        False ->
          case has_token(lowered, <<"keep-alive":utf8>>) {
            True -> option.Some(True)
            False -> state.connection
          }
      }
      let connection_upgrade =
        state.connection_upgrade || has_token(lowered, <<"upgrade":utf8>>)
      StepDone(HeaderState(..state, connection:, connection_upgrade:))
    }
    "upgrade" -> {
      // ASCII-lowered bytes of a validated `String` are valid UTF-8.
      let lowered =
        value
        |> bit_array.from_string
        |> lowercase_ascii
        |> unsafe_to_string
      StepDone(HeaderState(..state, upgrade: option.Some(lowered)))
    }
    "host" ->
      case state.host {
        option.Some(_host) -> ParseError(DuplicateHost)
        option.None ->
          // `value` is already a validated `String`. The split only slices
          // at ASCII delimiters, so the host bytes are still valid UTF-8
          // and don't need re-validating.
          case split_host_port(bit_array.from_string(value)) {
            Ok(#(host, port)) -> {
              let host = option.Some(#(unsafe_to_string(host), port))
              StepDone(HeaderState(..state, host:))
            }
            Error(Nil) -> ParseError(BadHost)
          }
      }
    _other -> StepDone(state)
  }
}

// Finds the next LF, then splits off the line without CRLF and the remaining.
fn extract_line(
  buffer: BitArray,
  max_len: Int,
  too_long: ParseError,
  malformed: ParseError,
) -> Step(#(BitArray, BitArray)) {
  case find_lf(buffer) {
    Error(Nil) ->
      case bit_array.byte_size(buffer) > max_len {
        True -> ParseError(too_long)
        False -> More
      }
    Ok(0) -> ParseError(malformed)
    Ok(position) ->
      case buffer {
        <<line:bytes-size(position - 1), "\r\n":utf8, remaining:bits>> ->
          StepDone(#(line, remaining))
        _bad -> ParseError(malformed)
      }
  }
}

// Returns input untouched if already lowercase, avoiding an allocation.
fn lowercase_ascii(bits: BitArray) -> BitArray {
  case has_uppercase(bits) {
    False -> bits
    True -> lowercase_walk(bits) |> list_to_bit_array
  }
}

fn has_uppercase(bits: BitArray) -> Bool {
  case bits {
    <<>> -> False
    <<byte, _remaining:bits>> if byte >= 65 && byte <= 90 -> True
    <<_byte, remaining:bits>> -> has_uppercase(remaining)
    _other -> False
  }
}

// Builds a byte list, lowercasing letters. Flattened by `list_to_bit_array`.
fn lowercase_walk(bits: BitArray) -> List(Int) {
  case bits {
    <<>> -> []
    <<"A", remaining:bits>> -> [0x61, ..lowercase_walk(remaining)]
    <<"B", remaining:bits>> -> [0x62, ..lowercase_walk(remaining)]
    <<"C", remaining:bits>> -> [0x63, ..lowercase_walk(remaining)]
    <<"D", remaining:bits>> -> [0x64, ..lowercase_walk(remaining)]
    <<"E", remaining:bits>> -> [0x65, ..lowercase_walk(remaining)]
    <<"F", remaining:bits>> -> [0x66, ..lowercase_walk(remaining)]
    <<"G", remaining:bits>> -> [0x67, ..lowercase_walk(remaining)]
    <<"H", remaining:bits>> -> [0x68, ..lowercase_walk(remaining)]
    <<"I", remaining:bits>> -> [0x69, ..lowercase_walk(remaining)]
    <<"J", remaining:bits>> -> [0x6A, ..lowercase_walk(remaining)]
    <<"K", remaining:bits>> -> [0x6B, ..lowercase_walk(remaining)]
    <<"L", remaining:bits>> -> [0x6C, ..lowercase_walk(remaining)]
    <<"M", remaining:bits>> -> [0x6D, ..lowercase_walk(remaining)]
    <<"N", remaining:bits>> -> [0x6E, ..lowercase_walk(remaining)]
    <<"O", remaining:bits>> -> [0x6F, ..lowercase_walk(remaining)]
    <<"P", remaining:bits>> -> [0x70, ..lowercase_walk(remaining)]
    <<"Q", remaining:bits>> -> [0x71, ..lowercase_walk(remaining)]
    <<"R", remaining:bits>> -> [0x72, ..lowercase_walk(remaining)]
    <<"S", remaining:bits>> -> [0x73, ..lowercase_walk(remaining)]
    <<"T", remaining:bits>> -> [0x74, ..lowercase_walk(remaining)]
    <<"U", remaining:bits>> -> [0x75, ..lowercase_walk(remaining)]
    <<"V", remaining:bits>> -> [0x76, ..lowercase_walk(remaining)]
    <<"W", remaining:bits>> -> [0x77, ..lowercase_walk(remaining)]
    <<"X", remaining:bits>> -> [0x78, ..lowercase_walk(remaining)]
    <<"Y", remaining:bits>> -> [0x79, ..lowercase_walk(remaining)]
    <<"Z", remaining:bits>> -> [0x7A, ..lowercase_walk(remaining)]
    <<byte, remaining:bits>> -> [byte, ..lowercase_walk(remaining)]
    _other -> []
  }
}

// ASCII-only OWS trim.
fn trim_ows(bits: BitArray) -> BitArray {
  bits
  |> trim_leading_ows
  |> trim_trailing_ows
}

fn trim_leading_ows(bits: BitArray) -> BitArray {
  case bits {
    <<" ", remaining:bits>> -> trim_leading_ows(remaining)
    <<"\t", remaining:bits>> -> trim_leading_ows(remaining)
    _bits -> bits
  }
}

fn trim_trailing_ows(bits: BitArray) -> BitArray {
  case bit_array.byte_size(bits) {
    0 -> bits
    size ->
      case bits {
        <<init:bytes-size(size - 1), " ":utf8>> -> trim_trailing_ows(init)
        <<init:bytes-size(size - 1), "\t":utf8>> -> trim_trailing_ows(init)
        _bits -> bits
      }
  }
}

// Exact-token match against a comma-separated header value.
fn has_token(value: BitArray, token: BitArray) -> Bool {
  case value == token {
    True -> True
    False ->
      split_comma(value)
      |> list.any(fn(part) { trim_ows(part) == token })
  }
}

@external(erlang, "http1_ffi", "find_lf")
fn find_lf(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "http1_ffi", "find_colon")
fn find_colon(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "http1_ffi", "find_space")
fn find_space(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "http1_ffi", "find_question")
fn find_question(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "http1_ffi", "find_close_bracket")
fn find_close_bracket(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "http1_ffi", "find_unsafe_header_byte")
fn find_unsafe_header_byte(bits: String) -> Result(Int, Nil)

@external(erlang, "http1_ffi", "split_comma")
fn split_comma(bits: BitArray) -> List(BitArray)

@external(erlang, "http1_ffi", "list_to_bit_array")
fn list_to_bit_array(bytes: List(Int)) -> BitArray

// Validates UTF-8 via native BIFs, I assume should be faster than
// `bit_array.to_string`.
@external(erlang, "http1_ffi", "bit_array_to_string")
fn bit_array_to_string(bits: BitArray) -> Result(String, Nil)

// Used only for bytes already proven valid UTF-8 elsewhere!!
@external(erlang, "ewe_ffi", "identity")
fn unsafe_to_string(bits: BitArray) -> String
