import ewe/glisten/internal/acceptor.{Pool}
import ewe/glisten/internal/handler
import ewe/glisten/internal/listener
import ewe/glisten/socket.{
  type Socket as InternalSocket, type SocketReason as InternalSocketReason,
}
import ewe/glisten/socket/options
import ewe/glisten/transport.{type Transport}
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process.{type Selector, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import logging

/// Your provided loop function will receive these message types as the
/// second argument.
pub type Message(user_message) {
  /// These are messages received from the socket
  Packet(BitArray)
  /// These are any messages received from the selector returned from `on_init`
  User(user_message)
}

/// This is used to describe the connecting client's IP address.
pub type IpAddress {
  IpV4(Int, Int, Int, Int)
  IpV6(Int, Int, Int, Int, Int, Int, Int, Int)
}

pub type Socket =
  InternalSocket

pub type SocketReason =
  InternalSocketReason

/// The address a socket is bound to, or the address of a connected peer.
/// Unix sockets have no port/IP, only the bound path.
pub type SocketAddress {
  TcpSocketAddress(port: Int, ip_address: IpAddress)
  UnixSocketAddress(path: String)
}

@internal
pub fn convert_sock_name(sock_name: socket.SockName) -> SocketAddress {
  case sock_name {
    socket.TcpSockName(ip, port) ->
      TcpSocketAddress(port, convert_ip_address(ip))
    socket.UnixSockName(path) -> UnixSocketAddress(path)
  }
}

/// Returns the user-provided port or the OS-assigned value if 0 was provided.
///
/// Pass the subject for the `listener_name` given to `new`.
pub fn get_server_info(
  listener: Subject(listener.Message),
  timeout: Int,
) -> SocketAddress {
  let state = process.call(listener, timeout, listener.Info)
  convert_sock_name(state.sock_name)
}

/// This type holds useful bits of data for the active connection.
pub type Connection(user_message) {
  Connection(
    socket: Socket,
    /// This provides a uniform interface for both TCP and TLS methods.
    transport: Transport,
    subject: Subject(handler.Message(user_message)),
  )
}

@internal
pub fn convert_ip_address(ip: options.IpAddress) -> IpAddress {
  case ip {
    options.IpV4(a, b, c, d) -> IpV4(a, b, c, d)
    options.IpV6(a, b, c, d, e, f, g, h) -> IpV6(a, b, c, d, e, f, g, h)
  }
}

/// Convenience function for convert an `IpAddress` type into a string. It will
/// convert IPv6 addresses to the canonical short-hand (ie. loopback is ::1).
pub fn ip_address_to_string(address: IpAddress) -> String {
  case address {
    IpV4(a, b, c, d) ->
      [a, b, c, d]
      |> list.map(int.to_string)
      |> string.join(".")
    IpV6(a, b, c, d, e, f, g, h) -> {
      let fields = [a, b, c, d, e, f, g, h]
      case ipv6_zeros(fields, 0, 0, 0, 0) {
        Error(_) -> join_ipv6_fields(fields)
        Ok(#(start, end)) ->
          join_ipv6_fields(list.take(fields, start))
          <> "::"
          <> join_ipv6_fields(list.drop(fields, end))
      }
      |> string.lowercase
    }
  }
}

fn join_ipv6_fields(fields: List(Int)) -> String {
  list.map(fields, int.to_base16) |> string.join(":")
}

/// Finds the longest sequence of consecutive all-zero fields in an IPv6.
/// If the address contains multiple runs of all-zero fields of the same size,
/// it is the leftmost that is compressed.
///
/// This returns the start & end indices of the compressed zeros.
fn ipv6_zeros(
  fields: List(Int),
  pos: Int,
  len: Int,
  max_start: Int,
  max_len: Int,
) -> Result(#(Int, Int), Nil) {
  case fields {
    [] if max_len > 1 -> Ok(#(max_start, max_start + max_len))
    [] -> Error(Nil)
    [x, ..xs] if x == 0 -> {
      let len = len + 1
      case len > max_len {
        // Biggest sequence yet
        True -> ipv6_zeros(xs, pos + 1, len, pos + 1 - len, len)
        // Continue to grow current sequence
        False -> ipv6_zeros(xs, pos + 1, len, max_start, max_len)
      }
    }
    // Continue to search for zeros
    [_, ..xs] -> ipv6_zeros(xs, pos + 1, 0, max_start, max_len)
  }
}

/// Tries to read the address of a connected client. For TCP/TLS connections
/// this is the IPv4 or IPv6 address and port, attempting to return the most
/// relevant one for the client. For unix socket connections this is the
/// bound path, since unix sockets have no per-client address.
pub fn get_connection_info(
  conn: Connection(user_message),
) -> Result(SocketAddress, Nil) {
  transport.peername(conn.transport, conn.socket)
  |> result.map(convert_sock_name)
}

/// Sends a BytesTree message over the socket using the active transport
pub fn send(
  conn: Connection(user_message),
  msg: BytesTree,
) -> Result(Nil, SocketReason) {
  transport.send(conn.transport, conn.socket, msg)
}

pub opaque type Next(user_state, user_message) {
  Continue(
    state: user_state,
    selector: Option(Selector(user_message)),
    active_state: Option(options.ActiveState),
  )
  NormalStop
  AbnormalStop(String)
}

pub fn continue(state: user_state) -> Next(user_state, user_message) {
  Continue(state, None, None)
}

pub fn with_selector(
  next: Next(user_state, user_message),
  selector: Selector(user_message),
) -> Next(user_state, user_message) {
  case next {
    Continue(state, _, active_state) ->
      Continue(state, Some(selector), active_state)
    stop -> stop
  }
}

/// Overrides the socket's `ActiveState` starting with this message. Applied
/// immediately when this `Next` is processed and persists as the new default 
/// for future commands until changed again. Allowed are `Once`, `Active` and 
/// `Count(n)` where n > 1. An invalid value is ignored.
pub fn set_active_state(
  next: Next(user_state, user_message),
  active_state: options.ActiveState,
) -> Next(user_state, user_message) {
  case active_state {
    options.Passive -> {
      logging.log(
        logging.Warning,
        "Ignoring set_active_state: cannot set the connection's `ActiveState` to `Passive`",
      )
      next
    }
    options.Count(n) if n <= 1 -> {
      logging.log(
        logging.Warning,
        "Ignoring set_active_state: Count shall be greater than 1",
      )
      next
    }
    options.Once | options.Active | options.Count(_) ->
      case next {
        Continue(state, selector, _) ->
          Continue(state, selector, Some(active_state))
        stop -> stop
      }
  }
}

pub fn stop() -> Next(user_state, user_message) {
  NormalStop
}

pub fn stop_abnormal(reason: String) -> Next(user_state, user_message) {
  AbnormalStop(reason)
}

@internal
pub fn convert_next(
  next: Next(state, user_message),
) -> handler.Next(state, user_message) {
  case next {
    Continue(state, selector, active_state) ->
      handler.Continue(state, selector, active_state)
    NormalStop -> handler.NormalStop
    AbnormalStop(reason) -> handler.AbnormalStop(reason)
  }
}

@internal
pub fn map_selector(
  next: Next(state, user_message),
  mapper: fn(user_message) -> other_message,
) -> Next(state, other_message) {
  case next {
    Continue(state, Some(selector), active_state) ->
      Continue(
        state,
        Some(process.map_selector(selector, mapper)),
        active_state,
      )
    Continue(state, None, active_state) -> Continue(state, None, active_state)
    AbnormalStop(reason) -> AbnormalStop(reason)
    NormalStop -> NormalStop
  }
}

/// This is the shape of the function you need to provide for the `handler`
/// argument to `start`.
pub type Loop(state, user_message) =
  fn(state, Message(user_message), Connection(user_message)) ->
    Next(state, Message(user_message))

pub opaque type Builder(state, user_message) {
  Builder(
    interface: options.Interface,
    on_init: fn(Connection(user_message)) ->
      #(state, Option(Selector(user_message))),
    loop: Loop(state, user_message),
    on_close: Option(fn(state) -> Nil),
    pool_size: Int,
    http2_support: Bool,
    ipv6_support: Bool,
    tls_options: Option(options.TlsCerts),
    client_verification: Option(CaCert),
    listener_name: process.Name(listener.Message),
    connection_factory_name: process.Name(
      factory.Message(Socket, Subject(handler.Message(user_message))),
    ),
    connection_shutdown_timeout_ms: Int,
    active_state: options.ActiveState,
  )
}

fn map_user_selector(
  selector: Selector(Message(user_message)),
) -> Selector(handler.LoopMessage(user_message)) {
  process.map_selector(selector, fn(value) {
    case value {
      Packet(msg) -> handler.Packet(msg)
      User(msg) -> handler.Custom(msg)
    }
  })
}

fn convert_loop(
  loop: Loop(state, user_message),
) -> handler.Loop(state, user_message) {
  fn(data, msg, conn: handler.Connection(user_message)) {
    let conn = Connection(conn.socket, conn.transport, conn.sender)
    let message = case msg {
      handler.Packet(msg) -> Packet(msg)
      handler.Custom(msg) -> User(msg)
    }
    case loop(data, message, conn) {
      Continue(data, selector, active_state) -> {
        let next = case selector {
          Some(selector) ->
            handler.continue(data)
            |> handler.with_selector(map_user_selector(selector))
          _ -> handler.continue(data)
        }
        case active_state {
          Some(active_state) -> handler.with_active_state(next, active_state)
          None -> next
        }
      }

      NormalStop -> handler.stop()
      AbnormalStop(reason) -> handler.stop_abnormal(reason)
    }
  }
}

fn convert_on_init(
  on_init: fn(Connection(user_message)) ->
    #(state, Option(Selector(user_message))),
) -> fn(handler.Connection(user_message)) ->
  #(state, Option(Selector(user_message))) {
  fn(conn: handler.Connection(user_message)) {
    let connection =
      Connection(
        subject: conn.sender,
        socket: conn.socket,
        transport: conn.transport,
      )
    on_init(connection)
  }
}

/// Create a new handler for each connection.  The `on_init` and `loop`
/// arguments mirror the `actor.start` API from `gleam_otp`. The default pool
/// is 10 acceptor processes.
///
/// `listener_name` and `connection_factory_name` are process names `glisten`
/// uses internally to wire the listener and connection factory together.
/// Create each once, at the point your program starts, and pass them in here.
/// 
/// `listener_name` is also what you use for `get_server_info` if you need to
/// read back the bound port or path.
pub fn new(
  listener_name listener_name: process.Name(listener.Message),
  connection_factory_name connection_factory_name: process.Name(
    factory.Message(Socket, Subject(handler.Message(user_message))),
  ),
  on_init on_init: fn(Connection(user_message)) ->
    #(state, Option(Selector(user_message))),
  loop loop: Loop(state, user_message),
) -> Builder(state, user_message) {
  Builder(
    interface: options.Loopback,
    on_init: on_init,
    loop: loop,
    on_close: None,
    pool_size: 10,
    http2_support: False,
    ipv6_support: False,
    tls_options: None,
    client_verification: None,
    listener_name:,
    connection_factory_name:,
    connection_shutdown_timeout_ms: 5000,
    active_state: options.Once,
  )
}

/// Adds a function to the handler to be called when the connection is closed.
pub fn with_close(
  builder: Builder(state, user_message),
  on_close: fn(state) -> Nil,
) -> Builder(state, user_message) {
  Builder(..builder, on_close: Some(on_close))
}

/// Modify the size of the acceptor pool
pub fn with_pool_size(
  builder: Builder(state, user_message),
  size: Int,
) -> Builder(state, user_message) {
  Builder(..builder, pool_size: size)
}

/// Sets the ALPN supported protocols to include HTTP/2.  It's currently being
/// exposed only for `mist` to provide this support.  For a TCP library, you
/// definitely do not need it.
@internal
pub fn with_http2(
  builder: Builder(state, user_message),
) -> Builder(state, user_message) {
  Builder(..builder, http2_support: True)
}

/// This sets the interface for `glisten` to listen on. It accepts the following
/// strings:  "localhost", valid IPv4 addresses (i.e. "127.0.0.1"), and valid
/// IPv6 addresses (i.e. "::1"). If an invalid value is provided, this will
/// panic.
pub fn bind(
  builder: Builder(state, user_message),
  interface: String,
) -> Builder(state, user_message) {
  let address = case interface, parse_address(charlist.from_string(interface)) {
    "0.0.0.0", _ -> options.Any
    "localhost", _ | "127.0.0.1", _ -> options.Loopback
    _, Ok(address) -> options.Address(address)
    _, Error(_nil) ->
      panic as "Invalid interface provided:  must be a valid IPv4/IPv6 address, or \"localhost\""
  }
  Builder(..builder, interface: address)
}

/// By default, `glisten` listens on `localhost` only over IPv4.  With an IPv4
/// address, you can call this builder method to also serve over IPv6 on that
/// interface.  If it is not supported, your application will crash.  If you
/// call this with an IPv6 interface specified, it will have no effect.
pub fn with_ipv6(
  builder: Builder(state, user_message),
) -> Builder(state, user_message) {
  Builder(..builder, ipv6_support: True)
}

/// To use TLS, provide a path to a certficate and key file.
pub fn with_tls(
  builder: Builder(state, user_message),
  certfile cert: String,
  keyfile key: String,
) -> Builder(state, user_message) {
  Builder(..builder, tls_options: Some(options.CertKeyFiles(cert, key)))
}

/// To use TLS, provide in-memory PEM-encoded certificate and key data.
pub fn with_tls_pem(
  builder: Builder(state, user_message),
  cert cert: BitArray,
  key key: BitArray,
) -> Builder(state, user_message) {
  Builder(..builder, tls_options: Some(options.CertKeyPem(cert, key)))
}

/// To use TLS, provide in-memory DER-encoded certificate and key data. The key 
/// type must match the encoding of the provided key binary.
pub fn with_tls_der(
  builder: Builder(state, user_message),
  cert cert: BitArray,
  key_type key_type: options.TlsKeyType,
  key key: BitArray,
) -> Builder(state, user_message) {
  Builder(..builder, tls_options: Some(options.CertKeyDer(cert, key_type, key)))
}

/// Specifies the CA certificate source for verifying client certificates.
pub type CaCert {
  /// Path to a PEM file containing the CA certificate.
  CaCertFile(path: String)
  /// In-memory DER-encoded CA certificate.
  CaCertData(certs: List(BitArray))
}

/// Enables mTLS by requiring clients to present a certificate signed by the 
/// provided CA. Connections without a valid certificate are rejected.
pub fn with_client_verification(
  builder: Builder(state, user_message),
  ca_cert: CaCert,
) -> Builder(state, user_message) {
  Builder(..builder, client_verification: Some(ca_cert))
}

/// Set the server's `ActiveState` for flow control of received packets.
/// Default is `Once`. Allowed are `Once`, `Active` and `Count(n)` where n > 1.
pub fn with_active_state(
  builder: Builder(state, user_message),
  active_state: options.ActiveState,
) -> Builder(state, user_message) {
  case active_state {
    options.Once | options.Active ->
      Builder(..builder, active_state: active_state)
    options.Count(n) if n > 1 -> Builder(..builder, active_state: active_state)
    options.Count(_) -> panic as "Count shall be greater than 1"
    options.Passive ->
      panic as "You cannot set the server's `ActiveState` to `Passive`"
  }
}

/// Sets how long, in milliseconds, a connection handler is given to shut down
/// once the supervisor asks it to before being forcefully killed. Default is 
/// 5000.
pub fn with_connection_shutdown_timeout_ms(
  builder: Builder(state, user_message),
  timeout_ms: Int,
) -> Builder(state, user_message) {
  Builder(..builder, connection_shutdown_timeout_ms: timeout_ms)
}

@internal
pub fn with_listener_name(
  builder: Builder(state, user_message),
  listener_name: process.Name(listener.Message),
) -> Builder(state, user_message) {
  Builder(..builder, listener_name:)
}

@internal
pub fn with_connection_factory_name(
  builder: Builder(state, user_message),
  connection_factory_name: process.Name(
    factory.Message(socket.Socket, Subject(handler.Message(user_message))),
  ),
) -> Builder(state, user_message) {
  Builder(..builder, connection_factory_name:)
}

/// Start the TCP server with the given handler on the provided port
pub fn start(
  builder: Builder(state, user_message),
  port: Int,
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  let listener_name = builder.listener_name
  let connection_supervisor = builder.connection_factory_name
  let options =
    [options.Ip(builder.interface)]
    |> list.append(case builder.ipv6_support {
      True -> [options.Ipv6]
      False -> []
    })
    |> list.append(case builder.tls_options {
      Some(opts) -> [options.CertKeyConfig(opts)]
      _ -> []
    })
    |> list.append(case builder.tls_options, builder.http2_support {
      Some(_), True -> [options.AlpnPreferredProtocols(["h2", "http/1.1"])]
      Some(_), False -> [options.AlpnPreferredProtocols(["http/1.1"])]
      None, _ -> []
    })
    |> list.append(case builder.client_verification {
      Some(CaCertFile(path)) -> [
        options.Verify(options.VerifyPeer),
        options.CaCertFile(path),
        options.FailIfNoPeerCert(True),
      ]
      Some(CaCertData(certs)) -> [
        options.Verify(options.VerifyPeer),
        options.CaCerts(certs),
        options.FailIfNoPeerCert(True),
      ]
      None -> []
    })

  let transport = case builder.tls_options {
    Some(_) -> transport.Ssl
    _ -> transport.Tcp
  }

  Pool(
    handler: convert_loop(builder.loop),
    name: connection_supervisor,
    pool_count: builder.pool_size,
    on_init: convert_on_init(builder.on_init),
    on_close: builder.on_close,
    transport:,
    active_state: builder.active_state,
    connection_shutdown_timeout_ms: builder.connection_shutdown_timeout_ms,
  )
  |> acceptor.start_pool(transport, port, options, listener_name)
}

@external(erlang, "ewe_glisten_ffi", "delete_file")
fn delete_socket_file(path: String) -> Result(Nil, dynamic.Dynamic)

pub fn start_unix(
  builder: Builder(state, user_message),
  path: String,
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  case path {
    "@" <> _ -> Nil
    _ -> {
      let _ = delete_socket_file(path)
      Nil
    }
  }

  let listener_name = builder.listener_name
  let connection_supervisor = builder.connection_factory_name

  let options =
    [options.Ip(options.UnixPath(path))]
    |> list.append(case builder.tls_options {
      Some(opts) -> [options.CertKeyConfig(opts)]
      _ -> []
    })
    |> list.append(case builder.tls_options, builder.http2_support {
      Some(_), True -> [options.AlpnPreferredProtocols(["h2", "http/1.1"])]
      Some(_), False -> [options.AlpnPreferredProtocols(["http/1.1"])]
      None, _ -> []
    })

  let transport = case builder.tls_options {
    Some(_) -> transport.Ssl
    _ -> transport.Tcp
  }

  Pool(
    handler: convert_loop(builder.loop),
    name: connection_supervisor,
    pool_count: builder.pool_size,
    on_init: convert_on_init(builder.on_init),
    on_close: builder.on_close,
    transport:,
    active_state: builder.active_state,
    connection_shutdown_timeout_ms: builder.connection_shutdown_timeout_ms,
  )
  |> acceptor.start_pool(transport, 0, options, listener_name)
}

@external(erlang, "ewe_glisten_ffi", "parse_address")
fn parse_address(value: Charlist) -> Result(ip_address, Nil)

/// Helper method for building a child specification for use in a supervision
/// tree.
pub fn supervised(
  handler: Builder(state, user_message),
  port: Int,
) -> ChildSpecification(supervisor.Supervisor) {
  supervision.supervisor(fn() { start(handler, port) })
}

pub fn supervised_unix(
  handler: Builder(state, user_message),
  path: String,
) -> ChildSpecification(supervisor.Supervisor) {
  supervision.supervisor(fn() { start_unix(handler, path) })
}
