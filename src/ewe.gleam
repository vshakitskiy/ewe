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
////       "enable_ipv6",
////       "enable_tls",
////       "with_name",
////       "quiet",
////       "idle_timeout",
////       "on_start",
////       "on_crash"
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
////       "stream_body"
////     ]
////   },
////   {
////     header: "Response",
////     functions: ["file"]
////   },
////   {
////     header: "Chunked Response",
////     functions: [
////       "chunked_body",
////       "send_chunk",
////       "chunked_continue",
////       "chunked_stop",
////       "chunked_stop_abnormal"
////     ]
////   },
////   {
////     header: "Websocket",
////     functions: [
////       "upgrade_websocket",
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
////       sortedList.append(sidebar)
////       sortedMembers.append(member)
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

import ewe/internal/file
import ewe/internal/handler
import ewe/internal/http as http_
import ewe/internal/stream/chunked
import ewe/internal/stream/sse
import ewe/internal/stream/websocket
import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http
import gleam/http/request.{type Request as HttpRequest}
import gleam/http/response.{type Response as HttpResponse}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor.{type Supervisor} as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string_tree.{type StringTree}
import glisten
import glisten/internal/listener
import glisten/socket/options as glisten_options
import glisten/transport
import logging
import websocks

// CONNECTION
// -----------------------------------------------------------------------------

/// Represents the request body and connection metadata. Access the body using
/// `ewe.read_body`, or retrieve client information with `ewe.get_client_info`.
pub type Connection =
  http_.Connection

// IP ADDRESS
// -----------------------------------------------------------------------------

/// Represents an IP address. Can be either IPv4 or IPv6.
pub type IpAddress {
  IpV4(Int, Int, Int, Int)
  IpV6(Int, Int, Int, Int, Int, Int, Int, Int)
}

/// Converts an `IpAddress` to its string representation.
pub fn ip_address_to_string(address address: IpAddress) -> String {
  ewe_to_glisten_ip(address)
  |> glisten.ip_address_to_string
}

fn glisten_to_ewe_ip(ip: glisten.IpAddress) -> IpAddress {
  case ip {
    glisten.IpV4(n1, n2, n3, n4) -> IpV4(n1, n2, n3, n4)
    glisten.IpV6(n1, n2, n3, n4, n5, n6, n7, n8) ->
      IpV6(n1, n2, n3, n4, n5, n6, n7, n8)
  }
}

fn glisten_options_to_ewe_ip(ip: glisten_options.IpAddress) -> IpAddress {
  case ip {
    glisten_options.IpV4(n1, n2, n3, n4) -> IpV4(n1, n2, n3, n4)
    glisten_options.IpV6(n1, n2, n3, n4, n5, n6, n7, n8) ->
      IpV6(n1, n2, n3, n4, n5, n6, n7, n8)
  }
}

fn ewe_to_glisten_ip(ip: IpAddress) -> glisten.IpAddress {
  case ip {
    IpV4(n1, n2, n3, n4) -> glisten.IpV4(n1, n2, n3, n4)
    IpV6(n1, n2, n3, n4, n5, n6, n7, n8) ->
      glisten.IpV6(n1, n2, n3, n4, n5, n6, n7, n8)
  }
}

// INFORMATION
// -----------------------------------------------------------------------------

/// Represents a socket address with IP and port. Use `ewe.get_lcient_info` to
/// get the client's address from a connection, or `ewe.get_server_info` to get
/// the server's bound address.
pub type SocketAddress {
  SocketAddress(ip: IpAddress, port: Int)
}

/// Retrieves the client's socket address from the connection. Returns error if
/// the socket information is unavailable.
pub fn get_client_info(
  connection connection: Connection,
) -> Result(SocketAddress, Nil) {
  transport.peername(connection.transport, connection.socket)
  |> result.map(fn(server_info) {
    SocketAddress(glisten_options_to_ewe_ip(server_info.0), server_info.1)
  })
}

/// Gets the server's bound address and port. Requires the server to be running
/// and the listener name to match the one set in `ewe.with_name`.
pub fn get_server_info(
  listener_name name: process.Name(listener.Message),
) -> SocketAddress {
  let server_info = glisten.get_server_info(name, 10_000)
  let ip_address = glisten_to_ewe_ip(server_info.ip_address)

  SocketAddress(ip: ip_address, port: server_info.port)
}

// RESPONSE
// -----------------------------------------------------------------------------

/// Represents possible response body options.
///
/// Types for direct usage:
/// - Regular data: `TextData`, `BytesData`, `BitsData`, `StringTreeData`,
/// `Empty`.
///
/// Types that should never be used directly:
/// - `File`: see `ewe.file` to construct it.
/// - `Chunked`: indicates that response body is being sent in chunks with
/// `chunked` transfer encoding.
/// - `Websocket`: indicates that request is being upgraded to a WebSocket
/// connection.
/// - `SSE`: indicates that request is being upgraded to a Server-Sent Events
/// connection.
pub type ResponseBody {
  /// Allows to set response body from a string.
  TextData(String)
  /// Allows to set response body from bytes.
  BytesData(BytesTree)
  /// Allows to set response body from bits.
  BitsData(BitArray)
  /// Allows to set response body from a string tree.
  StringTreeData(StringTree)
  /// Allows to set empty response body.
  Empty

  /// Allows to set response body from a file more efficiently rather than
  /// sending contents in regular data types.
  File(descriptor: file.IoDevice, offset: Int, size: Int)

  /// Indicates that response body is being sent in chunks with `chunked`
  /// transfer encoding.
  Chunked
  /// Indicates that request is being upgraded to a WebSocket connection.
  Websocket
  /// Indicates that request is being upgraded to a Server-Sent Events
  /// connection.
  SSE
}

/// A convenient alias for a HTTP response with a `ResponseBody` as the body.
///
pub type Response =
  HttpResponse(ResponseBody)

fn transform_response_body(resp: Response) -> HttpResponse(http_.ResponseBody) {
  response.set_body(resp, case resp.body {
    TextData(text) -> http_.TextData(text)
    BytesData(bytes) -> http_.BytesData(bytes)
    BitsData(bits) -> http_.BitsData(bits)
    StringTreeData(string_tree) -> http_.StringTreeData(string_tree)

    Chunked -> http_.Chunked
    File(descriptor, offset, size) -> http_.File(descriptor, offset, size)

    Websocket -> http_.Websocket
    SSE -> http_.SSE

    Empty -> http_.Empty
  })
}

/// Error type returned by `ewe.file` when opening a file for the response body.
pub type FileError {
  /// File does not exist.
  NoEntry
  /// Missing permission for reading the file, or for searching one of the
  /// parents directories.
  NoAccess
  /// The named file is a directory.
  IsDirectory
  /// Untypical file error.
  UnknownFileError(dynamic.Dynamic)
}

fn internal_to_file_error(error: file.FileError) -> FileError {
  case error {
    file.Enoent -> NoEntry
    file.Eacces -> NoAccess
    file.Eisdir -> IsDirectory
    file.Eunknown(error) -> UnknownFileError(error)
  }
}

/// Creates a file response body. Use `offset` to skip bytes from the start, and
/// `limit` to send only a portion of the file.
pub fn file(
  path: String,
  offset offset: Option(Int),
  limit limit: Option(Int),
) -> Result(ResponseBody, FileError) {
  // TODO: handle invalid offset + limit?
  case file.open(path) {
    Ok(file) ->
      Ok(File(
        file.descriptor,
        offset: option.unwrap(offset, 0),
        size: option.unwrap(limit, file.size),
      ))
    Error(error) -> Error(internal_to_file_error(error))
  }
}

// BUILDER
// -----------------------------------------------------------------------------

/// Contains all server configurations, can be adjusted by different builder
/// functions.
pub opaque type Builder {
  Builder(
    handler: fn(Request) -> Response,
    port: Int,
    interface: String,
    ipv6: Bool,
    tls: Option(#(String, String)),
    on_start: fn(http.Scheme, SocketAddress) -> Nil,
    on_crash: Response,
    listener_name: process.Name(listener.Message),
    idle_timeout: Int,
  )
}

/// Creates new server builder with handler provided.
pub fn new(handler: fn(Request) -> Response) -> Builder {
  Builder(
    handler:,
    port: 8080,
    interface: "127.0.0.1",
    ipv6: False,
    tls: None,
    on_start: fn(scheme, server) {
      let address = case server.ip {
        IpV6(..) -> "[" <> ip_address_to_string(server.ip) <> "]"
        IpV4(..) -> ip_address_to_string(server.ip)
      }

      let url =
        http.scheme_to_string(scheme)
        <> "://"
        <> address
        <> ":"
        <> int.to_string(server.port)

      logging.log(logging.Info, "Listening on " <> url)
    },
    on_crash: response.new(500) |> response.set_body(Empty),
    listener_name: process.new_name("glisten_listener"),
    idle_timeout: 10_000,
  )
}

/// Binds server to a specific network interface (e.g., "0.0.0.0" for all IPv4
/// interfaces or "127.0.0.1" for localhost). To bind to IPv6 addresses like
/// "::" or "::1", you must use `ewe.enable_ipv6`. Crashes the program if the
/// interface is invalid.
pub fn bind(builder: Builder, interface interface: String) -> Builder {
  Builder(..builder, interface:)
}

/// Sets the listening port for server.
pub fn listening(builder: Builder, port port: Int) -> Builder {
  Builder(..builder, port:)
}

/// Sets the listening port to 0, which causes the OS to assign a random
/// available port.
pub fn listening_random(builder: Builder) -> Builder {
  Builder(..builder, port: 0)
}

/// Enables IPv6 support, allowing the server to accept connections over IPv6
/// addresses. Must be called for binding to IPv6 addresses via `ewe.bind`.
pub fn enable_ipv6(builder: Builder) -> Builder {
  Builder(..builder, ipv6: True)
}

/// Enables TLS (HTTPS) support, with provided certificate and key files. 
/// Crashes the program if the files don't exist or are invalid.
pub fn enable_tls(
  builder: Builder,
  certificate_file certificate_file: String,
  key_file key_file: String,
) -> Builder {
  Builder(..builder, tls: Some(#(certificate_file, key_file)))
}

/// Sets a custom listener process name. This name is required when calling
/// `ewe.get_server_info` to retrieve the server's bound address and port.
pub fn with_name(
  builder: Builder,
  name: process.Name(listener.Message),
) -> Builder {
  Builder(..builder, listener_name: name)
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
  Builder(..builder, on_start: fn(_, _) { Nil })
}

/// Sets a custom response that will be sent when server crashes.
pub fn on_crash(builder: Builder, on_crash: Response) -> Builder {
  Builder(..builder, on_crash:)
}

/// Sets the idle timeout in milliseconds. Connections are closed after this
/// period of inactivity. Defaults to 10_000ms if the value is negative.
pub fn idle_timeout(builder: Builder, idle_timeout: Int) -> Builder {
  case idle_timeout {
    idle_timeout if idle_timeout >= 0 -> Builder(..builder, idle_timeout:)
    _ -> Builder(..builder, idle_timeout: 10_000)
  }
}

// SERVER
// -----------------------------------------------------------------------------

/// Starts the server with the provided configuration.
pub fn start(
  builder: Builder,
) -> Result(actor.Started(Supervisor), actor.StartError) {
  let handler = fn(req) { transform_response_body(builder.handler(req)) }
  let on_crash = transform_response_body(builder.on_crash)

  let factory_name = process.new_name("ewe_factory")
  let factory =
    factory.worker_child(fn(start) { start() })
    |> factory.restart_strategy(supervision.Temporary)
    |> factory.named(factory_name)
    |> factory.supervised()

  let glisten_supervisor =
    glisten.new(
      handler.init,
      handler.loop(handler, on_crash, factory_name, builder.idle_timeout),
    )
    |> glisten.bind(builder.interface)
    |> fn(glisten_builder) {
      case builder.ipv6 {
        True -> glisten.with_ipv6(glisten_builder)
        False -> glisten_builder
      }
    }
    |> fn(glisten_builder) {
      case builder.tls {
        Some(#(cert, key)) ->
          glisten.with_tls(glisten_builder, cert, key)
          // Uncomment once http2 will be implemented!
          |> glisten.with_http2
        None -> glisten_builder
      }
    }
    // https://github.com/rawhat/glisten/blob/master/src/glisten.gleam#L359
    |> glisten.start_with_listener_name(builder.port, builder.listener_name)
    |> result.map(fn(started) {
      let scheme = case builder.tls {
        Some(#(_, _)) -> http.Https
        None -> http.Http
      }

      let server_info = glisten.get_server_info(builder.listener_name, 10_000)
      let ip_address = glisten_to_ewe_ip(server_info.ip_address)

      let server = SocketAddress(ip: ip_address, port: server_info.port)

      builder.on_start(scheme, server)

      started
    })
  let glisten_child = supervision.supervisor(fn() { glisten_supervisor })

  supervisor.new(supervisor.OneForAll)
  |> supervisor.add(glisten_child)
  |> supervisor.add(factory)
  |> supervisor.start()
}

/// Returns a child specification for use in a supervision tree.
pub fn supervised(
  builder: Builder,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  supervision.supervisor(fn() { start(builder) })
}

// REQUEST
// -----------------------------------------------------------------------------

/// Possible errors that can occur when reading a body.
pub type BodyError {
  /// Body is larger than the provided limit.
  BodyTooLarge
  /// Body is malformed.
  InvalidBody
}

/// A convenient alias for a HTTP request with a `Connection` as the body.
pub type Request =
  HttpRequest(Connection)

/// Reads body from the request. Returns `BodyTooLarge` if body exceeds 
/// `bytes_limit`, or `InvalidBody` if malformed. Supports both chunked and 
/// content-length bodies.
pub fn read_body(
  req: Request,
  bytes_limit bytes_limit: Int,
) -> Result(HttpRequest(BitArray), BodyError) {
  case http_.read_body(req, bytes_limit) {
    Ok(req) -> Ok(req)
    Error(http_.BodyTooLarge) -> Error(BodyTooLarge)
    Error(_) -> Error(InvalidBody)
  }
}

/// A convenient alias for a consumer that reads `N` amount of bytes from the
/// request body stream.
pub type Consumer =
  fn(Int) -> Result(Stream, BodyError)

/// The progress of reading the request body stream.
pub type Stream {
  /// Chunk of data has been consumed.
  Consumed(data: BitArray, next: Consumer)
  /// Signifies that the request body stream has been fully consumed.
  Done
}

/// Returns a consumer for streaming the request body in chunks.
pub fn stream_body(req: Request) -> Result(Consumer, BodyError) {
  case http_.stream_body(req) {
    Ok(consumer) -> Ok(consumer_adapter(consumer))
    Error(_) -> Error(InvalidBody)
  }
}

fn consumer_adapter(
  internal_consumer: fn(Int) -> Result(http_.Stream, http_.ParseError),
) -> Consumer {
  fn(size) {
    case internal_consumer(size) {
      Ok(http_.Done) -> Ok(Done)
      Ok(http_.Consumed(data, next)) -> {
        Ok(Consumed(data, consumer_adapter(next)))
      }
      Error(_) -> Error(InvalidBody)
    }
  }
}

// CHUNKED RESPONSE
// -----------------------------------------------------------------------------

/// Represents a chunked response body. This type is used to send a chunked
/// response to the client.
pub type ChunkedBody =
  chunked.ChunkedBody

/// Represents an instruction on how chunked response should be processed.
///
/// - continue processing the chunked response.
/// - stop the chunked response normally.
/// - stop the chunked response with abnormal reason.
pub opaque type ChunkedNext(user_state) {
  ChunkedContinue(user_state)
  ChunkedStop
  ChunkedAbnormalStop(reason: String)
}

/// Instructs chunked response to continue processing.
pub fn chunked_continue(user_state: user_state) -> ChunkedNext(user_state) {
  ChunkedContinue(user_state)
}

/// Instructs chunked response to stop normally.
pub fn chunked_stop() -> ChunkedNext(user_state) {
  ChunkedStop
}

/// Instructs chunked response to stop with abnormal reason.
pub fn chunked_stop_abnormal(reason: String) -> ChunkedNext(user_state) {
  ChunkedAbnormalStop(reason)
}

fn to_internal_chunked_next(
  next: ChunkedNext(user_state),
) -> chunked.ChunkedNext(user_state) {
  case next {
    ChunkedContinue(user_state) -> chunked.Continue(user_state)
    ChunkedStop -> chunked.NormalStop
    ChunkedAbnormalStop(reason) -> chunked.AbnormalStop(reason)
  }
}

/// Sets up the connection for chunked response.
///
/// `on_init` function is called once the chunked response process is
/// initialized. The argument is subject that can be used to send chunks to the
/// client. It must return initial state.
///
/// `handler` function is called for every message received. It must return
/// instruction on how chunked response should proceed.
///
/// `on_close` function is called when the chunked response process is going to be stopped.
pub fn chunked_body(
  req: Request,
  resp: HttpResponse(a),
  on_init on_init: fn(Subject(user_message)) -> user_state,
  handler handler: fn(ChunkedBody, user_state, user_message) ->
    ChunkedNext(user_state),
  on_close on_close: fn(ChunkedBody, user_state) -> Nil,
) -> Response {
  let handler = fn(conn, state, msg) {
    handler(conn, state, msg)
    |> to_internal_chunked_next()
  }

  let transport = req.body.transport
  let socket = req.body.socket
  let factory_name = req.body.factory_name

  case chunked.send_response(resp, transport, socket) {
    Ok(Nil) -> {
      let supervisor = factory.get_by_name(factory_name)

      let start_result =
        factory.start_child(supervisor, fn() {
          chunked.start(transport, socket, on_init, handler, on_close)
        })

      case start_result {
        Ok(started) -> {
          let _ = transport.controlling_process(transport, socket, started.pid)
          response.new(200) |> response.set_body(Chunked)
        }
        Error(_) -> response.new(400) |> response.set_body(Empty)
      }
    }
    Error(Nil) -> response.new(400) |> response.set_body(Empty)
  }
}

/// Sends a chunk to the client.
pub fn send_chunk(
  body: ChunkedBody,
  chunk: BitArray,
) -> Result(Nil, glisten.SocketReason) {
  chunked.send_chunk(body.transport, body.socket, chunk)
}

// WEBSOCKET
// -----------------------------------------------------------------------------

/// Represents a WebSocket connection between a client and a server.
pub type WebsocketConnection =
  websocket.WebsocketConnection

/// Represents an instruction on how WebSocket connection should proceed.
///
/// - continue processing the WebSocket connection.
/// - continue processing the WebSocket connection with selector for custom
///   messages.
/// - stop the WebSocket connection.
/// - stop the WebSocket connection with abnormal reason.
pub opaque type WebsocketNext(user_state, user_message) {
  WebsocketContinue(user_state, Option(Selector(user_message)))
  WebsocketNormalStop
  WebsocketAbnormalStop(reason: String)
}

/// Instructs WebSocket connection to continue processing.
pub fn websocket_continue(
  user_state: user_state,
) -> WebsocketNext(user_state, user_message) {
  WebsocketContinue(user_state, None)
}

/// Instructs WebSocket connection to continue processing, including selector
/// for custom messages.
pub fn websocket_continue_with_selector(
  user_state: user_state,
  selector: Selector(user_message),
) -> WebsocketNext(user_state, user_message) {
  WebsocketContinue(user_state, Some(selector))
}

/// Instructs WebSocket connection to stop.
pub fn websocket_stop() -> WebsocketNext(user_state, user_message) {
  WebsocketNormalStop
}

/// Instructs WebSocket connection to stop with abnormal reason.
pub fn websocket_stop_abnormal(
  reason: String,
) -> WebsocketNext(user_state, user_message) {
  WebsocketAbnormalStop(reason)
}

fn to_websocket_next(
  next: websocket.WebsocketNext(user_state, user_message),
) -> WebsocketNext(user_state, user_message) {
  case next {
    websocket.Continue(user_state, selector) ->
      WebsocketContinue(user_state, selector)
    websocket.NormalStop -> WebsocketNormalStop
    websocket.AbnormalStop(reason) -> WebsocketAbnormalStop(reason)
  }
}

fn to_internal_websocket_next(
  next: WebsocketNext(user_state, user_message),
) -> websocket.WebsocketNext(user_state, user_message) {
  case next {
    WebsocketContinue(user_state, selector) ->
      websocket.Continue(user_state, selector)
    WebsocketNormalStop -> websocket.NormalStop
    WebsocketAbnormalStop(reason) -> websocket.AbnormalStop(reason)
  }
}

/// Represents a WebSocket message received from the client.
pub type WebsocketMessage(user_message) {
  /// Indicate that text frame has been received.
  Text(String)
  /// Indicate that binary frame has been received.
  Binary(BitArray)
  /// Indicate that user message has been received from WebSocket selector.
  User(user_message)
}

fn transform_websocket_message(
  message: websocket.WebsocketMessage(user_message),
) -> Result(WebsocketMessage(user_message), Nil) {
  case message {
    websocket.Frame(websocks.Text(payload)) ->
      bit_array.to_string(payload) |> result.map(Text)
    websocket.Frame(websocks.Binary(payload)) -> Ok(Binary(payload))
    websocket.UserMessage(user_message) -> Ok(User(user_message))
    _ -> Error(Nil)
  }
}

/// Upgrade request to a WebSocket connection. If the initial request is not
/// valid for WebSocket upgrade, 400 response is sent.
///
/// `on_init` function is called once process that handles WebSocket connection
/// is initialized. It must return a tuple with initial state and selector for
/// custom messages. If there is no custom messages, user can pass the same
/// selector from the argument
///
/// `handler` function is called for every WebSocket message received. It must
/// return instruction on how WebSocket connection should proceed.
///
/// `on_close` function is called when WebSocket process is going to be stopped.
pub fn upgrade_websocket(
  req: Request,
  on_init on_init: fn(WebsocketConnection, Selector(user_message)) ->
    #(user_state, Selector(user_message)),
  handler handler: fn(
    WebsocketConnection,
    user_state,
    WebsocketMessage(user_message),
  ) ->
    WebsocketNext(user_state, user_message),
  on_close on_close: fn(WebsocketConnection, user_state) -> Nil,
) -> Response {
  let handler = fn(conn, state, msg) {
    transform_websocket_message(msg)
    |> result.map(handler(conn, state, _))
    |> result.unwrap(websocket_continue(state))
    |> to_internal_websocket_next()
  }

  let transport = req.body.transport
  let socket = req.body.socket
  let factory_name = req.body.factory_name

  case http_.upgrade_websocket(req, transport, socket) {
    Ok(#(extensions, per_message_deflate)) -> {
      let supervisor = factory.get_by_name(factory_name)
      let start_result =
        factory.start_child(supervisor, fn() {
          websocket.start(
            transport,
            socket,
            on_init,
            handler,
            on_close,
            extensions,
            per_message_deflate,
          )
        })

      case start_result {
        Ok(started) -> {
          let _ = transport.controlling_process(transport, socket, started.pid)

          response.new(200) |> response.set_body(Websocket)
        }
        Error(_) -> response.new(500) |> response.set_body(Empty)
      }
    }
    Error(_) -> response.new(400) |> response.set_body(Empty)
  }
}

/// Sends a binary frame to the websocket client.
pub fn send_binary_frame(
  conn: WebsocketConnection,
  bits: BitArray,
) -> Result(Nil, glisten.SocketReason) {
  websocket.send_frame(
    websocks.encode_binary_frame,
    conn.transport,
    conn.socket,
    conn.context,
    bits,
  )
}

/// Sends a text frame to the websocket client.
pub fn send_text_frame(
  conn: WebsocketConnection,
  text: String,
) -> Result(Nil, glisten.SocketReason) {
  websocket.send_frame(
    websocks.encode_text_frame,
    conn.transport,
    conn.socket,
    conn.context,
    bit_array.from_string(text),
  )
}

/// WebSocket close codes that can be sent when closing a connection. The `data`
/// parameter allows you to include payload up to 123 bytes in size.
pub type CloseCode {
  /// Standard graceful shutdown (1000). Use when connection completed
  /// successfully.
  NormalClosure(data: String)
  /// Invalid message format (1007). Received payload that doesn't match what
  /// you expected.
  InvalidPayloadData(data: String)
  /// Application policy violation (1008).Client broke your rules - failed
  /// authentication, hit rate limits, or violated business logic.
  PolicyViolation(data: String)
  /// Message exceeds size limits (1009). Client sent something bigger than
  /// your application allows.
  MessageTooBig(data: String)
  /// Server encountered unexpected error (1011). Something went wrong on your
  /// side that prevents handling the connection.
  InternalError(data: String)
  /// Server is restarting (1012). Planned restart - clients can reconnect
  /// after a bit.
  ServiceRestart(data: String)
  /// Temporary server overload (1013). Use when server is temporarily
  /// unavailable, client should retry.
  TryAgainLater(data: String)
  /// Gateway/proxy received invalid response (1014). You're acting as a proxy
  /// and the upstream server gave you garbage.
  BadGateway(data: String)
  /// Custom close codes 3000-4999 for application-specific use.
  CustomCloseCode(code: Int, data: String)
  /// Close without a specific reason.
  NoCloseReason
}

fn to_internal_close_code(code: CloseCode) -> websocks.CloseReason {
  case code {
    NormalClosure(data) -> websocks.NormalClosure(bit_array.from_string(data))
    InvalidPayloadData(data) ->
      websocks.InvalidPayloadData(bit_array.from_string(data))
    PolicyViolation(data) ->
      websocks.PolicyViolation(bit_array.from_string(data))
    MessageTooBig(data) -> websocks.MessageTooBig(bit_array.from_string(data))
    InternalError(data) -> websocks.InternalError(bit_array.from_string(data))
    ServiceRestart(data) -> websocks.ServiceRestart(bit_array.from_string(data))
    TryAgainLater(data) -> websocks.TryAgainLater(bit_array.from_string(data))
    BadGateway(data) -> websocks.BadGateway(bit_array.from_string(data))
    CustomCloseCode(code, data) ->
      websocks.CustomCloseCode(code, bit_array.from_string(data))
    NoCloseReason -> websocks.NoCloseReason
  }
}

/// Sends a close frame to the websocket client. Once this function is called,
/// no other frames can be sent on this connection. Returns how the WebSocket
/// connection should proceed - make sure your handler returns this value.
pub fn send_close_frame(
  conn: WebsocketConnection,
  code: CloseCode,
) -> WebsocketNext(user_state, user_message) {
  to_internal_close_code(code)
  |> websocket.send_close_frame(conn.transport, conn.socket, _)
  |> to_websocket_next()
}

// SERVER-SENT EVENT
// -----------------------------------------------------------------------------

/// Represents a Server-Sent Events connection between a client and a server.
pub type SSEConnection =
  sse.SSEConnection

/// Represents an instruction on how Server-Sent Events connection should
/// proceed.
///
/// - continue processing the Server-Sent Events connection.
/// - stop the Server-Sent Events connection.
/// - stop the Server-Sent Events connection with abnormal reason.
pub opaque type SSENext(user_state) {
  SSEContinue(user_state)
  SSENormalStop
  SSEAbnormalStop(reason: String)
}

/// Instructs Server-Sent Events connection to continue processing.
pub fn sse_continue(user_state: user_state) -> SSENext(user_state) {
  SSEContinue(user_state)
}

/// Instructs Server-Sent Events connection to stop.
pub fn sse_stop() -> SSENext(user_state) {
  SSENormalStop
}

/// Instructs Server-Sent Events connection to stop with abnormal reason.
pub fn sse_stop_abnormal(reason: String) -> SSENext(user_state) {
  SSEAbnormalStop(reason)
}

fn to_internal_sse_next(next: SSENext(user_state)) -> sse.SSENext(user_state) {
  case next {
    SSEContinue(user_state) -> sse.Continue(user_state)
    SSENormalStop -> sse.NormalStop
    SSEAbnormalStop(reason) -> sse.AbnormalStop(reason)
  }
}

/// Represents a Server-Sent Events event. The event fields are:
/// - `event`: a string identifying the type of event described.
/// - `data`: the data field for the message.
/// - `id`: event ID.
/// - `retry`: The reconnection time. If the connection to the server is lost,
/// the browser will wait for the specified time before attempting to reconnect.
///
/// Can be created using `ewe.event` and modified with `ewe.event_name`,
/// `ewe.event_id`, and `ewe.event_retry`.
pub type SSEEvent =
  sse.SSEEvent

/// Creates a new SSE event with the given data. Use `ewe.event_name`,
/// `ewe.event_id`, and `ewe.event_retry` to modify other fields of the event.
pub fn event(data: String) -> SSEEvent {
  sse.SSEEvent(event: None, data:, id: None, retry: None)
}

/// Sets the name of the event.
pub fn event_name(event: SSEEvent, name: String) -> SSEEvent {
  sse.SSEEvent(..event, event: Some(name))
}

/// Sets the ID of the event.
pub fn event_id(event: SSEEvent, id: String) -> SSEEvent {
  sse.SSEEvent(..event, id: Some(id))
}

/// Sets the retry time of the event.
pub fn event_retry(event: SSEEvent, retry: Int) -> SSEEvent {
  sse.SSEEvent(..event, retry: Some(retry))
}

/// Sets up the connection for Server-Sent Events.
///
/// `on_init` function is called once process that handles SSE connection
/// is initialized. The argument is subject that can be used to send messages
/// to the client. It must return initial state.
///
/// `handler` function is called for every subject's message received. It must
/// return instruction on how SSE connection should proceed.
///
/// `on_close` function is called when SSE process is going to be stopped.
pub fn sse(
  req: Request,
  on_init on_init: fn(Subject(user_message)) -> user_state,
  handler handler: fn(SSEConnection, user_state, user_message) ->
    SSENext(user_state),
  on_close on_close: fn(SSEConnection, user_state) -> Nil,
) {
  let handler = fn(conn, state, msg) {
    handler(conn, state, msg)
    |> to_internal_sse_next()
  }

  let transport = req.body.transport
  let socket = req.body.socket
  let factory_name = req.body.factory_name

  case sse.send_response(transport, socket) {
    Ok(Nil) -> {
      let supervisor = factory.get_by_name(factory_name)
      let start_result =
        factory.start_child(supervisor, fn() {
          sse.start(transport, socket, on_init, handler, on_close)
        })

      case start_result {
        Ok(started) -> {
          let _ = transport.controlling_process(transport, socket, started.pid)
          response.new(200) |> response.set_body(SSE)
        }
        Error(_) -> response.new(400) |> response.set_body(Empty)
      }
    }
    Error(Nil) -> response.new(400) |> response.set_body(Empty)
  }
}

/// Sends a Server-Sent Events event to the client.
pub fn send_event(
  conn: SSEConnection,
  event: SSEEvent,
) -> Result(Nil, glisten.SocketReason) {
  sse.send_event(conn.transport, conn.socket, event)
}
