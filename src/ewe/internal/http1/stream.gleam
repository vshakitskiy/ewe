import ewe/internal/connection
import ewe/internal/http1/connection as http1
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/result
import tup/socket

pub type Event(user_message) {
  UserMessage(user_message)
  Packet(BitArray)
  Closed
  Failed(reason: String)
  Exhausted
  Exited(connection.Exit)
}

pub fn selector(
  messages: process.Selector(user_message),
) -> process.Selector(Event(user_message)) {
  process.map_selector(messages, UserMessage)
  |> process.select_record(atom.create("tcp"), 2, packet)
  |> process.select_record(atom.create("ssl"), 2, packet)
  |> process.select_record(atom.create("tcp_closed"), 1, closed)
  |> process.select_record(atom.create("ssl_closed"), 1, closed)
  |> process.select_record(atom.create("tcp_error"), 2, failed)
  |> process.select_record(atom.create("ssl_error"), 2, failed)
  |> process.select_record(atom.create("tcp_passive"), 1, exhausted)
  |> process.select_record(atom.create("ssl_passive"), 1, exhausted)
  |> connection.select_exits(Exited)
}

fn packet(record: dynamic.Dynamic) -> Event(user_message) {
  Packet(socket_payload(record))
}

fn closed(_record: dynamic.Dynamic) -> Event(user_message) {
  Closed
}

fn failed(record: dynamic.Dynamic) -> Event(user_message) {
  socket_error_reason(record)
  |> socket.describe_error
  |> Failed
}

fn exhausted(_record: dynamic.Dynamic) -> Event(user_message) {
  Exhausted
}

pub fn activate(
  transport: socket.Transport,
  socket: socket.Socket,
) -> Result(Nil, socket.SocketError) {
  socket.set_options(transport, socket, [
    socket.Active(socket.Packets(http1.active_count)),
  ])
  |> result.replace_error(socket.Closed)
}

@external(erlang, "ewe_http1_ffi", "socket_error_reason")
fn socket_error_reason(record: dynamic.Dynamic) -> socket.SocketError

@external(erlang, "ewe_websocket_ffi", "socket_payload")
fn socket_payload(record: dynamic.Dynamic) -> BitArray
