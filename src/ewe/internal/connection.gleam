import gleam/bytes_tree
import gleam/erlang/process
import glisten/socket
import glisten/transport

pub type Connection {
  Http1(
    transport: transport.Transport,
    socket: socket.Socket,
    self: process.Subject(Http1Signal),
    buffer: BitArray,
    framing: Framing,
    // Body bytes delivered to the caller so far, via `read_body_chunk`.
    read: Int,
    // Bytes left in the chunked-encoding chunk currently being delivered;
    // 0 means the next pull starts at a chunk boundary. Unused for `Fixed`
    // and `NoBody`.
    chunk_remaining: Int,
  )
  Http2
}

/// How to find the end of a request body on the wire, derived once from
/// `Content-Length` or `Transfer-Encoding` at parse time.
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
  Streaming(handler: fn(ResponseWriter) -> Nil)
}

pub type File {
  FileMetadata(path: String, offset: Int, length: Int)
}

/// Out-of-band events for a connection's own actor loop.
pub type Message {
  Timeout
}

/// Sent by `http1.gleam` to a request's own private subject, drained
/// synchronously within the same `http1.handle_message` call
pub type Http1Signal {
  /// Sent by `http1.read_body` and `http1.read_body_chunk` to themselves
  /// once the request body has been fully consumed, carrying whatever bytes
  /// came after it.
  BodyDrained(leftover: BitArray)
  /// Sent by `http1.read_body` and `http1.read_body_chunk` to themselves
  /// when they gave up on the body part-way through, leaving the connection
  /// in an unknown position.
  BodyAbandoned
  /// Sent by `http1.read_body_chunk` to itself after every chunk it
  /// delivers, so that if the caller stops reading before `BodyDrained`,
  /// the connection can still resume draining from here instead of from the
  /// start of the body.
  BodyProgress(buffer: BitArray, read: Int, chunk_remaining: Int)
  /// Sent by `http1.finish_chunk` and `http1.finish_response` to themselves once
  /// a streamed response's terminator has been written.
  StreamFinished(keep_alive: Bool)
}

/// How a streamed response writes its body chunks to the wire.
pub type ResponseWriter {
  Http1Writer(
    transport: transport.Transport,
    socket: socket.Socket,
    self: process.Subject(Http1Signal),
    // `True` on HTTP/1.1. Frame each chunk with its hex size and a trailing
    // `0\r\n\r\n` terminator. 
    //
    // `False` on HTTP/1.0, which has no chunked encoding write raw bytes and 
    // let the body end when the connection closes.
    chunked: Bool,
    // Whether the connection should stay alive once the stream finishes. Always 
    // `False` when `chunked` is `False`.
    keep_alive: Bool,
  )
  Http2Writer
}
