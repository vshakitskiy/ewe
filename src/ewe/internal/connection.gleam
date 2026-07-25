import gleam/bytes_tree
import gleam/erlang/process
import glisten/socket
import glisten/transport

pub type Connection {
  Http1(Http1Connection)
  Http2
}

pub type Http1Connection {
  Http1Connection(
    transport: transport.Transport,
    socket: socket.Socket,
    self: process.Subject(Http1Signal),
    buffer: BitArray,
    framing: Framing,
    read: Int,
    chunk_remaining: Int,
  )
}

pub type Framing {
  Fixed(length: Int)
  Chunked
  NoBody
}

pub type Body {
  Bytes(bytes_tree.BytesTree)
  Text(String)
  Empty
  File(File)
  Streaming(Streaming)
  Sse(Sse)
}

pub type Sse {
  SseMetadata(handler: fn(SseConnection) -> Outcome)
}

pub type Streaming {
  StreamingMetadata(handler: fn(ResponseWriter) -> Nil)
}

pub type File {
  FileMetadata(path: String, offset: Int, length: Int)
}

pub type Message {
  Timeout
}

pub type Http1Signal {
  BodyDrained(leftover: BitArray)
  BodyAbandoned
  BodyProgress(buffer: BitArray, read: Int, chunk_remaining: Int)
  StreamFinished(keep_alive: Bool)
}

pub type ResponseWriter {
  Http1Writer(Http1ResponseWriter)
  Http2Writer
}

pub type Http1ResponseWriter {
  Http1ResponseWriter(
    transport: transport.Transport,
    socket: socket.Socket,
    self: process.Subject(Http1Signal),
    chunked: Bool,
    keep_alive: Bool,
  )
}

pub type Outcome {
  Stopped
  StoppedAbnormal(reason: String)
}

pub type SseConnection {
  Http1Sse(Http1SseConnection)
  Http2Sse
}

pub type Http1SseConnection {
  Http1SseConnection(transport: transport.Transport, socket: socket.Socket)
}
