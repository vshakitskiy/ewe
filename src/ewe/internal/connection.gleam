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
  )
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
}
