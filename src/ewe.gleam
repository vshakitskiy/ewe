//// <script>
//// const docs = [
////   {
////     header: "IP Address",
////     functions: ["ip_address_to_string"]
////   },
////   {
////     header: "Information",
////     functions: [
////       "get_client_info",
////       "get_server_info"
////     ]
////   },
////   {
////     header: "Builder",
////     functions: [
////       "new",
////       "bind",
////       "listening",
////       "listening_random",
////       "force_ipv6",
////       "unix",
////       "with_tls",
////       "with_tls_pem",
////       "with_tls_der",
////       "with_http1",
////       "default_http1_config",
////       "quiet",
////       "on_start"
////     ]
////   },
////   {
////     header: "Server",
////     functions: [
////       "start",
////       "supervised"
////     ]
////   },
////   {
////     header: "Request",
////     functions: [
////       "read_body",
////       "read_body_chunk"
////     ]
////   },
////   {
////     header: "Response",
////     functions: ["file"]
////   },
////   {
////     header: "Streaming Response",
////     functions: [
////       "stream_response",
////       "send_chunk",
////       "finish_chunk",
////       "finish_response"
////     ]
////   },
////   {
////     header: "Websocket",
////     functions: [
////       "websocket",
////       "send_binary_frame",
////       "send_text_frame",
////       "send_close_frame",
////       "websocket_continue",
////       "websocket_continue_with_selector",
////       "websocket_stop",
////       "websocket_stop_abnormal"
////     ]
////   },
////   {
////     header: "Server-Sent Events",
////     functions: [
////       "sse",
////       "event",
////       "comment",
////       "event_name",
////       "event_id",
////       "event_retry",
////       "send_event",
////       "sse_continue",
////       "sse_stop",
////       "sse_stop_abnormal"
////     ]
////   }
//// ]
////
//// const callback = () => {
////   const list = document.querySelector(".sidebar > ul:last-of-type")
////   const sortedLists = document.createDocumentFragment()
////   const sortedMembers = document.createDocumentFragment()
////
////   for (const section of docs) {
////     sortedLists.append((() => {
////       const node = document.createElement("h3")
////       node.append(section.header)
////       return node
////     })())
////     sortedMembers.append((() => {
////       const node = document.createElement("h2")
////       node.append(section.header)
////       return node
////     })())
////
////     const sortedList = document.createElement("ul")
////     sortedLists.append(sortedList)
////
////     const sortedFunctions = [...section.functions].sort()
////
////     for (const funcName of sortedFunctions) {
////       const href = `#${funcName}`
////       const member = document.querySelector(
////         `.member:has(h2 > a[href="${href}"])`
////       )
////       const sidebar = list.querySelector(`li:has(a[href="${href}"])`)
////       if (sidebar) sortedList.append(sidebar)
////       if (member) sortedMembers.append(member)
////     }
////   }
////
////   document.querySelector(".sidebar").insertBefore(sortedLists, list)
////   document
////     .querySelector(".module-members:has(#module-values)")
////     .insertBefore(
////       sortedMembers,
////       document.querySelector("#module-values").nextSibling
////     )
//// }
////
//// document.readyState !== "loading"
////   ? callback()
////   : document.addEventListener(
////     "DOMContentLoaded",
////     callback,
////     { once: true }
////   )
//// </script>

import ewe/internal/connection
import ewe/internal/file
import ewe/internal/handler as handler_
import ewe/internal/http1/body as http1_body
import ewe/internal/http1/connection as http1
import ewe/internal/http1/encoder
import ewe/internal/http1/sse as http1_sse
import ewe/internal/http1/websocket as http1_websocket
import ewe/internal/sse
import ewe/internal/websocket
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
import gleam/string
import glisten
import glisten/internal/handler
import glisten/internal/listener
import glisten/socket
import glisten/socket/options
import glisten/transport
import logging
import websocks

pub type Connection =
  connection.Connection

pub type Body {
  Bytes(bytes_tree.BytesTree)
  Text(String)
  Empty
  File(connection.File)
  Streaming(connection.Streaming)
  Sse(connection.Sse)
  Websocket(connection.Websocket)
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

/// The limits and timeouts for every HTTP/1 connection. Build one by updating 
/// `default_http1_config`:
///
/// ```gleam
/// Http1Config(..ewe.default_http1_config(), max_headers: 50)
/// ```
///
/// Sizes are in bytes and timeouts in milliseconds.
pub type Http1Config {
  Http1Config(
    /// Longest request line accepted beyond which the request is refused with a 
    /// 414.
    max_request_line: Int,
    /// Longest single header line accepted beyond which the request is refused 
    /// with a 431.
    max_header_line: Int,
    /// How many header fields a request may carry beyond which it is refused
    /// with a 431.
    max_headers: Int,
    /// Longest chunk size line accepted in a chunked body.
    max_chunk_size_line: Int,
    /// How long a connection may sit without sending anything before it is
    /// closed.
    idle_timeout: Int,
    /// How long a single read of a request body waits for the client.
    body_read_timeout: Int,
    /// How much of a body the handler never read is drained so the connection
    /// can be reused. A body larger than this closes the connection instead.
    auto_drain_limit: Int,
    /// How much of that drain is read at a time.
    auto_drain_chunk_bytes: Int,
  )
}

pub fn default_http1_config() -> Http1Config {
  let http1.Config(
    max_request_line:,
    max_header_line:,
    max_headers:,
    max_chunk_size_line:,
    idle_timeout:,
    body_read_timeout:,
    auto_drain_limit:,
    auto_drain_chunk_bytes:,
  ) = http1.default_config()

  Http1Config(
    max_request_line:,
    max_header_line:,
    max_headers:,
    max_chunk_size_line:,
    idle_timeout:,
    body_read_timeout:,
    auto_drain_limit:,
    auto_drain_chunk_bytes:,
  )
}

fn to_internal_http1_config(config: Http1Config) -> http1.Config {
  let Http1Config(
    max_request_line:,
    max_header_line:,
    max_headers:,
    max_chunk_size_line:,
    idle_timeout:,
    body_read_timeout:,
    auto_drain_limit:,
    auto_drain_chunk_bytes:,
  ) = config

  http1.Config(
    max_request_line:,
    max_header_line:,
    max_headers:,
    max_chunk_size_line:,
    idle_timeout:,
    body_read_timeout:,
    auto_drain_limit:,
    auto_drain_chunk_bytes:,
  )
}

/// Contains all server configurations, can be adjusted by different builder
/// functions.
pub opaque type Builder {
  Builder(
    handler: fn(request.Request(Connection)) -> response.Response(Body),
    bind_target: BindTarget,
    tls: Option(TlsConfig),
    http1: Http1Config,
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
    http1: default_http1_config(),
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

/// Replaces the limits and timeouts applied to HTTP/1 connections.
pub fn with_http1(builder: Builder, config: Http1Config) -> Builder {
  Builder(..builder, http1: config)
}

fn to_internal_body(body: Body) -> connection.Body {
  case body {
    Bytes(tree) -> connection.Bytes(tree)
    Text(text) -> connection.Text(text)
    Empty -> connection.Empty
    File(file) -> connection.File(file)
    Streaming(streaming) -> connection.Streaming(streaming)
    Sse(sse) -> connection.Sse(sse)
    Websocket(websocket) -> connection.Websocket(websocket)
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
      on_init: handler_.on_init(
        handler,
        to_internal_http1_config(builder.http1),
      ),
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
///
/// On HTTP/1 this opens the file, and the returned body holds it open until the
/// response is written. Put it on a response you go on to return. A body that
/// is built and then discarded keeps its file open until it is collected.
pub fn file(
  connection: Connection,
  path: String,
  offset offset: Option(Int),
  limit limit: Option(Int),
) -> Result(Body, FileError) {
  case file.resolve(connection, path, offset, limit) {
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

/// Why a write to the client did not go through. TODO: obviously not the string 
/// reason variant but this is for later!
pub type SendError {
  SendError(reason: String)
}

fn to_send_error(reason: socket.SocketReason) -> SendError {
  SendError(socket.reason_to_string(reason))
}

/// A handle for writing a streamed response's body, obtained from
/// `stream_response`.
pub type ResponseWriter =
  connection.ResponseWriter

/// Starts a streamed response. `handler` must end by calling `finish_chunk` or
/// `finish_response` on it, since that's what closes the stream.
///
/// A send to a client that has gone ends the handler there and then, rather
/// than letting it carry on producing a body with nowhere to go. Nothing after
/// that send runs, so hold anything that needs releasing in a way that survives
/// on the process ending rather than in code after the write.
pub fn stream_response(
  response: response.Response(a),
  handler: fn(ResponseWriter) -> Result(Nil, SendError),
) -> response.Response(Body) {
  // What the handler was left holding when a write failed is its own business,
  // ewe already learns whether the stream finished from the writer.
  let stream = fn(writer) {
    let _sent = handler(writer)
    Nil
  }

  response.set_body(response, Streaming(connection.StreamingMetadata(stream)))
}

/// Sends one response body chunk, threading the writer through so it can be
/// piped. For the last chunk use `finish_chunk` instead, it closes the
/// stream in the same round trip.
pub fn send_chunk(
  writer: ResponseWriter,
  chunk: BitArray,
) -> Result(ResponseWriter, SendError) {
  case writer {
    connection.Http1Writer(writer) ->
      encoder.send_chunk(writer, chunk)
      |> result.map(connection.Http1Writer)
      |> result.map_error(to_send_error)
    connection.Http2Writer -> todo as "HTTP/2 is not implemented yet!"
  }
}

/// Sends `chunk` as the final response body chunk and closes the stream.
pub fn finish_chunk(
  writer: ResponseWriter,
  chunk: BitArray,
) -> Result(Nil, SendError) {
  case writer {
    connection.Http1Writer(writer) ->
      encoder.finish_chunk(writer, chunk) |> result.map_error(to_send_error)
    connection.Http2Writer -> todo as "HTTP/2 is not implemented yet!"
  }
}

/// Closes the stream with no further data. Use `finish_chunk` instead if
/// there's one last chunk to send.
pub fn finish_response(writer: ResponseWriter) -> Result(Nil, SendError) {
  case writer {
    connection.Http1Writer(writer) ->
      encoder.finish_response(writer) |> result.map_error(to_send_error)
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

/// Sends event to the client. If the client has gone the stream ends here:
/// `on_close` runs and the handler is not called again.
pub fn send_event(
  conn: SseConnection,
  event: SseEvent,
) -> Result(Nil, SendError) {
  case conn {
    connection.Http1Sse(conn) ->
      http1_sse.send(conn, event) |> result.map_error(to_send_error)
    connection.Http2Sse -> todo as "HTTP/2 is not implemented yet!"
  }
}

/// Turns the response into a Server-Sent Events stream, which runs until the
/// handler stops it or the client goes away. The HTTP/1.1 connection is 
/// reusable afterwards as long as the handler ended the stream itself and the 
/// client sent nothing during it.
///
/// - `on_init` is called once, with a subject the rest of your program uses to
/// push messages at the client, and returns the starting state. 
/// - `handler` is called for each message sent to that subject. 
/// - `on_close` is called once however the stream ended.
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

/// A handle for sending frames on an open WebSocket.
pub type WebsocketConnection =
  connection.WebsocketConnection

/// What the client sent or what the rest of your program sent to the subject
/// given to `on_init`. Ping and pong frames are answered by the server and do
/// not reach the handler.
pub type WebsocketMessage(user_message) {
  TextFrame(text: String)
  BinaryFrame(data: BitArray)
  UserMessage(message: user_message)
}

fn from_internal_websocket_message(
  message: websocket.Message(user_message),
) -> WebsocketMessage(user_message) {
  case message {
    websocket.TextFrame(text) -> TextFrame(text)
    websocket.BinaryFrame(data) -> BinaryFrame(data)
    websocket.UserMessage(message) -> UserMessage(message)
  }
}

/// What a WebSocket does after the handler has dealt with a message. Build it
/// with `websocket_continue`, `websocket_stop` or `websocket_stop_abnormal`.
pub opaque type WebsocketNext(user_state, user_message) {
  WebsocketContinue(user_state, Option(process.Selector(user_message)))
  WebsocketStop
  WebsocketStopAbnormal(reason: String)
}

/// Carries on handling further messages with `user_state` and the selector the
/// connection already has.
pub fn websocket_continue(
  user_state: user_state,
) -> WebsocketNext(user_state, user_message) {
  WebsocketContinue(user_state, None)
}

/// Carries on listening on `selector` from here on instead of the one the
/// connection was started with.
pub fn websocket_continue_with_selector(
  user_state: user_state,
  selector: process.Selector(user_message),
) -> WebsocketNext(user_state, user_message) {
  WebsocketContinue(user_state, Some(selector))
}

/// Ends the WebSocket.
pub fn websocket_stop() -> WebsocketNext(user_state, user_message) {
  WebsocketStop
}

/// Ends the WebSocket reporting `reason` as the cause.
pub fn websocket_stop_abnormal(
  reason: String,
) -> WebsocketNext(user_state, user_message) {
  WebsocketStopAbnormal(reason)
}

/// Why a WebSocket is being closed, sent to the client in the close frame.
pub type CloseReason {
  /// Close without saying why.
  NoCloseReason
  /// Close with a status code and a description, which may be empty.
  CloseReason(code: CloseCode, reason: String)
}

/// The status code a close frame carries. The codes that exist only to be
/// reported locally such as 1005 and 1006 are absent. Sending one is a
/// protocol violation.
pub type CloseCode {
  /// The connection did what it was for and is closing normally (1000).
  NormalClosure
  /// The endpoint is going away, from a server shutdown or a client navigating
  /// away (1001).
  GoingAway
  /// The other end broke the protocol (1002).
  ProtocolError
  /// Data arrived that this endpoint cannot accept (1003).
  UnsupportedData
  /// A message did not match the type it declared, such as a text frame that
  /// is not UTF-8 (1007).
  InvalidPayloadData
  /// The other end broke your rules, when no more specific code applies (1008).
  PolicyViolation
  /// A message was larger than this endpoint will handle (1009).
  MessageTooBig
  /// An extension the client required was not negotiated (1010).
  MandatoryExtension
  /// Something went wrong on this side (1011).
  InternalError
  /// The server is restarting, and clients may reconnect shortly (1012).
  ServiceRestart
  /// The server is overloaded and the client should retry later (1013).
  TryAgainLater
  /// An upstream server answered badly (1014).
  BadGateway
  /// An application specific code, which must be between 3000 and 4999.
  ApplicationCode(code: Int)
}

fn to_internal_close_reason(reason: CloseReason) -> websocks.CloseReason {
  case reason {
    NoCloseReason -> websocks.NoCloseReason
    CloseReason(code:, reason:) ->
      websocks.CloseReason(to_internal_close_code(code), reason)
  }
}

fn to_internal_close_code(code: CloseCode) -> websocks.CloseCode {
  case code {
    NormalClosure -> websocks.NormalClosure
    GoingAway -> websocks.GoingAway
    ProtocolError -> websocks.ProtocolError
    UnsupportedData -> websocks.UnsupportedData
    InvalidPayloadData -> websocks.InvalidPayloadData
    PolicyViolation -> websocks.PolicyViolation
    MessageTooBig -> websocks.MessageTooBig
    MandatoryExtension -> websocks.MandatoryExtension
    InternalError -> websocks.InternalError
    ServiceRestart -> websocks.ServiceRestart
    TryAgainLater -> websocks.TryAgainLater
    BadGateway -> websocks.BadGateway
    ApplicationCode(code:) -> websocks.ApplicationCode(code:)
  }
}

/// Sends a text frame. If the client has gone the WebSocket ends here.
pub fn send_text_frame(
  conn: WebsocketConnection,
  text: String,
) -> Result(Nil, SendError) {
  case conn {
    connection.Http1Websocket(conn) ->
      http1_websocket.send_text(conn, text) |> result.map_error(to_send_error)
    connection.Http2Websocket -> todo as "HTTP/2 is not implemented yet!"
  }
}

/// Sends a binary frame. If the client has gone the WebSocket ends here.
pub fn send_binary_frame(
  conn: WebsocketConnection,
  data: BitArray,
) -> Result(Nil, SendError) {
  case conn {
    connection.Http1Websocket(conn) ->
      http1_websocket.send_binary(conn, data) |> result.map_error(to_send_error)
    connection.Http2Websocket -> todo as "HTTP/2 is not implemented yet!"
  }
}

/// Starts the closing handshake and ends the WebSocket. Return the value this
/// gives back from your handler, no frame can be sent after it.
pub fn send_close_frame(
  conn: WebsocketConnection,
  reason: CloseReason,
) -> WebsocketNext(user_state, user_message) {
  let _sent = case conn {
    connection.Http1Websocket(conn) ->
      http1_websocket.send_close(conn, to_internal_close_reason(reason))
    connection.Http2Websocket -> todo as "HTTP/2 is not implemented yet!"
  }

  WebsocketStop
}

/// Turns the response into a WebSocket which runs until the handler stops it
/// or the client goes away. The connection stops being HTTP once the handshake
/// is written so it never carries another request.
///
/// A request that is not a valid handshake is answered with a 400 and the
/// handler is never run.
///
/// - `on_init` is called once with an empty selector to add whatever the rest 
/// of your program sends this connection to and returns the starting state 
/// along with that selector. 
/// - `handler` is called for each frame from the client and each message the 
/// selector picks up. 
/// - `on_close` is called once however the WebSocket ended.
pub fn websocket(
  request request: request.Request(Connection),
  on_init on_init: fn(WebsocketConnection, process.Selector(user_message)) ->
    #(user_state, process.Selector(user_message)),
  handler handler: fn(
    WebsocketConnection,
    user_state,
    WebsocketMessage(user_message),
  ) -> WebsocketNext(user_state, user_message),
  on_close on_close: fn(WebsocketConnection, user_state) -> Nil,
) -> response.Response(Body) {
  let step = fn(conn, state, message) {
    case handler(conn, state, from_internal_websocket_message(message)) {
      WebsocketContinue(state, messages) -> websocket.Proceed(state, messages)
      WebsocketStop -> websocket.Halt(connection.Stopped)
      WebsocketStopAbnormal(reason) ->
        websocket.Halt(connection.StoppedAbnormal(reason))
    }
  }

  let socket = fn(conn) {
    case conn {
      connection.Http1Websocket(conn) ->
        http1_websocket.run(conn, on_init, step, on_close)
      connection.Http2Websocket -> todo as "HTTP/2 is not implemented yet!"
    }
  }

  case request.body {
    connection.Http1(conn) ->
      case http1_websocket.handshake(request.method, conn) {
        Ok(http1_websocket.Handshake(accept:, compression:)) -> {
          let context = websocks.create_context(compression, websocks.Server)

          response.Response(
            status: 101,
            headers: handshake_headers(accept, compression),
            body: Websocket(connection.WebsocketMetadata(
              context:,
              handler: socket,
            )),
          )
        }
        Error(error) -> {
          logging.log(
            logging.Debug,
            "Rejected a WebSocket handshake: "
              <> http1_websocket.handshake_error_to_string(error),
          )

          response.set_body(response.new(400), Empty)
        }
      }
    connection.Http2 -> todo as "HTTP/2 is not implemented yet!"
  }
}

fn handshake_headers(
  accept: String,
  compression: option.Option(websocks.CompressionExtensions),
) -> List(#(String, String)) {
  let headers = [
    #("connection", "upgrade"),
    #("upgrade", "websocket"),
    #("sec-websocket-accept", accept),
  ]

  case compression {
    Some(extensions) -> [
      #("sec-websocket-extensions", compression_header(extensions)),
      ..headers
    ]
    None -> headers
  }
}

fn compression_header(extensions: websocks.CompressionExtensions) -> String {
  let websocks.CompressionExtensions(
    client_no_context_takeover:,
    client_max_window_bits:,
    server_no_context_takeover:,
    server_max_window_bits:,
  ) = extensions

  ["permessage-deflate"]
  |> append_flag(client_no_context_takeover, "client_no_context_takeover")
  |> append_flag(server_no_context_takeover, "server_no_context_takeover")
  |> append_window_bits(client_max_window_bits, "client_max_window_bits")
  |> append_window_bits(server_max_window_bits, "server_max_window_bits")
  |> list.reverse
  |> string.join("; ")
}

fn append_flag(
  parameters: List(String),
  enabled: Bool,
  name: String,
) -> List(String) {
  case enabled {
    True -> [name, ..parameters]
    False -> parameters
  }
}

fn append_window_bits(
  parameters: List(String),
  bits: Option(Int),
  name: String,
) -> List(String) {
  case bits {
    Some(bits) -> [name <> "=" <> int.to_string(bits), ..parameters]
    None -> parameters
  }
}
