import ewe/internal/connection
import ewe/internal/file
import ewe/internal/handler as handler_
import ewe/internal/http1/body as http1_body
import ewe/internal/http1/encoder
import ewe/internal/http1/sse as http1_sse
import ewe/internal/sse
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
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

pub type Connection =
  connection.Connection

pub type Body {
  Bytes(bytes_tree.BytesTree)
  Text(String)
  Empty
  File(connection.File)
  Streaming(connection.Streaming)
  Sse(connection.Sse)
}

pub type IpAddress {
  IpV4(Int, Int, Int, Int)
  IpV6(Int, Int, Int, Int, Int, Int, Int, Int)
}

pub fn ip_address_to_string(address: IpAddress) -> String {
  to_internal_ip_address(address)
  |> glisten.ip_address_to_string
}

fn to_internal_ip_address(address: IpAddress) -> glisten.IpAddress {
  case address {
    IpV4(a, b, c, d) -> glisten.IpV4(a, b, c, d)
    IpV6(a, b, c, d, e, f, g, h) -> glisten.IpV6(a, b, c, d, e, f, g, h)
  }
}

fn from_internal_options_ip_address(address: options.IpAddress) -> IpAddress {
  case address {
    options.IpV4(a, b, c, d) -> IpV4(a, b, c, d)
    options.IpV6(a, b, c, d, e, f, g, h) -> IpV6(a, b, c, d, e, f, g, h)
  }
}

fn from_internal_ip_address(address: glisten.IpAddress) -> IpAddress {
  case address {
    glisten.IpV4(a, b, c, d) -> IpV4(a, b, c, d)
    glisten.IpV6(a, b, c, d, e, f, g, h) -> IpV6(a, b, c, d, e, f, g, h)
  }
}

/// The address a socket is bound to, or the address of a connected peer.
pub type SocketAddress {
  TcpSocketAddress(ip_address: IpAddress, port: Int)
  UnixSocketAddress(path: String)
}

// Field order differs between `SocketAddress` and `glisten.SocketAddress`.
fn convert_socket_address(address: glisten.SocketAddress) -> SocketAddress {
  case address {
    glisten.TcpSocketAddress(port:, ip_address:) ->
      TcpSocketAddress(ip_address: from_internal_ip_address(ip_address), port:)
    glisten.UnixSocketAddress(path:) -> UnixSocketAddress(path:)
  }
}

/// Retrieves the client's socket address from the connection. Returns error if
/// the socket information is unavailable.
pub fn get_client_info(connection: Connection) -> Result(SocketAddress, Nil) {
  case connection {
    connection.Http1(connection) -> {
      let peername = transport.peername(connection.transport, connection.socket)
      use info <- result.map(over: peername)

      case info {
        socket.TcpSockName(ip_address:, port:) ->
          from_internal_options_ip_address(ip_address)
          |> TcpSocketAddress(port:)
        socket.UnixSockName(path:) -> UnixSocketAddress(path:)
      }
    }
    connection.Http2 -> todo as "HTTP/2 is not implemented yet!"
  }
}

/// Gets the server's bound address and port. Requires the server to be running.
/// Pass the subject named with `listener_name` given to `new`.
pub fn get_server_info(
  listener: process.Subject(listener.Message),
) -> SocketAddress {
  glisten.get_server_info(listener, 1000)
  |> convert_socket_address
}

type BindTarget {
  TcpBind(interface: String, port: Int, ipv6: Bool)
  UnixBind(path: String)
}

type TlsConfig {
  CertKeyFiles(certfile: String, keyfile: String)
  CertKeyPem(cert: BitArray, key: BitArray)
  CertKeyDer(cert: BitArray, key_type: TlsKeyType, key: BitArray)
}

/// The private key encoding type, required when providing DER-encoded
/// certificate and key via `with_tls_der`.
pub type TlsKeyType {
  /// Traditional RSA key.
  RsaPrivateKey
  /// Elliptic curve key.
  EcPrivateKey
  /// DSA key.
  DsaPrivateKey
  /// PKCS#8 key.
  PrivateKeyInfo
}

fn to_internal_tls_key_type(key_type: TlsKeyType) -> options.TlsKeyType {
  case key_type {
    RsaPrivateKey -> options.RsaPrivateKey
    EcPrivateKey -> options.EcPrivateKey
    DsaPrivateKey -> options.DsaPrivateKey
    PrivateKeyInfo -> options.PrivateKeyInfo
  }
}

/// Contains all server configurations, can be adjusted by different builder
/// functions.
pub opaque type Builder {
  Builder(
    handler: fn(request.Request(Connection)) -> response.Response(Body),
    bind_target: BindTarget,
    tls: Option(TlsConfig),
    listener_name: process.Name(listener.Message),
    connection_factory_name: process.Name(
      factory.Message(
        socket.Socket,
        process.Subject(handler.Message(connection.Message)),
      ),
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
    factory.Message(
      socket.Socket,
      process.Subject(handler.Message(connection.Message)),
    ),
  ),
  handler handler: fn(request.Request(Connection)) -> response.Response(Body),
) {
  Builder(
    handler:,
    bind_target: TcpBind(interface: "127.0.0.1", port: 3000, ipv6: False),
    tls: None,
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

/// Enables TLS using a certificate and key file on disk.
pub fn with_tls(
  builder: Builder,
  certfile cert: String,
  keyfile key: String,
) -> Builder {
  Builder(..builder, tls: Some(CertKeyFiles(cert, key)))
}

/// Enables TLS using in-memory PEM-encoded certificate and key data.
pub fn with_tls_pem(
  builder: Builder,
  cert cert: BitArray,
  key key: BitArray,
) -> Builder {
  Builder(..builder, tls: Some(CertKeyPem(cert, key)))
}

/// Enables TLS using in-memory DER-encoded certificate and key data. The key
/// type must match the encoding of the provided key binary.
pub fn with_tls_der(
  builder: Builder,
  cert cert: BitArray,
  key_type key_type: TlsKeyType,
  key key: BitArray,
) -> Builder {
  Builder(..builder, tls: Some(CertKeyDer(cert, key_type, key)))
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

fn to_internal_body(body: Body) -> connection.Body {
  case body {
    Bytes(tree) -> connection.Bytes(tree)
    Text(text) -> connection.Text(text)
    Empty -> connection.Empty
    File(file) -> connection.File(file)
    Streaming(streaming) -> connection.Streaming(streaming)
    Sse(sse) -> connection.Sse(sse)
  }
}

/// Starts the server with the provided configuration.
pub fn start(
  builder: Builder,
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  let handler = fn(request) {
    let response = builder.handler(request)
    response.set_body(response, to_internal_body(response.body))
  }

  let pool =
    glisten.new(
      listener_name: builder.listener_name,
      connection_factory_name: builder.connection_factory_name,
      on_init: handler_.on_init(handler),
      loop: handler_.loop,
    )

  let pool = case builder.tls {
    Some(CertKeyFiles(certfile:, keyfile:)) ->
      glisten.with_tls(pool, certfile:, keyfile:)
    Some(CertKeyPem(cert:, key:)) -> glisten.with_tls_pem(pool, cert:, key:)
    Some(CertKeyDer(cert:, key_type:, key:)) ->
      glisten.with_tls_der(
        pool,
        cert:,
        key_type: to_internal_tls_key_type(key_type),
        key:,
      )
    None -> pool
  }

  use started <- result.map(over: case builder.bind_target {
    TcpBind(interface:, port:, ipv6:) -> {
      let pool = glisten.bind(pool, interface)

      let pool = case ipv6 {
        True -> glisten.with_ipv6(pool)
        False -> pool
      }

      glisten.start(pool, port)
    }
    UnixBind(path:) -> glisten.start_unix(pool, path)
  })

  let scheme = case builder.tls {
    Some(_config) -> http.Https
    None -> http.Http
  }
  let address =
    process.named_subject(builder.listener_name)
    |> get_server_info

  builder.on_start(scheme, address)

  started
}

/// Returns a child specification for use in a supervision tree.
pub fn supervised(
  builder: Builder,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  fn() { start(builder) }
  |> supervision.supervisor
}

pub type FileError {
  NotFound
  IsDirectory
  AccessDenied
  UnknownError
  InvalidOffset
  InvalidLimit
}

fn from_internal_file_error(error: file.FileError) -> FileError {
  case error {
    file.NotFound -> NotFound
    file.IsDirectory -> IsDirectory
    file.AccessDenied -> AccessDenied
    file.UnknownError -> UnknownError
    file.InvalidOffset -> InvalidOffset
    file.InvalidLimit -> InvalidLimit
  }
}

/// Prepares a file to be streamed as a response body. `offset` and `limit` in 
/// bytes let you serve a byte range from the file. leave either as `None` to 
/// serve from the start or through the end.
pub fn file(
  path: String,
  offset offset: Option(Int),
  limit limit: Option(Int),
) -> Result(Body, FileError) {
  case file.resolve(path, offset, limit) {
    Ok(file) -> Ok(File(file))
    Error(error) -> Error(from_internal_file_error(error))
  }
}

pub type BodyError {
  /// The declared body is bigger than the `limit` passed to `read_body`.
  BodyTooLarge
  /// The body couldn't be fully read: the connection dropped, timed out, or
  /// the chunked framing was malformed.
  InvalidBody
}

fn from_internal_http1_body_error(error: http1_body.BodyError) -> BodyError {
  case error {
    http1_body.BodyTooLarge -> BodyTooLarge
    http1_body.InvalidBody -> InvalidBody
  }
}

/// Reads the entire request body into memory, up to `limit` bytes. For a 
/// chunked request, any trailer fields are appended to the returned request's 
/// `headers`.
pub fn read_body(
  req: request.Request(Connection),
  limit limit: Int,
) -> Result(request.Request(BitArray), BodyError) {
  case req.body {
    connection.Http1(connection) -> {
      use #(body, trailers) <- result.try(
        http1_body.read_body(connection, limit)
        |> result.map_error(from_internal_http1_body_error),
      )

      request.Request(..req, headers: list.append(req.headers, trailers), body:)
      |> Ok
    }
    connection.Http2 -> todo as "HTTP/2 is not implemented yet!"
  }
}

/// The result of one `read_body_chunk` call.
pub type ReadEvent {
  /// Up to `max_chunk_bytes` of body data. Feed `request` into the next call.
  Chunk(data: BitArray, request: request.Request(Connection))
  /// The body is fully consumed. Any chunked trailer fields have been appended 
  /// to the returned request's `headers`.
  Done(request: request.Request(Nil))
}

/// Pulls up to `max_chunk_bytes` of body per call instead of buffering the
/// whole body, capped overall at `limit`. Feed the request carried by `Chunk` 
/// into the next call.
pub fn read_body_chunk(
  req: request.Request(Connection),
  max_chunk_bytes max_chunk_bytes: Int,
  limit limit: Int,
) -> Result(ReadEvent, BodyError) {
  case req.body {
    connection.Http1(connection) -> {
      case http1_body.read_body_chunk(connection, max_chunk_bytes:, limit:) {
        Ok(http1_body.Chunk(data, connection)) -> {
          let body = connection.Http1(connection)
          Ok(Chunk(data, request.set_body(req, body)))
        }
        Ok(http1_body.Done(trailers)) -> {
          let headers = list.append(req.headers, trailers)
          Ok(Done(request.Request(..req, headers:, body: Nil)))
        }
        Error(error) -> Error(from_internal_http1_body_error(error))
      }
    }
    connection.Http2 -> todo as "HTTP/2 is not implemented yet!"
  }
}

/// A handle for writing a streamed response's body, obtained from
/// `stream_response`.
pub type ResponseWriter =
  connection.ResponseWriter

/// Starts a streamed response. `handler` must end by calling `finish_chunk` or
/// `finish_response` on it, since that's what closes the stream.
pub fn stream_response(
  response: response.Response(a),
  handler: fn(ResponseWriter) -> Nil,
) -> response.Response(Body) {
  response.set_body(response, Streaming(connection.StreamingMetadata(handler)))
}

/// Sends one response body chunk, threading the writer through so it can be
/// piped. For the last chunk use `finish_chunk` instead, it closes the
/// stream in the same round trip.
pub fn send_chunk(writer: ResponseWriter, chunk: BitArray) -> ResponseWriter {
  case writer {
    connection.Http1Writer(writer) ->
      connection.Http1Writer(encoder.send_chunk(writer, chunk))
    connection.Http2Writer -> todo as "HTTP/2 is not implemented yet!"
  }
}

/// Sends `chunk` as the final response body chunk and closes the stream.
pub fn finish_chunk(writer: ResponseWriter, chunk: BitArray) -> Nil {
  case writer {
    connection.Http1Writer(writer) -> encoder.finish_chunk(writer, chunk)
    connection.Http2Writer -> todo as "HTTP/2 is not implemented yet!"
  }
}

/// Closes the stream with no further data. Use `finish_chunk` instead if
/// there's one last chunk to send.
pub fn finish_response(writer: ResponseWriter) -> Nil {
  case writer {
    connection.Http1Writer(writer) -> encoder.finish_response(writer)
    connection.Http2Writer -> todo as "HTTP/2 is not implemented yet!"
  }
}

/// A handle for writing to an open Server-Sent Events stream.
pub type SseConnection =
  connection.SseConnection

/// Server-Sent Events message. Build it with `event` or `comment`, then set 
/// the remaining fields with `event_name`, `event_id` and `event_retry`.
pub type SseEvent =
  sse.Event

/// What an SSE stream does after the handler has dealt with the message. Build
/// it with `sse_continue`, `sse_stop` or `sse_stop_abnormal`.
pub opaque type SseNext(user_state) {
  SseContinue(user_state)
  SseStop
  SseStopAbnormal(reason: String)
}

/// Carries on with the stream, handling further messages with `user_state`.
pub fn sse_continue(user_state: user_state) -> SseNext(user_state) {
  SseContinue(user_state)
}

/// Ends the stream.
pub fn sse_stop() -> SseNext(user_state) {
  SseStop
}

/// Ends the stream, reporting `reason` as the cause.
pub fn sse_stop_abnormal(reason: String) -> SseNext(user_state) {
  SseStopAbnormal(reason)
}

/// Creates an event carrying `data`. Data spanning several lines is sent as
/// the repeated `data:` fields the client rejoins.
pub fn event(data: String) -> SseEvent {
  sse.Event(..sse.new(), data: Some(data))
}

/// Creates a comment, which clients ignore. Sending one periodically is the
/// conventional way to stop an idle stream being closed by a proxy.
pub fn comment(text: String) -> SseEvent {
  sse.Event(..sse.new(), comment: Some(text))
}

/// Sets the name of the event.
pub fn event_name(event: SseEvent, name: String) -> SseEvent {
  sse.Event(..event, name: Some(name))
}

/// Sets the ID of the event.
pub fn event_id(event: SseEvent, id: String) -> SseEvent {
  sse.Event(..event, id: Some(id))
}

/// Sets how long, in milliseconds, the client waits before reconnecting.
pub fn event_retry(event: SseEvent, retry: Int) -> SseEvent {
  sse.Event(..event, retry: Some(retry))
}

/// Sends event to the client.
pub fn send_event(
  conn: SseConnection,
  event: SseEvent,
) -> Result(Nil, socket.SocketReason) {
  case conn {
    connection.Http1Sse(conn) -> http1_sse.send(conn, event)
    connection.Http2Sse -> todo as "HTTP/2 is not implemented yet!"
  }
}

/// Turns the response into a Server-Sent Events stream, which runs until the
/// handler stops it or the client goes away. The HTTP/1.1 connection is 
/// reusable afterwards as long as the handler ended the stream itself and the 
/// client sent nothing during it.
///
/// `on_init` is called once, with a subject the rest of your program uses to
/// push messages at the client, and returns the starting state. `handler` is
/// called for each message sent to that subject. `on_close` is called once 
/// however the stream ended.
pub fn sse(
  response: response.Response(a),
  on_init on_init: fn(process.Subject(user_message)) -> user_state,
  handler handler: fn(SseConnection, user_state, user_message) ->
    SseNext(user_state),
  on_close on_close: fn(SseConnection, user_state) -> Nil,
) -> response.Response(Body) {
  let step = fn(conn, state, message) {
    case handler(conn, state, message) {
      SseContinue(state) -> sse.Proceed(state)
      SseStop -> sse.Halt(connection.Stopped)
      SseStopAbnormal(reason) -> sse.Halt(connection.StoppedAbnormal(reason))
    }
  }

  let stream = fn(conn) {
    case conn {
      connection.Http1Sse(conn) -> http1_sse.run(conn, on_init, step, on_close)
      connection.Http2Sse -> todo as "HTTP/2 is not implemented yet!"
    }
  }

  response.set_body(response, Sse(connection.SseMetadata(stream)))
}
