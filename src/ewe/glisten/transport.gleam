import ewe/glisten/socket.{type ListenSocket, type Socket, type SocketReason}
import ewe/glisten/socket/options
import ewe/glisten/ssl
import ewe/glisten/tcp
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/result

pub type Transport {
  Tcp
  Ssl
}

pub fn controlling_process(
  transport: Transport,
  socket: Socket,
  pid: Pid,
) -> Result(Nil, Atom) {
  case transport {
    Tcp -> tcp.controlling_process(socket, pid)
    Ssl -> ssl.controlling_process(socket, pid)
  }
}

pub fn listen(
  transport: Transport,
  port: Int,
  opts: List(options.TcpOption),
) -> Result(ListenSocket, SocketReason) {
  case transport {
    Tcp -> tcp.listen(port, opts)
    Ssl -> ssl.listen(port, opts)
  }
}

pub fn accept(
  transport: Transport,
  socket: ListenSocket,
) -> Result(Socket, SocketReason) {
  case transport {
    Tcp -> tcp.accept(socket)
    Ssl -> ssl.accept(socket)
  }
}

pub fn handshake(transport: Transport, socket: Socket) -> Result(Socket, Nil) {
  case transport {
    Tcp -> tcp.handshake(socket)
    Ssl -> ssl.handshake(socket)
  }
}

pub fn receive_timeout(
  transport: Transport,
  socket: Socket,
  amount: Int,
  timeout: Int,
) -> Result(BitArray, SocketReason) {
  case transport {
    Tcp -> tcp.receive_timeout(socket, amount, timeout)
    Ssl -> ssl.receive_timeout(socket, amount, timeout)
  }
}

pub fn send(
  transport: Transport,
  socket: Socket,
  data: BytesTree,
) -> Result(Nil, SocketReason) {
  case transport {
    Tcp -> tcp.send(socket, data)
    Ssl -> ssl.send(socket, data)
  }
}

pub fn close(
  transport: Transport,
  socket: Socket,
) -> Result(Nil, SocketReason) {
  case transport {
    Tcp -> tcp.close(socket)
    Ssl -> ssl.close(socket)
  }
}

pub fn set_opts(
  transport: Transport,
  socket: Socket,
  opts: List(options.TcpOption),
) -> Result(Nil, SocketReason) {
  case transport {
    Tcp -> tcp.set_opts(socket, opts)
    Ssl -> ssl.set_opts(socket, opts)
  }
}

pub fn peername(
  transport: Transport,
  socket: Socket,
) -> Result(socket.SockName, Nil) {
  case transport {
    Tcp -> tcp.peername(socket)
    Ssl -> ssl.peername(socket)
  }
  |> result.replace_error(Nil)
}

fn get_socket_opts(
  transport: Transport,
  socket: Socket,
  opts: List(Atom),
) -> Result(List(#(Atom, Dynamic)), Nil) {
  case transport {
    Tcp -> tcp.get_socket_opts(socket, opts)
    Ssl -> ssl.get_socket_opts(socket, opts)
  }
  |> result.replace_error(Nil)
}

pub fn set_buffer_size(
  transport: Transport,
  socket: Socket,
) -> Result(Nil, Nil) {
  use read <- result.try(
    get_socket_opts(transport, socket, [
      atom.create("recbuf"),
    ]),
  )
  use size <- result.try(case read {
    [#(_recbuf, size)] ->
      decode.run(size, decode.int) |> result.replace_error(Nil)
    _read -> Error(Nil)
  })

  set_opts(transport, socket, [options.Buffer(size)])
  |> result.replace_error(Nil)
}

pub fn sockname(
  transport: Transport,
  socket: ListenSocket,
) -> Result(socket.SockName, SocketReason) {
  case transport {
    Tcp -> tcp.sockname(socket)
    Ssl -> ssl.sockname(socket)
  }
}
