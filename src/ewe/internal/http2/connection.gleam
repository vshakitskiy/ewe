import ewe/glisten/socket
import gleam/dynamic
import gleam/erlang/process
import gleam/erlang/reference
import gleam/http/response
import gleam/option
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
    max_concurrent_streams: option.None,
    initial_window_size: 2_097_152,
    max_frame_size: 16_384,
    max_header_list_size: option.Some(32_768),
    header_table_size: 4096,
    max_continuation_frames: 100,
    max_header_block_bytes: 65_536,
    rapid_reset_window_ms: 10_000,
    rapid_reset_threshold: 100,
    handshake_timeout_ms: 10_000,
    drain_timeout_ms: 4000,
    recv_window_low_water_mark: 262_144,
    recv_window_high_water_mark: 2_097_152,
    websocket: False,
    send_buffer_limit: 1_048_576,
    file_read_threshold: 1_048_576,
    body_read_timeout: 10_000,
  )
}

pub type Connection(body) {
  Connection(
    connection: process.Subject(Reply(body)),
    stream_id: Int,
    has_body: Bool,
    pending: BitArray,
    pending_trailers: option.Option(List(#(String, String))),
    read: Int,
    body_read_timeout: Int,
    peer: Result(socket.SockName, Nil),
    protocol: option.Option(String),
  )
}

pub type Reply(body) {
  Respond(stream_id: Int, response: response.Response(body))
  ReadBody(stream_id: Int, reply_to: process.Subject(BodyEvent))
  WriteHeaders(
    stream_id: Int,
    ack: process.Subject(WriteAck),
    status: Int,
    headers: List(#(String, String)),
    mode: ResponseMode,
  )
  PushData(stream_id: Int, chunk: Chunk)
}

pub type ResponseMode {
  PlainStream
  EventStream
  WebsocketStream(notify: process.Subject(StreamSignal))
}

pub type StreamSignal {
  Draining
}

pub type Chunk {
  Chunk(bytes: BitArray, ack: option.Option(process.Subject(WriteAck)))
  Finish(bytes: BitArray, ack: option.Option(process.Subject(WriteAck)))
}

pub type BodyEvent {
  ChunkEvent(BitArray)
  LastChunkEvent(BitArray, trailers: List(#(String, String)))
  DoneEvent(trailers: List(#(String, String)))
}

pub type WriteAck {
  WriteAck
}

pub type ResponseWriter(body) {
  ResponseWriter(
    connection: process.Subject(Reply(body)),
    stream_id: Int,
    ack: process.Subject(WriteAck),
    ack_ref: reference.Reference,
  )
}

pub type SseConnection(body) {
  SseConnection(writer: ResponseWriter(body))
}

pub type WebsocketConnection(body) {
  WebsocketConnection(
    writer: ResponseWriter(body),
    context: websocks.Context,
    body: process.Subject(BodyEvent),
    signals: process.Subject(StreamSignal),
  )
}

pub type Interrupted {
  StreamReset
  ConnectionClosed
  TimedOut
}

@external(erlang, "ewe_http2_ffi", "recv_or_exit")
pub fn receive_reply(tag: reference.Reference) -> Result(message, Interrupted)

@external(erlang, "ewe_http2_ffi", "recv_or_exit")
pub fn receive_reply_within(
  tag: reference.Reference,
  timeout: Int,
) -> Result(message, Interrupted)

@external(erlang, "ewe_ffi", "identity")
pub fn tag(reference: reference.Reference) -> dynamic.Dynamic

@external(erlang, "ewe_http2_ffi", "parent_pid")
pub fn parent_pid() -> Result(process.Pid, Nil)

@external(erlang, "ewe_http2_ffi", "is_shutdown")
pub fn is_shutdown(reason: dynamic.Dynamic) -> Bool
