import gleam/erlang/process
import gleam/option
import glisten/socket
import glisten/transport
import websocks

pub type Options {
  Options(
    max_request_line: Int,
    max_header_line: Int,
    max_headers: Int,
    max_chunk_size_line: Int,
    idle_timeout: Int,
    body_read_timeout: Int,
    auto_drain_limit: Int,
    auto_drain_chunk_bytes: Int,
  )
}

pub fn default_options() -> Options {
  Options(
    max_request_line: 8192,
    max_header_line: 8192,
    max_headers: 100,
    max_chunk_size_line: 128,
    idle_timeout: 10_000,
    body_read_timeout: 10_000,
    auto_drain_limit: 1_048_576,
    auto_drain_chunk_bytes: 65_536,
  )
}

pub type Connection {
  Connection(
    transport: transport.Transport,
    socket: socket.Socket,
    self: process.Subject(Signal),
    buffer: BitArray,
    framing: Framing,
    read: Int,
    chunk_remaining: Int,
    options: Options,
    upgrade: option.Option(Upgrade),
  )
}

pub const active_count = 100

pub type Framing {
  Fixed(length: Int)
  Chunked
  NoBody
}

pub type Upgrade {
  WebsocketUpgrade(
    key: option.Option(String),
    version: option.Option(String),
    extensions: option.Option(String),
  )
  OtherUpgrade(name: String)
}

pub type Signal {
  BodySignal(BodySignal)
  StreamSignal(StreamSignal)
}

pub type BodySignal {
  BodyDrained(leftover: BitArray)
  BodyAbandoned
  BodyProgress(buffer: BitArray, read: Int, chunk_remaining: Int)
}

pub type StreamSignal {
  StreamFinished(keep_alive: KeepAlive)
}

pub type ResponseWriter {
  ResponseWriter(
    transport: transport.Transport,
    socket: socket.Socket,
    self: process.Subject(Signal),
    framing: StreamFraming,
    keep_alive: KeepAlive,
  )
}

pub type KeepAlive {
  KeepAlive
  CloseAfterResponse
}

pub fn and_keep_alive(left: KeepAlive, right: KeepAlive) -> KeepAlive {
  case left {
    KeepAlive -> right
    CloseAfterResponse -> CloseAfterResponse
  }
}

pub type StreamFraming {
  ChunkedStream
  CloseDelimitedStream
}

pub type SseConnection {
  SseConnection(
    transport: transport.Transport,
    socket: socket.Socket,
    self: process.Subject(Signal),
    framing: StreamFraming,
  )
}

pub type WebsocketConnection {
  WebsocketConnection(
    transport: transport.Transport,
    socket: socket.Socket,
    context: websocks.Context,
  )
}
