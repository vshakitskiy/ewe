import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic
import gleam/erlang/process
import gleam/erlang/reference
import gleam/option
import tup
import websocks

pub type Options {
  Options(
    max_concurrent_streams: option.Option(Int),
    initial_window_size: Int,
    max_frame_size: Int,
    max_header_list_size: option.Option(Int),
    header_table_size: Int,
    max_continuation_frames: Int,
    max_header_block_bytes: Int,
    rapid_reset_window_ms: Int,
    rapid_reset_threshold: Int,
    handshake_timeout_ms: Int,
    drain_timeout_ms: Int,
    idle_timeout_ms: Int,
    recv_window_low_water_mark: Int,
    recv_window_high_water_mark: Int,
    websocket: Bool,
    send_buffer_limit: Int,
    file_read_threshold: Int,
    body_read_timeout: Int,
  )
}

pub fn default_options() -> Options {
  Options(
    max_concurrent_streams: option.Some(100),
    initial_window_size: 262_144,
    max_frame_size: 16_384,
    max_header_list_size: option.Some(32_768),
    header_table_size: 4096,
    max_continuation_frames: 100,
    max_header_block_bytes: 65_536,
    rapid_reset_window_ms: 10_000,
    rapid_reset_threshold: 100,
    handshake_timeout_ms: 10_000,
    drain_timeout_ms: 4000,
    idle_timeout_ms: 60_000,
    recv_window_low_water_mark: 65_536,
    recv_window_high_water_mark: 262_144,
    websocket: True,
    send_buffer_limit: 1_048_576,
    file_read_threshold: 1_048_576,
    body_read_timeout: 10_000,
  )
}

pub type Connection {
  Connection(
    commands: process.Subject(Command),
    stream_id: Int,
    has_body: Bool,
    pending: BitArray,
    pending_trailers: option.Option(List(#(String, String))),
    bytes_read: Int,
    body_read_timeout: Int,
    peer: tup.Endpoint,
    protocol: option.Option(String),
  )
}

pub type Command {
  ReadBody(stream_id: Int, reply_to: process.Subject(BodyEvent))
  WriteHeaders(
    stream_id: Int,
    ack: process.Subject(WriteAck),
    status: Int,
    headers: List(#(String, String)),
    signals: option.Option(process.Subject(StreamSignal)),
  )
  WriteData(
    stream_id: Int,
    data: BitArray,
    end_stream: Bool,
    ack: process.Subject(WriteAck),
  )
}

pub type StreamSignal {
  Draining
}

pub type BodyEvent {
  ChunkEvent(BitArray)
  LastChunkEvent(BitArray, trailers: List(#(String, String)))
  DoneEvent(trailers: List(#(String, String)))
}

pub type WriteAck {
  Written
  Ended
}

pub type ResponseWriter {
  ResponseWriter(
    commands: process.Subject(Command),
    stream_id: Int,
    ack: process.Subject(WriteAck),
    ack_ref: reference.Reference,
  )
}

pub type SseConnection {
  SseConnection(writer: ResponseWriter, signals: process.Subject(StreamSignal))
}

pub type WebsocketConnection {
  WebsocketConnection(
    writer: ResponseWriter,
    context: websocks.Context,
    body: process.Subject(BodyEvent),
    signals: process.Subject(StreamSignal),
  )
}

pub type Interrupted {
  StreamReset
  StreamEnded
  ConnectionClosed
  TimedOut
}

pub fn interrupted_to_string(interrupted: Interrupted) -> String {
  case interrupted {
    StreamReset -> "the client reset the stream"
    StreamEnded -> "the response had already ended"
    ConnectionClosed -> "the connection closed"
    TimedOut -> "the client did not read the response in time"
  }
}

@external(erlang, "ewe_ffi", "recv_or_exit")
pub fn receive_reply(tag: reference.Reference) -> Result(message, Interrupted)

@external(erlang, "ewe_ffi", "recv_or_exit")
pub fn receive_reply_within(
  tag: reference.Reference,
  timeout: Int,
) -> Result(message, Interrupted)

@external(erlang, "ewe_ffi", "identity")
pub fn tag(reference: reference.Reference) -> dynamic.Dynamic

@external(erlang, "ewe_ffi", "is_shutdown")
pub fn is_shutdown(reason: dynamic.Dynamic) -> Bool

pub type BodyError {
  BodyTooLarge
  InvalidBody
}

pub fn read_body(
  connection: Connection,
  limit: Int,
) -> Result(#(BitArray, List(#(String, String))), BodyError) {
  case connection.has_body {
    False -> Ok(#(<<>>, []))
    True -> read_all(connection, limit, bytes_tree.new())
  }
}

fn read_all(
  connection: Connection,
  limit: Int,
  acc: bytes_tree.BytesTree,
) -> Result(#(BitArray, List(#(String, String))), BodyError) {
  case next_chunk(connection) {
    Error(error) -> Error(error)
    Ok(Done(trailers)) -> Ok(#(bytes_tree.to_bit_array(acc), trailers))
    Ok(Chunk(data, connection)) ->
      case connection.bytes_read > limit {
        True -> Error(BodyTooLarge)
        False -> read_all(connection, limit, bytes_tree.append(acc, data))
      }
  }
}

pub type ReadEvent {
  Chunk(data: BitArray, connection: Connection)
  Done(trailers: List(#(String, String)))
}

pub fn read_body_chunk(
  connection: Connection,
  max_chunk_bytes max_chunk_bytes: Int,
  limit limit: Int,
) -> Result(ReadEvent, BodyError) {
  case next_chunk(connection) {
    Error(error) -> Error(error)
    Ok(Done(trailers)) -> Ok(Done(trailers))
    Ok(Chunk(data, connection)) ->
      case connection.bytes_read > limit {
        True -> Error(BodyTooLarge)
        False -> Ok(split(connection, data, max_chunk_bytes))
      }
  }
}

fn split(
  connection: Connection,
  data: BitArray,
  max_chunk_bytes: Int,
) -> ReadEvent {
  case data {
    <<chunk:bytes-size(max_chunk_bytes), pending:bits>> ->
      Chunk(chunk, Connection(..connection, pending:))
    _data -> Chunk(data, Connection(..connection, pending: <<>>))
  }
}

fn next_chunk(connection: Connection) -> Result(ReadEvent, BodyError) {
  case connection.has_body, connection.pending, connection.pending_trailers {
    False, _pending, _trailers -> Ok(Done([]))
    True, <<>>, option.Some(trailers) -> Ok(Done(trailers))
    True, <<>>, option.None -> pull(connection)
    True, pending, _trailers ->
      Ok(Chunk(pending, Connection(..connection, pending: <<>>)))
  }
}

fn pull(connection: Connection) -> Result(ReadEvent, BodyError) {
  let reply_ref = reference.new()
  let reply_to = process.unsafely_create_subject(process.self(), tag(reply_ref))

  process.send(connection.commands, ReadBody(connection.stream_id, reply_to))

  case receive_reply_within(reply_ref, connection.body_read_timeout) {
    Error(_interrupted) -> Error(InvalidBody)
    Ok(DoneEvent(trailers)) -> Ok(Done(trailers))
    Ok(ChunkEvent(data)) -> Ok(Chunk(data, count_read(connection, data)))
    Ok(LastChunkEvent(data, trailers)) ->
      Ok(Chunk(
        data,
        Connection(
          ..count_read(connection, data),
          pending_trailers: option.Some(trailers),
        ),
      ))
  }
}

fn count_read(connection: Connection, data: BitArray) -> Connection {
  Connection(
    ..connection,
    bytes_read: connection.bytes_read + bit_array.byte_size(data),
  )
}
