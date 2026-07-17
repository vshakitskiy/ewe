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

pub type Message {
  Timeout
}
