import gleam/erlang/process
import glisten/socket
import glisten/transport

/// A handler's HTTP/1 connection. Where to write, where to report back to, 
/// and how much of the request body is still unread.
pub type Connection {
  Connection(
    transport: transport.Transport,
    socket: socket.Socket,
    self: process.Subject(Signal),
    buffer: BitArray,
    framing: Framing,
    read: Int,
    chunk_remaining: Int,
  )
}

/// How the request body declares its length.
pub type Framing {
  Fixed(length: Int)
  Chunked
  NoBody
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
