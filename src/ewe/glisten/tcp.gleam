import ewe/glisten/socket.{type ListenSocket, type Socket, type SocketReason}
import ewe/glisten/socket/options.{type TcpOption}
import gleam/bytes_tree.{type BytesTree}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/list

@external(erlang, "ewe_glisten_tcp_ffi", "controlling_process")
pub fn controlling_process(socket: Socket, pid: Pid) -> Result(Nil, Atom)

@external(erlang, "gen_tcp", "listen")
fn do_listen_tcp(
  port: Int,
  options: List(options.ErlangTcpOption),
) -> Result(ListenSocket, SocketReason)

@external(erlang, "gen_tcp", "accept")
pub fn accept_timeout(
  socket: ListenSocket,
  timeout: Int,
) -> Result(Socket, SocketReason)

@external(erlang, "gen_tcp", "accept")
pub fn accept(socket: ListenSocket) -> Result(Socket, SocketReason)

@external(erlang, "gen_tcp", "recv")
pub fn receive_timeout(
  socket: Socket,
  length: Int,
  timeout: Int,
) -> Result(BitArray, SocketReason)

@external(erlang, "gen_tcp", "recv")
pub fn receive(socket: Socket, length: Int) -> Result(BitArray, SocketReason)

@external(erlang, "ewe_glisten_tcp_ffi", "send")
pub fn send(socket: Socket, packet: BytesTree) -> Result(Nil, SocketReason)

@external(erlang, "socket", "info")
pub fn socket_info(socket: Socket) -> Dict(a, b)

@external(erlang, "ewe_glisten_tcp_ffi", "close")
pub fn close(socket: a) -> Result(Nil, SocketReason)

@external(erlang, "ewe_glisten_tcp_ffi", "shutdown")
pub fn do_shutdown(socket: Socket, write: Atom) -> Result(Nil, SocketReason)

pub fn shutdown(socket: Socket) -> Result(Nil, SocketReason) {
  do_shutdown(socket, atom.create("write"))
}

@external(erlang, "ewe_glisten_tcp_ffi", "set_opts")
fn do_set_opts(
  socket: Socket,
  opts: List(options.ErlangTcpOption),
) -> Result(Nil, SocketReason)

/// Update the optons for a socket (mutates the socket)
pub fn set_opts(
  socket: Socket,
  opts: List(TcpOption),
) -> Result(Nil, SocketReason) {
  opts
  |> options.to_erl_options()
  |> do_set_opts(socket, _)
}

/// Start listening over TCP on a port with the given options
pub fn listen(
  port: Int,
  opts: List(TcpOption),
) -> Result(ListenSocket, SocketReason) {
  let is_unix =
    list.any(opts, fn(option) {
      case option {
        options.Ip(options.UnixPath(_)) -> True
        _ -> False
      }
    })

  let merged = case is_unix {
    True -> options.merge_with_unix_defaults(opts)
    False -> options.merge_with_tcp_defaults(opts)
  }

  options.to_erl_options(merged)
  |> do_listen_tcp(port, _)
}

pub fn handshake(socket: Socket) -> Result(Socket, Nil) {
  Ok(socket)
}

@external(erlang, "tcp", "negotiated_protocol")
pub fn negotiated_protocol(socket: Socket) -> a

@external(erlang, "ewe_glisten_tcp_ffi", "peername")
pub fn peername(socket: Socket) -> Result(socket.SockName, SocketReason)

@external(erlang, "inet", "getopts")
pub fn get_socket_opts(
  socket: Socket,
  opts: List(Atom),
) -> Result(List(#(Atom, Dynamic)), SocketReason)

@external(erlang, "ewe_glisten_tcp_ffi", "sockname")
pub fn sockname(socket: ListenSocket) -> Result(socket.SockName, SocketReason)
