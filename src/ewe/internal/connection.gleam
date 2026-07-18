import gleam/bytes_tree
import gleam/erlang/process
import glisten/internal/handler
import glisten/socket
import glisten/transport

pub type Connection {
  Http1(
    transport: transport.Transport,
    socket: socket.Socket,
    self: process.Subject(handler.Message(Message)),
    buffer: BitArray,
    framing: Framing,
  )
  Http2
}

/// How to find the end of a request body on the wire, derived once from
/// `Content-Length`/`Transfer-Encoding` at parse time.
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
}

pub type File {
  FileMetadata(path: String, offset: Int, length: Int)
}

pub type Message {
  Timeout
  /// Sent by `http1.read_body` to itself once the request body has been
  /// fully consumed, carrying whatever bytes came after it.
  BodyDrained(leftover: BitArray)
  /// Sent by `http1.read_body` to itself when it gave up on the body
  /// part-way through, leaving the connection in an unknown position.
  BodyAbandoned
}
