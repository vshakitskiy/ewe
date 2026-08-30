import ewe/glisten/socket.{type ListenSocket, type Socket, type SocketReason}
import ewe/glisten/socket/options
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}

@external(erlang, "ewe_glisten_ssl_ffi", "controlling_process")
pub fn controlling_process(socket: Socket, pid: Pid) -> Result(Nil, Atom)

@external(erlang, "ssl", "listen")
fn do_listen(
  port: Int,
  options: List(options.ErlangTcpOption),
) -> Result(ListenSocket, SocketReason)

@external(erlang, "ssl", "transport_accept")
pub fn accept(socket: ListenSocket) -> Result(Socket, SocketReason)

@external(erlang, "ssl", "recv")
pub fn receive_timeout(
  socket: Socket,
  length: Int,
  timeout: Int,
) -> Result(BitArray, SocketReason)

@external(erlang, "ewe_glisten_ssl_ffi", "send")
pub fn send(socket: Socket, packet: BytesTree) -> Result(Nil, SocketReason)

@external(erlang, "ewe_glisten_ssl_ffi", "close")
pub fn close(socket: Socket) -> Result(Nil, SocketReason)

@external(erlang, "ewe_glisten_ssl_ffi", "set_opts")
fn do_set_opts(
  socket: Socket,
  opts: List(options.ErlangTcpOption),
) -> Result(Nil, SocketReason)

/// Update the optons for a socket (mutates the socket)
pub fn set_opts(
  socket: Socket,
  opts: List(options.TcpOption),
) -> Result(Nil, SocketReason) {
  opts
  |> options.to_erl_options()
  |> do_set_opts(socket, _)
}

@external(erlang, "ssl", "handshake")
pub fn handshake(socket: Socket) -> Result(Socket, Nil)

/// Start listening over TLS on a port with the given options
pub fn listen(
  port: Int,
  options: List(options.TcpOption),
) -> Result(ListenSocket, SocketReason) {
  options
  |> options.merge_with_tcp_defaults
  |> options.to_erl_options
  |> do_listen(port, _)
}

@external(erlang, "ewe_glisten_ssl_ffi", "peername")
pub fn peername(socket: Socket) -> Result(socket.SockName, SocketReason)

@external(erlang, "ewe_glisten_ssl_ffi", "sockname")
pub fn sockname(socket: ListenSocket) -> Result(socket.SockName, SocketReason)

@external(erlang, "ssl", "getopts")
pub fn get_socket_opts(
  socket: Socket,
  opts: List(Atom),
) -> Result(List(#(Atom, Dynamic)), SocketReason)
