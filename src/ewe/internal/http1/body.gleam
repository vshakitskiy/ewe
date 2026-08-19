import ewe/internal/connection
import ewe/internal/http1/connection as http1
import ewe/internal/http1/parser
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/int
import gleam/result
import glisten/socket
import glisten/transport

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
  transport: transport.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  length: Int,
  timeout: Int,
) -> Result(#(BitArray, BitArray), parser.ParseError) {
  case buffer {
    <<data:bytes-size(length), leftover:bits>> -> Ok(#(data, leftover))
    _buffer ->
      case
        transport.receive_timeout(
          transport,
          socket,
          length - bit_array.byte_size(buffer),
          timeout,
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
  transport: transport.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  timeout: Int,
  step: fn(BitArray) -> parser.Step(a),
) -> Result(a, parser.ParseError) {
  case step(buffer) {
    parser.StepDone(value) -> Ok(value)
    parser.ParseError(error) -> Error(error)
    parser.More ->
      case transport.receive_timeout(transport, socket, 0, timeout) {
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
