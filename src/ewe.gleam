import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import glisten
import glisten/internal/handler
import glisten/internal/listener
import glisten/socket
import glisten/socket/options
import glisten/transport

pub opaque type Connection {
  Connection(transport: transport.Transport, socket: socket.Socket)
}

pub type Body

pub type IpAddress {
  IpV4(Int, Int, Int, Int)
  IpV6(Int, Int, Int, Int, Int, Int, Int, Int)
}

pub fn ip_address_to_string(address: IpAddress) -> String {
  unsafe_to_internal_ip_address(address)
  |> glisten.ip_address_to_string
}

// IpAddress and glisten.IpAddress are structurally identical.
@external(erlang, "gleam_stdlib", "identity")
fn unsafe_to_internal_ip_address(address: IpAddress) -> glisten.IpAddress

// IpAddress and options.IpAddress are structurally identical.
@external(erlang, "gleam_stdlib", "identity")
fn unsafe_from_internal_options_ip_address(
  address: options.IpAddress,
) -> IpAddress

/// The address a socket is bound to, or the address of a connected peer.
pub type SocketAddress {
  TcpSocketAddress(ip_address: IpAddress, port: Int)
  UnixSocketAddress(path: String)
}

// SocketAddress and glisten.SocketAddress are structurally identical.
@external(erlang, "gleam_stdlib", "identity")
fn unsafe_from_internal_socket_address(
  address: glisten.SocketAddress,
) -> SocketAddress

/// Retrieves the client's socket address from the connection. Returns error if
/// the socket information is unavailable.
pub fn get_client_info(connection: Connection) -> Result(SocketAddress, Nil) {
  let peername = transport.peername(connection.transport, connection.socket)
  use info <- result.map(over: peername)

  case info {
    socket.TcpSockName(ip_address:, port:) ->
      unsafe_from_internal_options_ip_address(ip_address)
      |> TcpSocketAddress(port:)
    socket.UnixSockName(path:) -> UnixSocketAddress(path:)
  }
}

/// Gets the server's bound address and port. Requires the server to be running.
/// Pass the subject named with `listener_name` given to `new`.
pub fn get_server_info(
  listener: process.Subject(listener.Message),
) -> SocketAddress {
  glisten.get_server_info(listener, 1000)
  |> unsafe_from_internal_socket_address
}

type BindTarget {
  TcpBind(interface: String, port: Int, ipv6: Bool)
  UnixBind(path: String)
}

/// Contains all server configurations, can be adjusted by different builder
/// functions.
pub opaque type Builder {
  Builder(
    handler: fn(request.Request(Connection)) -> response.Response(Body),
    bind_target: BindTarget,
    listener_name: process.Name(listener.Message),
    connection_factory_name: process.Name(
      factory.Message(socket.Socket, process.Subject(handler.Message(Nil))),
    ),
    on_start: fn(http.Scheme, SocketAddress) -> Nil,
  )
}

/// Creates a new server configuration with handler and names provided. 
/// `listener_name` and `connection_factory_name` are process names used for the
/// acceptor pool to wire together listener and connection factory. Create them 
/// once, at the point your program starts, and pass them in here.  
pub fn new(
  listener_name listener_name: process.Name(listener.Message),
  connection_factory_name connection_factory_name: process.Name(
    factory.Message(socket.Socket, process.Subject(handler.Message(Nil))),
  ),
  handler handler: fn(request.Request(Connection)) -> response.Response(Body),
) {
  Builder(
    handler:,
    bind_target: TcpBind(interface: "127.0.0.1", port: 3000, ipv6: False),
    listener_name:,
    connection_factory_name:,
    on_start: fn(scheme, address) {
      case address {
        TcpSocketAddress(ip_address:, port:) -> {
          let host = case ip_address {
            IpV6(..) -> "[" <> ip_address_to_string(ip_address) <> "]"
            IpV4(..) -> ip_address_to_string(ip_address)
          }

          let url =
            http.scheme_to_string(scheme)
            <> "://"
            <> host
            <> ":"
            <> int.to_string(port)

          io.println("Listening on " <> url)
        }
        UnixSocketAddress(path:) -> io.println("Listening on unix:" <> path)
      }
    },
  )
}

/// Binds server to a specific network interface; e.g., "0.0.0.0" for all IPv4
/// interfaces, "127.0.0.1" for localhost, "::" for all IPv6 interfaces, or
/// "::1" for IPv6 loopback. Crashes the program if the interface is invalid.
pub fn bind(builder: Builder, to interface: String) -> Builder {
  let bind_target = case builder.bind_target {
    TcpBind(port:, ipv6:, ..) -> TcpBind(interface:, port:, ipv6:)
    UnixBind(..) -> TcpBind(interface:, port: 3000, ipv6: False)
  }

  Builder(..builder, bind_target:)
}

/// Sets the listening port for server.
pub fn listening(builder: Builder, on port: Int) -> Builder {
  let bind_target = case builder.bind_target {
    TcpBind(interface:, ipv6:, ..) -> TcpBind(interface:, port:, ipv6:)
    UnixBind(..) -> TcpBind(interface: "127.0.0.1", port:, ipv6: False)
  }
  Builder(..builder, bind_target:)
}

/// Sets the listening port to 0, which causes the OS to assign a random
/// available port.
pub fn listening_random(builder: Builder) -> Builder {
  listening(builder, on: 0)
}

/// Forces the underlying socket to use IPv6. On IPv4 provided in `ewe.bind` or
/// if the system does not support IPv6, the server crashes. The exceptions are
/// `localhost`, `127.0.0.1` or `0.0.0.0`, they are automatically bound to work
/// with either address family.
pub fn force_ipv6(builder: Builder) -> Builder {
  let bind_target = case builder.bind_target {
    TcpBind(interface:, port:, ..) -> TcpBind(interface:, port:, ipv6: True)
    UnixBind(..) -> TcpBind(interface: "127.0.0.1", port: 3000, ipv6: True)
  }

  Builder(..builder, bind_target:)
}

/// Binds server to a unix domain socket at `path` instead of TCP. Overrides
/// any interface, port and ipv6 settings previously configured.
pub fn unix(builder: Builder, path: String) -> Builder {
  Builder(..builder, bind_target: UnixBind(path))
}

/// Sets a callback function called after the server starts. Receives the scheme
/// and server's socket address.
pub fn on_start(
  builder: Builder,
  on_start: fn(http.Scheme, SocketAddress) -> Nil,
) -> Builder {
  Builder(..builder, on_start:)
}

/// Sets an empty `on_start` function.
pub fn quiet(builder: Builder) -> Builder {
  Builder(..builder, on_start: fn(_scheme, _address) { Nil })
}

/// Starts the server with the provided configuration.
pub fn start(
  builder: Builder,
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  todo
}

/// Returns a child specification for use in a supervision tree.
pub fn supervised(
  builder: Builder,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  todo
}
