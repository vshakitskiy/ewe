import gleam/erlang/process
import gleam/option
import glisten/socket
import glisten/transport
import websocks

/// The limits and timeouts an HTTP/1 connection is held to.
pub type Config {
  Config(
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

pub fn default_config() -> Config {
  Config(
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
    config: Config,
    upgrade: option.Option(Upgrade),
  )
}

/// How many socket messages a stream is delivered before it has to ask for
/// more. Bounded so a peer that keeps sending cannot grow the mailbox faster
/// than the loop drains it.
pub const active_count = 100

/// How the request body declares its length.
pub type Framing {
  Fixed(length: Int)
  Chunked
  NoBody
}

/// What a request asked to become instead of HTTP/1, gathered as the headers
/// go past rather than looked up again afterwards. Whether the fields amount to
/// a handshake is for whoever answers it to decide.
pub type Upgrade {
  WebsocketUpgrade(
    key: option.Option(String),
    version: option.Option(String),
    extensions: option.Option(String),
  )
  OtherUpgrade(name: String)
}

/// Handlers run inside the connection process, so they report what they did to
/// the request body and the response stream by messaging it.
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

/// Whether the connection survives the response, or is closed once it is done.
pub type KeepAlive {
  KeepAlive
  CloseAfterResponse
}

/// The connection is only reusable when every party to the exchange agrees.
pub fn and_keep_alive(left: KeepAlive, right: KeepAlive) -> KeepAlive {
  case left {
    KeepAlive -> right
    CloseAfterResponse -> CloseAfterResponse
  }
}

/// How a streamed response body delimits itself: `chunked` transfer encoding on
/// HTTP/1.1, or by closing the connection on HTTP/1.0.
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

/// The connection has stopped being HTTP by this point so there is nothing to
/// keep alive and nothing to report back about reuse.
pub type WebsocketConnection {
  WebsocketConnection(
    transport: transport.Transport,
    socket: socket.Socket,
    context: websocks.Context,
  )
}
