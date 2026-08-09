import gleam/dynamic
import gleam/erlang/process
import gleam/erlang/reference
import gleam/http/response
import gleam/option
import glisten/socket

/// The limits and timeouts an HTTP/2 connection is held to.
pub type Config {
  Config(
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
    file_read_threshold: Int,
    body_read_timeout: Int,
  )
}

pub fn default_config() -> Config {
  Config(
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
    file_read_threshold: 1_048_576,
    body_read_timeout: 10_000,
  )
}

/// What a handler holds for one stream. The handler gets its own process, not
/// the connection's. Reading the body and writing the response are messages,
/// not socket writes.
///
/// The body type is a parameter to break the import cycle with the module that
/// defines it.
pub type Connection(body) {
  Connection(
    connection: process.Subject(Reply(body)),
    stream_id: Int,
    has_body: Bool,
    /// Body bytes handed over but not yet returned to the caller.
    pending: BitArray,
    pending_trailers: option.Option(List(#(String, String))),
    /// Body bytes read so far. `read_body_chunk` caps its limit against this.
    read: Int,
    body_read_timeout: Int,
    /// Resolved once for the connection. A stream process has no socket to
    /// ask.
    peer: Result(socket.SockName, Nil),
  )
}

/// What a stream process asks of the connection process.
pub type Reply(body) {
  Respond(stream_id: Int, response: response.Response(body))
  ReadBody(stream_id: Int, reply_to: process.Subject(BodyEvent))
  WriteHeaders(
    stream_id: Int,
    ack: process.Subject(WriteAck),
    status: Int,
    headers: List(#(String, String)),
    reserved: Reserved,
  )
  WriteData(
    stream_id: Int,
    ack: process.Subject(WriteAck),
    chunk: BitArray,
    end_stream: Bool,
  )
}

/// Which headers the connection sets itself for a streamed body. They get
/// dropped from the handler's list so nothing goes out twice.
pub type Reserved {
  Nothing
  SseHeaders
}

pub type BodyEvent {
  ChunkEvent(BitArray)
  LastChunkEvent(BitArray, trailers: List(#(String, String)))
  DoneEvent(trailers: List(#(String, String)))
}

pub type WriteAck {
  WriteAck
}

/// A handle for writing a response a frame at a time. The connection tags its
/// acks with the reference so a stream waits on it directly, no selector.
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

/// Why a stream process stopped waiting. Only a body read times out. It is the
/// one wait that hangs on the client.
pub type Interrupted {
  StreamReset
  ConnectionClosed
  TimedOut
}

/// Waits for the connection to answer. Gives up if the stream resets or the
/// connection goes.
@external(erlang, "http2_ffi", "recv_or_exit")
pub fn receive_reply(tag: reference.Reference) -> Result(message, Interrupted)

@external(erlang, "http2_ffi", "recv_or_exit")
pub fn receive_reply_within(
  tag: reference.Reference,
  timeout: Int,
) -> Result(message, Interrupted)

/// `unsafely_create_subject` wants the tag the messages carry and the
/// connection tags replies with a reference, so the two meet as `Dynamic`.
/// Waiting on the reference directly saves building a selector per chunk.
@external(erlang, "ewe_ffi", "identity")
pub fn tag(reference: reference.Reference) -> dynamic.Dynamic
