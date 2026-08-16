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
////       "with_http1",
////       "default_http1_options",
////       "with_http2",
////       "default_http2_options",
////       "with_client_verification",
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
////   },
////   {
////     header: "Errors",
////     functions: [
////       "send_error_to_string",
////       "socket_reason_to_string"
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
import ewe/internal/http2/body as http2_body
import ewe/internal/http2/connection as http2
import ewe/internal/http2/sse as http2_sse
import ewe/internal/http2/stream as http2_stream
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

/// The connection a request arrived on.
///
/// This is the body of the request given to your handler. Pass it to `read_body` 
/// or `read_body_chunk` to read the request body, or to `file` to send a file 
/// back.
pub type Connection =
  connection.Connection

/// The body of a HTTP response to be sent to the client.
///
/// The `Streaming`, `Sse` and `Websocket` variants are created by the functions 
/// rather than directly.
pub type Body {
  /// A body of binary data stored as a `BytesTree`.
  ///
  /// If you have a `BitArray` you can use the `bytes_tree.from_bit_array`
  /// function to convert it.
  Bytes(bytes_tree.BytesTree)
  /// A body of unicode text sent as UTF-8.
  Text(String)
  /// No body. The response is sent with a `content-length` of 0.
  Empty
  /// A body of the contents of a file created with the `file` function.
  ///
  /// Large files are safe to send this way as they are never held in memory
  /// whole. See `file` for how each protocol sends them.
  File(connection.File)
  /// A body written a chunk at a time created with the `stream_response` 
  /// function.
  Streaming(connection.Streaming)
  /// A Server-Sent Events stream created with the `sse` function.
  Sse(connection.Sse)
  /// A WebSocket created with the `websocket` function.
  ///
  /// The connection stops being HTTP once the handshake has been sent so it
  /// will never carry another request.
  Websocket(connection.Websocket)
}

/// An IP address.
pub type IpAddress {
  /// An IPv4 address, represented as its four bytes. `127.0.0.1` is 
  /// `IpV4(127, 0, 0, 1)`.
  IpV4(Int, Int, Int, Int)
  /// An IPv6 address, represented as its eight groups. `::1` is
  /// `IpV6(0, 0, 0, 0, 0, 0, 0, 1)`.
  IpV6(Int, Int, Int, Int, Int, Int, Int, Int)
}

/// Convert an IP address to the string form. IPv6 addresses are written in 
/// lowercase, with the longest run of zero groups collapsed to `::`.
///
/// # Examples
///
/// ```gleam
/// ip_address_to_string(IpV4(127, 0, 0, 1))
/// // -> "127.0.0.1"
///
/// ip_address_to_string(IpV6(0, 0, 0, 0, 0, 0, 0, 1))
/// // -> "::1"
/// ```
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

/// The address a socket is bound to or the address of a connected peer.
pub type SocketAddress {
  /// An address and port on a TCP socket.
  TcpSocketAddress(ip_address: IpAddress, port: Int)
  /// The path of a Unix domain socket.
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

/// Get the address of the client at the other end of the connection.
///
/// Returns an error if the address could not be looked up such as when the
/// connection has already closed.
pub fn get_client_info(connection: Connection) -> Result(SocketAddress, Nil) {
  // An HTTP/2 handler runs in a process that has no access to the socket so the
  // address is resolved once for the connection and carried on every stream.
  let peername = case connection {
    connection.Http1(connection) ->
      transport.peername(connection.transport, connection.socket)
    connection.Http2(connection) -> connection.peer
  }

  use info <- result.map(over: peername)

  case info {
    socket.TcpSockName(ip_address:, port:) ->
      from_internal_options_ip_address(ip_address)
      |> TcpSocketAddress(port:)
    socket.UnixSockName(path:) -> UnixSocketAddress(path:)
  }
}

/// Get the address the server is listening on. This is how you find the port
/// picked by `listening_random`.
///
/// The server must be running. Pass the subject of the `listener_name` given
/// to `new`.
///
/// # Examples
///
/// ```gleam
/// process.named_subject(listener_name)
/// |> ewe.get_server_info
/// // -> TcpSocketAddress(IpV4(127, 0, 0, 1), 3000)
/// ```
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

/// The source of the TLS certificate and key given to `with_tls`.
pub type Tls {
  /// Paths to PEM-encoded certificate and key files on disk.
  Disk(cert: String, key: String)
  /// In-memory PEM-encoded certificate and key.
  Pem(cert: BitArray, key: BitArray)
  /// In-memory DER-encoded certificate and key.
  Der(cert: BitArray, key: BitArray, key_type: TlsKeyType)
}

/// The type of a DER-encoded private key needed by the `Der` variant of `Tls`.
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

/// The limits and timeouts applied to every HTTP/1 connection.
///
/// Sizes are in bytes and timeouts in milliseconds. Build one by updating
/// `default_http1_options` so you only state the ones you care about.
///
/// A value outside the range a field accepts is replaced with the default and
/// logged as a warning when the server starts.
///
/// # Examples
///
/// ```gleam
/// Http1Options(..ewe.default_http1_options(), max_headers: 50)
/// ```
pub type Http1Options {
  Http1Options(
    /// The longest request line accepted. A longer one is refused with status
    /// code 414: URI Too Long.
    max_request_line: Int,
    /// The longest single header line accepted. A longer one is refused with
    /// status code 431: Request Header Fields Too Large.
    max_header_line: Int,
    /// The most header fields a request may carry. More than this is refused
    /// with status code 431: Request Header Fields Too Large.
    max_headers: Int,
    /// The longest chunk size line accepted in a chunked body. A longer one is
    /// refused with status code 413: Content Too Large.
    max_chunk_size_line: Int,
    /// How long a connection may sit without sending anything before it is
    /// closed.
    idle_timeout: Int,
    /// How long a single read of a request body waits for the client.
    body_read_timeout: Int,
    /// How much of a body the handler never read is drained so that the
    /// connection can be reused. A larger body closes the connection instead.
    auto_drain_limit: Int,
    /// How much of that drain is read at a time.
    auto_drain_chunk_bytes: Int,
  )
}

/// Get the default HTTP/1 limits and timeouts to be adjusted and given to
/// `with_http1`.
pub fn default_http1_options() -> Http1Options {
  let http1.Options(
    max_request_line:,
    max_header_line:,
    max_headers:,
    max_chunk_size_line:,
    idle_timeout:,
    body_read_timeout:,
    auto_drain_limit:,
    auto_drain_chunk_bytes:,
  ) = http1.default_options()

  Http1Options(
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

fn out_of_range(field: String, value: String, default: String) -> Nil {
  logging.log(
    logging.Warning,
    field <> " of " <> value <> " is out of range, using " <> default,
  )
}

fn at_least(value: Int, minimum: Int, default: Int, field: String) -> Int {
  case value >= minimum {
    True -> value
    False -> {
      out_of_range(field, int.to_string(value), int.to_string(default))
      default
    }
  }
}

fn within(
  value: Int,
  minimum: Int,
  maximum: Int,
  default: Int,
  field: String,
) -> Int {
  case value >= minimum && value <= maximum {
    True -> value
    False -> {
      out_of_range(field, int.to_string(value), int.to_string(default))
      default
    }
  }
}

fn optional_at_least(
  value: Option(Int),
  minimum: Int,
  default: Option(Int),
  field: String,
) -> Option(Int) {
  case value {
    Some(limit) if limit < minimum -> {
      out_of_range(field, int.to_string(limit), limit_to_string(default))
      default
    }
    _value -> value
  }
}

fn limit_to_string(limit: Option(Int)) -> String {
  case limit {
    Some(limit) -> int.to_string(limit)
    None -> "no limit"
  }
}

fn to_internal_http1_options(options: Http1Options) -> http1.Options {
  let defaults = http1.default_options()

  http1.Options(
    max_request_line: at_least(
      options.max_request_line,
      1,
      defaults.max_request_line,
      "max_request_line",
    ),
    max_header_line: at_least(
      options.max_header_line,
      1,
      defaults.max_header_line,
      "max_header_line",
    ),
    max_headers: at_least(
      options.max_headers,
      1,
      defaults.max_headers,
      "max_headers",
    ),
    max_chunk_size_line: at_least(
      options.max_chunk_size_line,
      1,
      defaults.max_chunk_size_line,
      "max_chunk_size_line",
    ),
    idle_timeout: at_least(
      options.idle_timeout,
      1,
      defaults.idle_timeout,
      "idle_timeout",
    ),
    body_read_timeout: at_least(
      options.body_read_timeout,
      1,
      defaults.body_read_timeout,
      "body_read_timeout",
    ),
    auto_drain_limit: at_least(
      options.auto_drain_limit,
      0,
      defaults.auto_drain_limit,
      "auto_drain_limit",
    ),
    auto_drain_chunk_bytes: at_least(
      options.auto_drain_chunk_bytes,
      1,
      defaults.auto_drain_chunk_bytes,
      "auto_drain_chunk_bytes",
    ),
  )
}

const max_window_size = 2_147_483_647

/// The limits and timeouts applied to every HTTP/2 connection.
///
/// Sizes are in bytes and timeouts in milliseconds. Build one by updating
/// `default_http2_options` so you only state the ones you care about.
///
/// A value outside the range a field accepts is replaced with the default and 
/// logged as a warning when the server starts.
///
/// # Examples
///
/// ```gleam
/// Http2Options(..ewe.default_http2_options(), max_concurrent_streams: Some(100))
/// ```
pub type Http2Options {
  Http2Options(
    /// The most streams a client may have open at once. `None` leaves it
    /// unlimited.
    max_concurrent_streams: Option(Int),
    /// How much response body a stream may have in flight before the client
    /// has to allow more. Must be within 0 and 2147483647.
    initial_window_size: Int,
    /// The largest frame the server accepts. Must be within 16384 and 16777215.
    max_frame_size: Int,
    /// The largest header list the server accepts. `None` leaves it unlimited.
    max_header_list_size: Option(Int),
    /// How much HPACK dynamic table the server keeps for decoding.
    header_table_size: Int,
    /// The most CONTINUATION frames one header sequence may span.
    max_continuation_frames: Int,
    /// The most bytes of HEADERS and CONTINUATION one header block may total,
    /// counted before it is decoded.
    max_header_block_bytes: Int,
    /// The window over which client stream resets are counted.
    rapid_reset_window: Int,
    /// How many resets within that window trip a GOAWAY which is what stops
    /// Rapid Reset (CVE-2023-44487) costing more than it should.
    rapid_reset_threshold: Int,
    /// How long a connection may sit in the preface and SETTINGS handshake
    /// before it is dropped.
    handshake_timeout: Int,
    /// How long a draining connection waits for its streams to finish after
    /// GOAWAY before closing.
    drain_timeout: Int,
    /// Once a receive window falls to this it is topped straight back up to
    /// `recv_window_high_water_mark` rather than trickling small updates.
    recv_window_low_water_mark: Int,
    /// What a receive window is topped up to. The wider the gap from the low
    /// mark the fewer WINDOW_UPDATE round trips a large body costs.
    recv_window_high_water_mark: Int,
    /// Files at or below this size are read into memory and framed like any
    /// other body. Larger ones are streamed from disk instead.
    file_read_threshold: Int,
    /// How long a single read of a request body waits for the client.
    body_read_timeout: Int,
  )
}

/// Get the default HTTP/2 limits and timeouts to be adjusted and given to
/// `with_http2`.
pub fn default_http2_options() -> Http2Options {
  let http2.Options(
    max_concurrent_streams:,
    initial_window_size:,
    max_frame_size:,
    max_header_list_size:,
    header_table_size:,
    max_continuation_frames:,
    max_header_block_bytes:,
    rapid_reset_window_ms:,
    rapid_reset_threshold:,
    handshake_timeout_ms:,
    drain_timeout_ms:,
    recv_window_low_water_mark:,
    recv_window_high_water_mark:,
    file_read_threshold:,
    body_read_timeout:,
  ) = http2.default_options()

  Http2Options(
    max_concurrent_streams:,
    initial_window_size:,
    max_frame_size:,
    max_header_list_size:,
    header_table_size:,
    max_continuation_frames:,
    max_header_block_bytes:,
    rapid_reset_window: rapid_reset_window_ms,
    rapid_reset_threshold:,
    handshake_timeout: handshake_timeout_ms,
    drain_timeout: drain_timeout_ms,
    recv_window_low_water_mark:,
    recv_window_high_water_mark:,
    file_read_threshold:,
    body_read_timeout:,
  )
}

fn to_internal_http2_options(options: Http2Options) -> http2.Options {
  let defaults = http2.default_options()

  let #(recv_window_low_water_mark, recv_window_high_water_mark) = case
    options.recv_window_low_water_mark,
    options.recv_window_high_water_mark
  {
    low, high if low > 0 && low < high && high <= max_window_size -> #(low, high)
    low, high -> {
      out_of_range(
        "recv window water marks",
        int.to_string(low) <> " and " <> int.to_string(high),
        int.to_string(defaults.recv_window_low_water_mark)
          <> " and "
          <> int.to_string(defaults.recv_window_high_water_mark),
      )

      #(
        defaults.recv_window_low_water_mark,
        defaults.recv_window_high_water_mark,
      )
    }
  }

  http2.Options(
    max_concurrent_streams: optional_at_least(
      options.max_concurrent_streams,
      1,
      defaults.max_concurrent_streams,
      "max_concurrent_streams",
    ),
    initial_window_size: within(
      options.initial_window_size,
      0,
      max_window_size,
      defaults.initial_window_size,
      "initial_window_size",
    ),
    max_frame_size: within(
      options.max_frame_size,
      16_384,
      16_777_215,
      defaults.max_frame_size,
      "max_frame_size",
    ),
    max_header_list_size: optional_at_least(
      options.max_header_list_size,
      1,
      defaults.max_header_list_size,
      "max_header_list_size",
    ),
    header_table_size: at_least(
      options.header_table_size,
      0,
      defaults.header_table_size,
      "header_table_size",
    ),
    max_continuation_frames: at_least(
      options.max_continuation_frames,
      1,
      defaults.max_continuation_frames,
      "max_continuation_frames",
    ),
    max_header_block_bytes: at_least(
      options.max_header_block_bytes,
      1,
      defaults.max_header_block_bytes,
      "max_header_block_bytes",
    ),
    rapid_reset_window_ms: at_least(
      options.rapid_reset_window,
      1,
      defaults.rapid_reset_window_ms,
      "rapid_reset_window",
    ),
    rapid_reset_threshold: at_least(
      options.rapid_reset_threshold,
      1,
      defaults.rapid_reset_threshold,
      "rapid_reset_threshold",
    ),
    handshake_timeout_ms: at_least(
      options.handshake_timeout,
      1,
      defaults.handshake_timeout_ms,
      "handshake_timeout",
    ),
    drain_timeout_ms: at_least(
      options.drain_timeout,
      1,
      defaults.drain_timeout_ms,
      "drain_timeout",
    ),
    recv_window_low_water_mark:,
    recv_window_high_water_mark:,
    file_read_threshold: at_least(
      options.file_read_threshold,
      0,
      defaults.file_read_threshold,
      "file_read_threshold",
    ),
    body_read_timeout: at_least(
      options.body_read_timeout,
      1,
      defaults.body_read_timeout,
      "body_read_timeout",
    ),
  )
}

/// The certificate authority a client's certificate has to be signed by, given
/// to `with_client_verification`.
pub type ClientVerification {
  /// Path to a PEM file holding the CA certificate.
  CaCertFile(path: String)
  /// In-memory DER-encoded CA certificates.
  CaCertData(certs: List(BitArray))
}

fn to_internal_client_verification(
  verification: ClientVerification,
) -> glisten.CaCert {
  case verification {
    CaCertFile(path:) -> glisten.CaCertFile(path)
    CaCertData(certs:) -> glisten.CaCertData(certs)
  }
}

/// The configuration of a server.
///
/// Create one with `new`, adjust it with the builder functions, then give it to
/// `start` or `supervised`.
pub opaque type Builder {
  Builder(
    handler: fn(request.Request(Connection)) -> response.Response(Body),
    bind_target: BindTarget,
    tls: Option(Tls),
    client_verification: Option(ClientVerification),
    http1: Http1Options,
    http2: Http2Options,
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

/// Create a new server configuration. The handler is called for every request
/// and the response it returns is sent to the client.
///
/// The two names are used by the acceptor pool to wire its listener and its
/// connection factory together. Create them once where your program starts
/// and pass them in here.
///
/// The server listens on 127.0.0.1:3000 and prints its address once started.
/// Use `bind`, `listening` and `on_start` to change that.
///
/// # Examples
///
/// ```gleam
/// pub fn main() {
///   let listener_name = process.new_name("listener_name")
///   let connection_factory_name = process.new_name("connection_factory_name")
///
///   let assert Ok(_) =
///     ewe.new(listener_name:, connection_factory_name:, handler: handle_request)
///     |> ewe.bind(to: "0.0.0.0")
///     |> ewe.listening(on: 8080)
///     |> ewe.start
///
///   process.sleep_forever()
/// }
/// ```
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
    client_verification: None,
    http1: default_http1_options(),
    http2: default_http2_options(),
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

/// Set the network interface the server listens on. `"127.0.0.1"` and
/// `"localhost"` are the loopback, `"0.0.0.0"` is every IPv4 interface, `"::1"`
/// is the IPv6 loopback, and `"::"` is every IPv6 interface.
///
/// A server listens on either a network interface or a Unix socket so this
/// undoes a previous call to `unix`.
///
/// # Panics
///
/// Starting the server will panic if the interface is not `"localhost"` or a
/// valid IPv4 or IPv6 address.
pub fn bind(builder: Builder, to interface: String) -> Builder {
  let bind_target = case builder.bind_target {
    TcpBind(port:, ipv6:, ..) -> TcpBind(interface:, port:, ipv6:)
    UnixBind(..) -> TcpBind(interface:, port: 3000, ipv6: False)
  }

  Builder(..builder, bind_target:)
}

/// Set the port the server listens on.
///
/// A server listens on either a network interface or a Unix socket so this
/// undoes a previous call to `unix`.
pub fn listening(builder: Builder, on port: Int) -> Builder {
  let bind_target = case builder.bind_target {
    TcpBind(interface:, ipv6:, ..) -> TcpBind(interface:, port:, ipv6:)
    UnixBind(..) -> TcpBind(interface: "127.0.0.1", port:, ipv6: False)
  }
  Builder(..builder, bind_target:)
}

/// Listen on port 0, which asks the operating system for any free port. This
/// is useful in tests where a fixed port would clash.
///
/// Use `get_server_info` once the server is running to find the port it was
/// given.
pub fn listening_random(builder: Builder) -> Builder {
  listening(builder, on: 0)
}

/// Serve over IPv6.
///
/// `bind` must have been given an IPv6 address, or one of `"localhost"`,
/// `"127.0.0.1"` and `"0.0.0.0"`, which are bound so that they work over either
/// address family. The server crashes on start with any other IPv4 address and
/// with any address at all if the system has no IPv6 support.
pub fn force_ipv6(builder: Builder) -> Builder {
  let bind_target = case builder.bind_target {
    TcpBind(interface:, port:, ..) -> TcpBind(interface:, port:, ipv6: True)
    UnixBind(..) -> TcpBind(interface: "127.0.0.1", port: 3000, ipv6: True)
  }

  Builder(..builder, bind_target:)
}

/// Listen on a Unix domain socket at the given path instead of on TCP.
///
/// A server listens on either a network interface or a Unix socket so this
/// discards any interface, port and IPv6 setting made before it.
pub fn unix(builder: Builder, path: String) -> Builder {
  Builder(..builder, bind_target: UnixBind(path))
}

/// Serve over TLS with the given certificate and key.
///
/// This is also what offers HTTP/2 to clients through ALPN. Without TLS a
/// client only gets HTTP/2 by opening the connection with the h2c preface.
///
/// # Examples
///
/// ```gleam
/// ewe.with_tls(builder, ewe.Disk("cert.pem", "key.pem"))
/// ewe.with_tls(builder, ewe.Pem(cert, key))
/// ewe.with_tls(builder, ewe.Der(cert, key, ewe.RsaPrivateKey))
/// ```
pub fn with_tls(builder: Builder, tls: Tls) -> Builder {
  Builder(..builder, tls: Some(tls))
}

/// Set the function to run once the server is listening. It is given the
/// scheme and the address the server ended up on.
///
/// By default this prints the address. Use `quiet` to say nothing instead.
pub fn on_start(
  builder: Builder,
  on_start: fn(http.Scheme, SocketAddress) -> Nil,
) -> Builder {
  Builder(..builder, on_start:)
}

/// Print nothing when the server starts by replacing the default `on_start`
/// function with one that does nothing.
pub fn quiet(builder: Builder) -> Builder {
  Builder(..builder, on_start: fn(_scheme, _address) { Nil })
}

/// Set the limits and timeouts applied to every HTTP/1 connection.
pub fn with_http1(builder: Builder, options: Http1Options) -> Builder {
  Builder(..builder, http1: options)
}

/// Set the limits and timeouts applied to every HTTP/2 connection.
pub fn with_http2(builder: Builder, options: Http2Options) -> Builder {
  Builder(..builder, http2: options)
}

/// Require clients to present a certificate signed by the given authority.
/// Clients that do not are refused.
///
/// This needs TLS which `with_tls` sets up.
pub fn with_client_verification(
  builder: Builder,
  ca_cert: ClientVerification,
) -> Builder {
  Builder(..builder, client_verification: Some(ca_cert))
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

/// Start the server, running the `on_start` function once it is listening.
///
/// The supervisor returned holds the acceptor pool. To put the server under a
/// supervision tree use `supervised` instead.
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
        to_internal_http1_options(builder.http1),
        to_internal_http2_options(builder.http2),
      ),
      loop: handler_.loop,
    )
    |> glisten.with_http2

  let pool = case builder.tls {
    Some(Disk(cert:, key:)) ->
      glisten.with_tls(pool, certfile: cert, keyfile: key)
    Some(Pem(cert:, key:)) -> glisten.with_tls_pem(pool, cert:, key:)
    Some(Der(cert:, key:, key_type:)) ->
      glisten.with_tls_der(
        pool,
        cert:,
        key_type: to_internal_tls_key_type(key_type),
        key:,
      )
    None -> pool
  }

  let pool = case builder.client_verification {
    Some(ca_cert) ->
      glisten.with_client_verification(
        pool,
        to_internal_client_verification(ca_cert),
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
    Some(_tls) -> http.Https
    None -> http.Http
  }
  let address =
    process.named_subject(builder.listener_name)
    |> get_server_info

  builder.on_start(scheme, address)

  started
}

/// Create a child specification for the server so that it can be added to a
/// supervision tree.
pub fn supervised(
  builder: Builder,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  fn() { start(builder) }
  |> supervision.supervisor
}

/// The reason a file could not be prepared by the `file` function.
pub type FileError {
  /// There is nothing at the given path.
  NotFound
  /// The path is a directory.
  IsDirectory
  /// The server is not permitted to read the file.
  AccessDenied
  /// The file could not be opened or measured for a reason ewe does not name.
  UnknownError
  /// The offset is negative or past the end of the file.
  InvalidOffset
  /// The limit is negative.
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

/// Create a response body from a file on the disc. Large files are safe to
/// send this way as they are never held in memory whole.
///
/// The offset and limit are in bytes and serve a range of the file. Leave
/// either as `None` to start at the beginning or to run to the end.
///
/// How the file reaches the client depends on the protocol. HTTP/1 lets the 
/// kernel copy it straight to the socket and falls back to reading it in 64kb 
/// pieces when TLS is in the way. HTTP/2 reads a file at or below the 
/// `file_read_threshold` of `Http2Options` into memory and frames it like any 
/// other body, and streams anything larger from the disc.
///
/// On HTTP/1 the file is opened here and stays open until the response has been
/// written so only create a body you go on to return. One that is created and
/// then thrown away holds its file open until it is garbage collected.
///
/// # Examples
///
/// ```gleam
/// let assert Ok(body) =
///   ewe.file(request.body, "/tmp/report.pdf", offset: None, limit: None)
///
/// response.new(200)
/// |> response.set_header("content-type", "application/pdf")
/// |> response.set_body(body)
/// ```
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

/// The reason a request body could not be read.
pub type BodyError {
  /// The body is larger than the limit that was given.
  BodyTooLarge
  /// The body could not be read to the end. The connection dropped, the read
  /// timed out or the chunked framing was malformed.
  InvalidBody
}

fn from_internal_http1_body_error(error: http1_body.BodyError) -> BodyError {
  case error {
    http1_body.BodyTooLarge -> BodyTooLarge
    http1_body.InvalidBody -> InvalidBody
  }
}

/// Read the entire request body into memory up to the given limit in bytes.
///
/// Any trailer fields a chunked request ends with are appended to the returned
/// request's headers.
///
/// Use `read_body_chunk` instead if the body may be too large to hold in memory.
///
/// # Examples
///
/// ```gleam
/// case ewe.read_body(request, limit: 1_048_576) {
///   Ok(request) -> handle(request.body)
///   Error(_body_error) -> response.new(400) |> response.set_body(ewe.Empty)
/// }
/// ```
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
    connection.Http2(connection) -> {
      use #(body, trailers) <- result.try(
        http2_body.read_body(connection, limit)
        |> result.map_error(from_internal_http2_body_error),
      )

      request.Request(..req, headers: list.append(req.headers, trailers), body:)
      |> Ok
    }
  }
}

fn from_internal_http2_body_error(error: http2_body.BodyError) -> BodyError {
  case error {
    http2_body.BodyTooLarge -> BodyTooLarge
    http2_body.InvalidBody -> InvalidBody
  }
}

/// The result of a single call to `read_body_chunk`.
pub type ReadEvent {
  /// A piece of the body along with the request to pass to the next call.
  Chunk(data: BitArray, request: request.Request(Connection))
  /// The body has been read to the end.
  ///
  /// Any trailer fields are appended to the request's headers and the request
  /// no longer carries a connection as there is nothing left to read from it.
  Done(request: request.Request(Nil))
}

/// Read the request body a chunk at a time rather than holding all of it in
/// memory taking up to `max_chunk_bytes` per call and refusing a body larger
/// than `limit` bytes in total.
///
/// Each `Chunk` carries the request to use for the next call. Keep going until
/// you get `Done`.
///
/// # Examples
///
/// ```gleam
/// fn count(request: request.Request(ewe.Connection), total: Int) -> Int {
///   case ewe.read_body_chunk(request, max_chunk_bytes: 4096, limit: 10_000_000) {
///     Ok(ewe.Chunk(data:, request:)) ->
///       count(request, total + bit_array.byte_size(data))
///     Ok(ewe.Done(_request)) -> total
///     Error(_body_error) -> total
///   }
/// }
/// ```
pub fn read_body_chunk(
  req: request.Request(Connection),
  max_chunk_bytes max_chunk_bytes: Int,
  limit limit: Int,
) -> Result(ReadEvent, BodyError) {
  let max_chunk_bytes = int.max(max_chunk_bytes, 1)

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
    connection.Http2(connection) -> {
      case http2_body.read_body_chunk(connection, max_chunk_bytes:, limit:) {
        Ok(http2_body.Chunk(data, connection)) -> {
          let body = connection.Http2(connection)
          Ok(Chunk(data, request.set_body(req, body)))
        }
        Ok(http2_body.Done(trailers)) -> {
          let headers = list.append(req.headers, trailers)
          Ok(Done(request.Request(..req, headers:, body: Nil)))
        }
        Error(error) -> Error(from_internal_http2_body_error(error))
      }
    }
  }
}

/// The reason a write to the client did not go through.
pub type SendError {
  /// The client is gone so nothing further can be written.
  ConnectionClosed
  /// The client cancelled this HTTP/2 stream while the rest of the connection
  /// carries on.
  StreamReset
  /// The client stopped reading for long enough that the write gave up which
  /// takes the connection with it.
  SendTimedOut
  /// The socket refused the write for a reason of its own.
  SocketError(reason: SocketReason)
}

/// What the socket said when it refused a write, carried by the `SocketError`
/// variant of `SendError`.
pub type SocketReason {
  /// The kernel has no socket buffer space or memory left to take the write.
  OutOfBuffers
  /// The node is at its file descriptor limit or the whole host is.
  TooManyOpenFiles
  /// The interface the connection runs over is down.
  NetworkDown
  /// There is no route to the client's network.
  NetworkUnreachable
  /// The client's network is reachable but the client's host is not.
  HostUnreachable
  /// The write is larger than the socket will send in one piece.
  MessageTooLarge
  /// The socket refused the write on permission grounds.
  PermissionDenied
  /// The write would have blocked and the socket is not willing to.
  WouldBlock
  /// A signal arrived mid write. Nothing was sent.
  Interrupted
  /// The socket does not support the write as it was made.
  NotSupported
  /// The write failed below the socket in the network stack or the device.
  IoError
  /// The socket reported something ewe does not classify.
  UnknownReason
}

/// Describe a `SendError` in a form that reads inside a log line.
///
/// # Examples
///
/// ```gleam
/// send_error_to_string(ConnectionClosed)
/// // -> "the client is gone"
/// ```
pub fn send_error_to_string(error: SendError) -> String {
  case error {
    ConnectionClosed -> "the client is gone"
    StreamReset -> "the client cancelled the stream"
    SendTimedOut -> "the client stopped reading and the write gave up"
    SocketError(reason:) ->
      "the socket refused the write, " <> socket_reason_to_string(reason)
  }
}

/// Describe a `SocketReason` in a form that reads inside a log line.
///
/// # Examples
///
/// ```gleam
/// socket_reason_to_string(NetworkDown)
/// // -> "the network is down"
/// ```
pub fn socket_reason_to_string(reason: SocketReason) -> String {
  case reason {
    OutOfBuffers -> "no socket buffer space or memory is left"
    TooManyOpenFiles -> "the file descriptor limit is reached"
    NetworkDown -> "the network is down"
    NetworkUnreachable -> "the client's network is unreachable"
    HostUnreachable -> "the client's host is unreachable"
    MessageTooLarge -> "the write is too large to send in one piece"
    PermissionDenied -> "permission was denied"
    WouldBlock -> "the write would have blocked"
    Interrupted -> "a signal arrived mid write"
    NotSupported -> "the socket does not support the write"
    IoError -> "the network stack or the device failed"
    UnknownReason -> "for a reason ewe does not classify"
  }
}

fn from_interrupted(interrupted: http2.Interrupted) -> SendError {
  case interrupted {
    http2.StreamReset -> StreamReset
    http2.ConnectionClosed | http2.TimedOut -> ConnectionClosed
  }
}

fn to_send_error(reason: socket.SocketReason) -> SendError {
  case reason {
    socket.Closed
    | socket.Econnaborted
    | socket.Econnreset
    | socket.Enotconn
    | socket.Epipe
    | socket.Etimedout
    | socket.Einval
    | socket.Ebadf
    | socket.Terminated -> ConnectionClosed
    socket.Timeout -> SendTimedOut
    socket.Enobufs | socket.Enomem -> SocketError(OutOfBuffers)
    socket.Emfile | socket.Enfile -> SocketError(TooManyOpenFiles)
    socket.Enetdown -> SocketError(NetworkDown)
    socket.Enetunreach -> SocketError(NetworkUnreachable)
    socket.Ehostunreach | socket.Ehostdown -> SocketError(HostUnreachable)
    socket.Emsgsize -> SocketError(MessageTooLarge)
    socket.Eacces | socket.Eperm -> SocketError(PermissionDenied)
    socket.Eagain | socket.Ewouldblock -> SocketError(WouldBlock)
    socket.Eintr -> SocketError(Interrupted)
    socket.Enotsup | socket.Eopnotsupp -> SocketError(NotSupported)
    socket.Eio -> SocketError(IoError)
    reason -> {
      logging.log(
        logging.Warning,
        "The socket refused a write: " <> socket.reason_to_string(reason),
      )

      SocketError(UnknownReason)
    }
  }
}

/// A handle for writing the body of a streamed response, given to the handler
/// by `stream_response`.
pub type ResponseWriter =
  connection.ResponseWriter

/// Set the body of a response to one written a chunk at a time so that each
/// chunk reaches the client as it is produced.
///
/// The handler is given a writer to send through and must finish the body with
/// `finish_chunk` or `finish_response`. A handler that returns without calling
/// either still has its body closed off but the connection is dropped instead
/// of being reused for the next request.
///
/// # Examples
///
/// ```gleam
/// response.new(200)
/// |> response.set_header("content-type", "text/plain")
/// |> ewe.stream_response(fn(writer) {
///   use writer <- result.try(ewe.send_chunk(writer, <<"Hello, ":utf8>>))
///   ewe.finish_chunk(writer, <<"Joe!":utf8>>)
/// })
/// ```
pub fn stream_response(
  response: response.Response(a),
  handler: fn(ResponseWriter) -> Result(Nil, SendError),
) -> response.Response(Body) {
  let stream = fn(writer) {
    let _sent = handler(writer)
    Nil
  }

  response.set_body(response, Streaming(connection.StreamingMetadata(stream)))
}

/// Send one chunk of a streamed response body. The writer is handed back so
/// that it can be threaded into the next call.
///
/// For the last chunk use `finish_chunk` instead, which closes the body off in
/// the same write.
pub fn send_chunk(
  writer: ResponseWriter,
  chunk: BitArray,
) -> Result(ResponseWriter, SendError) {
  case writer {
    connection.Http1Writer(writer) ->
      encoder.send_chunk(writer, chunk)
      |> result.map(connection.Http1Writer)
      |> result.map_error(to_send_error)
    connection.Http2Writer(writer) ->
      http2_stream.send_chunk(writer, chunk)
      |> result.map(connection.Http2Writer)
      |> result.map_error(from_interrupted)
  }
}

/// Send the last chunk of a streamed response body and close the body off.
pub fn finish_chunk(
  writer: ResponseWriter,
  chunk: BitArray,
) -> Result(Nil, SendError) {
  case writer {
    connection.Http1Writer(writer) ->
      encoder.finish_chunk(writer, chunk) |> result.map_error(to_send_error)
    connection.Http2Writer(writer) ->
      http2_stream.finish_chunk(writer, chunk)
      |> result.map_error(from_interrupted)
  }
}

/// Close off a streamed response body without sending any more data. Use
/// `finish_chunk` instead if there is one last chunk to send.
pub fn finish_response(writer: ResponseWriter) -> Result(Nil, SendError) {
  case writer {
    connection.Http1Writer(writer) ->
      encoder.finish_response(writer) |> result.map_error(to_send_error)
    connection.Http2Writer(writer) ->
      http2_stream.finish_response(writer) |> result.map_error(from_interrupted)
  }
}

/// A handle for sending on an open Server-Sent Events stream.
pub type SseConnection =
  connection.SseConnection

/// A message on a Server-Sent Events stream.
///
/// Create one with `event` or `comment`, then set the rest of its fields with
/// `event_name`, `event_id` and `event_retry`.
pub type SseEvent =
  sse.Event

/// What a Server-Sent Events stream does once the handler has dealt with a
/// message.
///
/// Create one with `sse_continue`, `sse_stop` or `sse_stop_abnormal`.
pub opaque type SseNext(user_state) {
  SseContinue(user_state)
  SseStop
  SseStopAbnormal(reason: String)
}

/// Carry on with the stream, handling further messages with the given state.
pub fn sse_continue(user_state: user_state) -> SseNext(user_state) {
  SseContinue(user_state)
}

/// End the stream.
pub fn sse_stop() -> SseNext(user_state) {
  SseStop
}

/// End the stream and exit the connection process abnormally with the given
/// reason.
pub fn sse_stop_abnormal(reason: String) -> SseNext(user_state) {
  SseStopAbnormal(reason)
}

/// Create an event carrying the given data.
///
/// Data spanning several lines is sent as the repeated `data:` fields that the
/// client joins back together.
///
/// # Examples
///
/// ```gleam
/// event("Hello, Joe!")
/// |> event_name("greeting")
/// |> event_id("1")
/// ```
pub fn event(data: String) -> SseEvent {
  sse.Event(..sse.new(), data: Some(data))
}

/// Create a comment, which clients ignore.
///
/// Sending one every so often is the usual way to keep an idle stream from
/// being closed by a proxy in between.
pub fn comment(text: String) -> SseEvent {
  sse.Event(..sse.new(), comment: Some(text))
}

/// Set the name of an event which clients use to route it to a listener.
pub fn event_name(event: SseEvent, name: String) -> SseEvent {
  sse.Event(..event, name: Some(name))
}

/// Set the ID of an event. A reconnecting client sends the last ID it saw back
/// in the `last-event-id` header.
pub fn event_id(event: SseEvent, id: String) -> SseEvent {
  sse.Event(..event, id: Some(id))
}

/// Set how long, in milliseconds, the client waits before reconnecting.
pub fn event_retry(event: SseEvent, retry: Int) -> SseEvent {
  sse.Event(..event, retry: Some(retry))
}

/// Send an event to the client of a Server-Sent Events stream.
pub fn send_event(
  conn: SseConnection,
  event: SseEvent,
) -> Result(Nil, SendError) {
  case conn {
    connection.Http1Sse(conn) ->
      http1_sse.send(conn, event) |> result.map_error(to_send_error)
    connection.Http2Sse(conn) ->
      http2_sse.send(conn, event) |> result.map_error(from_interrupted)
  }
}

/// Set the body of a response to a Server-Sent Events stream which runs until
/// the handler stops it or the client goes away.
///
/// - `on_init` is called once, with a subject that the rest of your program
///   sends messages to, and returns the starting state.
/// - `handler` is called for each message that arrives on that subject.
/// - `on_close` is called once, however the stream ended.
///
/// The `content-type` and `cache-control` headers the stream needs are set by
/// ewe.
///
/// On HTTP/1.1 the connection can carry another request afterwards as long as 
/// the handler ended the stream itself and the client sent nothing during it.
///
/// # Examples
///
/// ```gleam
/// response.new(200)
/// |> ewe.sse(
///   on_init: fn(subject) {
///     pubsub.subscribe(pubsub, subject)
///     0
///   },
///   handler: fn(conn, sent, message) {
///     case ewe.send_event(conn, ewe.event(message)) {
///       Ok(Nil) -> ewe.sse_continue(sent + 1)
///       Error(_send_error) -> ewe.sse_stop()
///     }
///   },
///   on_close: fn(_conn, _sent) { Nil },
/// )
/// ```
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
      connection.Http2Sse(conn) -> http2_sse.run(conn, on_init, step, on_close)
    }
  }

  response.set_body(response, Sse(connection.SseMetadata(stream)))
}

/// A handle for sending frames on an open WebSocket.
pub type WebsocketConnection =
  connection.WebsocketConnection

/// A message reaching a WebSocket handler either from the client or from the
/// rest of your program.
///
/// Ping and pong frames are answered by the server and never reach the handler.
pub type WebsocketMessage(user_message) {
  /// A text frame from the client with the valid UTF-8 payload.
  TextFrame(text: String)
  /// A binary frame from the client.
  BinaryFrame(data: BitArray)
  /// A message picked up by the selector given to `on_init`, sent by the rest
  /// of your program.
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

/// What a WebSocket does once the handler has dealt with a message.
///
/// Create one with `websocket_continue`, `websocket_continue_with_selector`,
/// `websocket_stop` or `websocket_stop_abnormal`.
pub opaque type WebsocketNext(user_state, user_message) {
  WebsocketContinue(user_state, Option(process.Selector(user_message)))
  WebsocketStop
  WebsocketStopAbnormal(reason: String)
}

/// Carry on with the WebSocket handling further messages with the given state
/// and the selector the connection already has.
pub fn websocket_continue(
  user_state: user_state,
) -> WebsocketNext(user_state, user_message) {
  WebsocketContinue(user_state, None)
}

/// Carry on with the WebSockets listening on the given selector from here on
/// instead of the one the connection was started with.
pub fn websocket_continue_with_selector(
  user_state: user_state,
  selector: process.Selector(user_message),
) -> WebsocketNext(user_state, user_message) {
  WebsocketContinue(user_state, Some(selector))
}

/// End the WebSocket. To tell the client why first, use `send_close_frame`.
pub fn websocket_stop() -> WebsocketNext(user_state, user_message) {
  WebsocketStop
}

/// End the WebSocket and exit the connection process abnormally with the given
/// reason.
pub fn websocket_stop_abnormal(
  reason: String,
) -> WebsocketNext(user_state, user_message) {
  WebsocketStopAbnormal(reason)
}

/// The reason a WebSocket is being closed, sent to the client in the close
/// frame.
pub type CloseReason {
  /// Close without saying why.
  NoCloseReason
  /// Close with a status code and a description, which may be empty.
  CloseReason(code: CloseCode, reason: String)
}

/// The status code a close frame carries.
///
/// The codes that exist only to be reported locally, such as 1005 and 1006,
/// are absent, as sending one is a protocol violation.
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
  /// A message did not match the type it declared such as a text frame that
  /// is not UTF-8 (1007).
  InvalidPayloadData
  /// The other end broke your rules when no more specific code applies (1008).
  PolicyViolation
  /// A message was larger than this endpoint will handle (1009).
  MessageTooBig
  /// An extension the client required was not negotiated (1010).
  MandatoryExtension
  /// Something went wrong on this side (1011).
  InternalError
  /// The server is restarting and clients may reconnect shortly (1012).
  ServiceRestart
  /// The server is overloaded and the client should retry later (1013).
  TryAgainLater
  /// An upstream server answered badly (1014).
  BadGateway
  /// An application specific code which must be between 3000 and 4999.
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

/// Send a text frame to the client.
pub fn send_text_frame(
  conn: WebsocketConnection,
  text: String,
) -> Result(Nil, SendError) {
  case conn {
    connection.Http1Websocket(conn) ->
      http1_websocket.send_text(conn, text) |> result.map_error(to_send_error)
  }
}

/// Send a binary frame to the client.
pub fn send_binary_frame(
  conn: WebsocketConnection,
  data: BitArray,
) -> Result(Nil, SendError) {
  case conn {
    connection.Http1Websocket(conn) ->
      http1_websocket.send_binary(conn, data) |> result.map_error(to_send_error)
  }
}

/// Start the closing handshake and end the WebSocket.
///
/// Return the value this gives back from your handler. No frame can be sent
/// after it.
///
/// # Examples
///
/// ```gleam
/// ewe.send_close_frame(conn, ewe.CloseReason(ewe.GoingAway, "shutting down"))
/// ```
pub fn send_close_frame(
  conn: WebsocketConnection,
  reason: CloseReason,
) -> WebsocketNext(user_state, user_message) {
  let _sent = case conn {
    connection.Http1Websocket(conn) ->
      http1_websocket.send_close(conn, to_internal_close_reason(reason))
  }

  WebsocketStop
}

/// Upgrade the request to a WebSocket which runs until the handler stops it or
/// the client goes away.
///
/// - `on_init` is called once, with an empty selector to add whatever the rest
///   of your program sends this connection to, and returns the starting state
///   along with that selector.
/// - `handler` is called for each frame from the client and each message the
///   selector picks up.
/// - `on_close` is called once, however the WebSocket ended.
///
/// A request that is not a valid handshake is answered with status code 400:
/// Bad Request, and the handler is never run. WebSockets travel over extended
/// CONNECT on HTTP/2, which ewe does not negotiate yet, so a request on an
/// HTTP/2 connection is answered with status code 501: Not Implemented.
///
/// The connection stops being HTTP once the handshake has been sent so it will
/// never carry another request.
///
/// # Examples
///
/// ```gleam
/// ewe.websocket(
///   request:,
///   on_init: fn(_conn, selector) { #(0, selector) },
///   handler: fn(conn, count, message) {
///     case message {
///       ewe.TextFrame(text) -> {
///         let assert Ok(Nil) = ewe.send_text_frame(conn, text)
///         ewe.websocket_continue(count + 1)
///       }
///       ewe.BinaryFrame(_data) | ewe.UserMessage(_message) ->
///         ewe.websocket_continue(count)
///     }
///   },
///   on_close: fn(_conn, _count) { Nil },
/// )
/// ```
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
    // WebSockets ride on extended CONNECT over HTTP/2 which ewe does not
    // negotiate yet!
    connection.Http2(_connection) -> {
      logging.log(
        logging.Debug,
        "Rejected a WebSocket handshake! HTTP/2 connections do not carry WebSockets",
      )

      response.set_body(response.new(501), Empty)
    }
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
