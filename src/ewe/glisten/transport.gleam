import ewe/glisten/socket.{type ListenSocket, type Socket, type SocketReason}
import ewe/glisten/socket/options
import ewe/glisten/ssl
import ewe/glisten/tcp
import gleam/bytes_tree.{type BytesTree}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
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

pub fn accept_timeout(
  transport: Transport,
  socket: ListenSocket,
  timeout: Int,
) -> Result(Socket, SocketReason) {
  case transport {
    Tcp -> tcp.accept_timeout(socket, timeout)
    Ssl -> ssl.accept_timeout(socket, timeout)
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

pub fn receive(
  transport: Transport,
  socket: Socket,
  amount: Int,
) -> Result(BitArray, SocketReason) {
  case transport {
    Tcp -> tcp.receive(socket, amount)
    Ssl -> ssl.receive(socket, amount)
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

pub fn shutdown(
  transport: Transport,
  socket: Socket,
) -> Result(Nil, SocketReason) {
  case transport {
    Tcp -> tcp.shutdown(socket)
    Ssl -> ssl.shutdown(socket)
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

pub fn negotiated_protocol(
  transport: Transport,
  socket: Socket,
) -> Result(String, String) {
  case transport {
    Tcp -> Error("Can't negotiate protocol on tcp")
    Ssl -> ssl.negotiated_protocol(socket)
  }
}

fn decode_ipv4() -> Decoder(options.IpAddress) {
  use a <- decode.field(0, decode.int)
  use b <- decode.field(1, decode.int)
  use c <- decode.field(2, decode.int)
  use d <- decode.field(3, decode.int)
  decode.success(options.IpV4(a, b, c, d))
}

fn decode_ipv6() -> Decoder(options.IpAddress) {
  use a <- decode.field(0, decode.int)
  use b <- decode.field(1, decode.int)
  use c <- decode.field(2, decode.int)
  use d <- decode.field(3, decode.int)
  use e <- decode.field(4, decode.int)
  use f <- decode.field(5, decode.int)
  use g <- decode.field(6, decode.int)
  use h <- decode.field(7, decode.int)
  case a, b, c, d, e, f, g, h {
    0, 0, 0, 0, 0, 65_535, a, b -> {
      let #(a, b, c, d) = convert_address(#(a, b, c, d, e, f, g, h))
      decode.success(options.IpV4(a, b, c, d))
    }
    _, _, _, _, _, _, _, _ -> {
      decode.success(options.IpV6(a, b, c, d, e, f, g, h))
    }
  }
}

pub fn decode_ip() -> Decoder(options.IpAddress) {
  decode.one_of(decode_ipv6(), or: [decode_ipv4()])
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

@external(erlang, "inet", "ipv4_mapped_ipv6_address")
fn convert_address(address: address) -> #(Int, Int, Int, Int)

@external(erlang, "socket", "info")
pub fn socket_info(socket: Socket) -> Dict(Atom, Dynamic)

pub fn get_socket_opts(
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
  get_socket_opts(transport, socket, [atom.create("recbuf")])
  |> result.try(fn(p) {
    case p {
      [#(_buffer, value)] ->
        value
        |> decode.run(decode.int)
        |> result.replace_error(Nil)
      _ -> Error(Nil)
    }
  })
  |> result.try(fn(value) {
    set_opts(transport, socket, [options.Buffer(value)])
    |> result.map_error(fn(_) { Nil })
  })
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
