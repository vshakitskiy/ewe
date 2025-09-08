//// <style>
////   .content > h4,
////   .content > ul {
////     display: none;
////   }
//// </style>
//// <script>
//// // https://gitlab.com/arkandos/smol/-/blob/main/src/smol.gleam?ref_type=heads
//// (callback => document.readyState !== 'loading' ? callback() : document.addEventListener('DOMContentLoaded', callback, { once: true }))(() => {
////   const list = document.querySelector('.sidebar > ul:last-of-type')
////   const sortedLists = document.createDocumentFragment()
////   const sortedMembers = document.createDocumentFragment()
////
////   for (const header of document.querySelectorAll('main > h4')) {
////     sortedLists.append((() => {
////       const node = document.createElement('h3')
////       node.append(header.textContent)
////       return node
////     })())
////     sortedMembers.append((() => {
////       const node = document.createElement('h2')
////       node.append(header.textContent)
////       return node
////     })())
////
////     const sortedList = document.createElement('ul')
////     sortedLists.append(sortedList)
////
////     for (const anchor of header.nextElementSibling.querySelectorAll('a')) {
////       const href = anchor.getAttribute('href')
////       const member = document.querySelector(`.member:has(h2 > a[href="${href}"])`)
////       const sidebar = list.querySelector(`li:has(a[href="${href}"])`)
////       sortedList.append(sidebar)
////       sortedMembers.append(member)
////     }
////   }
////
////   document.querySelector('.sidebar').insertBefore(sortedLists, list)
////   document.querySelector('.module-members:has(#module-values)').insertBefore(sortedMembers, document.querySelector('#module-values').nextSibling)
//// })
//// </script>
//// #### IP Address
//// - [ip_address_to_string](#ip_address_to_string)
//// #### Information
//// - [get_client_info](#get_client_info)
//// - [get_server_info](#get_server_info)
//// #### Builder
//// - [new](#new)
//// - [bind](#bind)
//// - [bind_all](#bind_all)
//// - [listening](#listening)
//// - [listening_random](#listening_random)
//// - [enable_ipv6](#enable_ipv6)
//// - [enable_tls](#enable_tls)
//// - [set_information_name](#set_information_name)
//// - [quiet](#quiet)
//// - [on_start](#on_start)
//// - [on_crash](#on_crash)
//// #### Server
//// - [start](#start)
//// - [supervised](#supervised)
//// #### Request
//// - [read_body](#read_body)
//// - [stream_body](#stream_body)
//// #### Response
//// - [text](#text)
//// - [bytes](#bytes)
//// - [bits](#bits)
//// - [string_tree](#string_tree)
//// - [empty](#empty)
//// - [json](#json)
//// #### Websocket
//// - [upgrade_websocket](#upgrade_websocket)
//// - [send_binary_frame](#send_binary_frame)
//// - [send_text_frame](#send_text_frame)
//// - [continue](#continue)
//// - [continue_with_selector](#continue_with_selector)
//// - [stop](#stop)
//// - [stop_abnormal](#stop_abnormal)
//// #### Experimental
//// - [use_expression](#use_expression)

// TODO: figure something out with getting server information

// -----------------------------------------------------------------------------
// IMPORTS
// -----------------------------------------------------------------------------

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Selector}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor} as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}

import glisten
import glisten/socket/options as glisten_options
import glisten/transport

import gramps/websocket as gramps

import ewe/internal/file as file_
import ewe/internal/handler as handler_
import ewe/internal/http as http_
import ewe/internal/information
import ewe/internal/websocket as ewe_websocket

// -----------------------------------------------------------------------------
// CONNECTION
// -----------------------------------------------------------------------------

/// Represents a connection between a client and a server, stored inside a
/// `Request`. Can be converted to a `BitArray` using `ewe.read_body`.
///
pub type Connection =
  http_.Connection

// -----------------------------------------------------------------------------
// IP ADDRESS
// -----------------------------------------------------------------------------

/// Represents an IP address. Appears when accessing client's information
/// (`ewe.client_stats`) or `on_start` handler (`ewe.on_start`).
///
pub type IpAddress {
  IpV4(Int, Int, Int, Int)
  IpV6(Int, Int, Int, Int, Int, Int, Int, Int)
}

/// Converts an `IpAddress` to a string for later printing.
/// 
pub fn ip_address_to_string(address address: IpAddress) -> String {
  ewe_to_glisten_ip(address)
  |> glisten.ip_address_to_string()
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

// -----------------------------------------------------------------------------
// INFORMATION
// -----------------------------------------------------------------------------

/// Represents client or server information. Can be retrieved using
/// `ewe.get_server_info` or `ewe.get_client_info`.
/// 
pub type SocketAddress {
  SocketAddress(ip: IpAddress, port: Int)
}

/// Performs an attempt to get the client's socket address.
/// 
pub fn get_client_info(
  connection connection: Connection,
) -> Result(SocketAddress, Nil) {
  transport.peername(connection.transport, connection.socket)
  |> result.map(fn(server_info) {
    SocketAddress(glisten_options_to_ewe_ip(server_info.0), server_info.1)
  })
}

/// Retrieves server's socket address. Requires the same name as the one used in
/// `ewe.with_name` and server to be started. Otherwise, will crash the program.
/// 
pub fn get_server_info(
  named name: process.Name(information.Message(SocketAddress)),
) -> Result(SocketAddress, Nil) {
  information.get(process.named_subject(name))
}

// -----------------------------------------------------------------------------
// RESPONSE
// -----------------------------------------------------------------------------

/// Represents a response body. To set the response body, use the following
/// functions: 
/// 
/// - `ewe.text`
/// - `ewe.bytes`
/// - `ewe.bits`
/// - `ewe.string_tree`
/// - `ewe.empty`
/// - `ewe.json`
/// 
pub opaque type ResponseBody {
  TextData(String)
  BytesData(BytesTree)
  BitsData(BitArray)
  StringTreeData(StringTree)

  WebsocketConnection(Selector(process.Down))

  Empty
}

fn transform_response_body(
  resp: Response(ResponseBody),
) -> Response(http_.ResponseBody) {
  response.set_body(resp, case resp.body {
    TextData(text) -> http_.TextData(text)
    BytesData(bytes) -> http_.BytesData(bytes)
    BitsData(bits) -> http_.BitsData(bits)
    StringTreeData(string_tree) -> http_.StringTreeData(string_tree)
    WebsocketConnection(selector) -> http_.WebsocketConnection(selector)
    Empty -> http_.Empty
  })
}

/// Sets response body from string, sets `content-type` to
/// `text/plain; charset=utf-8` and `content-length` headers.
/// 
pub fn text(response: Response(a), text: String) -> Response(ResponseBody) {
  response.set_body(response, TextData(text))
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_header(
    "content-length",
    int.to_string(string.byte_size(text)),
  )
}

/// Sets response body from bytes, sets `content-length` header. Doesn't set
/// `content-type` header.
/// 
pub fn bytes(response: Response(a), bytes: BytesTree) -> Response(ResponseBody) {
  response.set_body(response, BytesData(bytes))
  |> response.set_header(
    "content-length",
    int.to_string(bytes_tree.byte_size(bytes)),
  )
}

/// Sets response body from bits, sets `content-length` header. Doesn't set
/// `content-type` header.
/// 
pub fn bits(response: Response(a), bits: BitArray) -> Response(ResponseBody) {
  response.set_body(response, BitsData(bits))
  |> response.set_header(
    "content-length",
    int.to_string(bit_array.byte_size(bits)),
  )
}

/// Sets response body from string tree, sets `content-length` header. Doesn't
/// set `content-type` header.
/// 
pub fn string_tree(
  response: Response(a),
  string_tree: StringTree,
) -> Response(ResponseBody) {
  response.set_body(response, StringTreeData(string_tree))
  |> response.set_header(
    "content-length",
    int.to_string(string_tree.byte_size(string_tree)),
  )
}

/// Sets response body to empty, sets `content-length` header to `0`.
/// 
pub fn empty(response: Response(a)) -> Response(ResponseBody) {
  response.set_body(response, Empty)
  |> response.set_header("content-length", "0")
}

/// Sets response body from string tree (use `gleam_json` package and encode
/// using `json.to_string_tree`), sets `content-type` to `application/json;
/// charset=utf-8` and `content-length` headers.
/// 
pub fn json(
  response: Response(a),
  json json: StringTree,
) -> Response(ResponseBody) {
  string_tree(response, json)
  |> response.set_header("content-type", "application/json; charset=utf-8")
}

// -----------------------------------------------------------------------------
// BUILDER
// -----------------------------------------------------------------------------

type Handler =
  fn(Request(Connection)) -> Response(ResponseBody)

type OnStart =
  fn(http.Scheme, SocketAddress) -> Nil

/// Ewe's server builder. Contains all server's configuration. Can be adjusted
/// with the following functions:
/// - `ewe.bind`
/// - `ewe.bind_all`
/// - `ewe.listening`
/// - `ewe.listening_random`
/// - `ewe.enable_ipv6`
/// - `ewe.enable_tls`
/// - `ewe.set_information_name`
/// - `ewe.on_start`
/// - `ewe.quiet`
/// - `ewe.on_crash`
/// 
pub opaque type Builder {
  Builder(
    handler: Handler,
    port: Int,
    interface: String,
    ipv6: Bool,
    tls: Option(#(String, String)),
    on_start: OnStart,
    on_crash: Response(ResponseBody),
    information_name: process.Name(information.Message(SocketAddress)),
  )
}

/// Creates new server builder with handler provided.
/// 
/// Default configuration:
/// - port: `8080`
/// - interface: `127.0.0.1`
/// - No ipv6 support
/// - No TLS support
/// - Default process name for server information retrieval
/// - on_start: prints `Listening on <scheme>://<ip_address>:<port>`
/// - on_crash: empty 500 response
/// 
pub fn new(handler: Handler) -> Builder {
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

      io.println("Listening on " <> url)
    },
    on_crash: response.new(500) |> response.set_body(Empty),
    information_name: process.new_name("ewe_server_info"),
  )
}

/// Binds server to a specific interface. Crashes program if interface is invalid.
/// 
pub fn bind(builder: Builder, interface interface: String) -> Builder {
  Builder(..builder, interface:)
}

/// Binds server to all interfaces.
/// 
pub fn bind_all(builder: Builder) -> Builder {
  Builder(..builder, interface: "0.0.0.0")
}

/// Sets listening port for server.
/// 
pub fn listening(builder: Builder, port port: Int) -> Builder {
  Builder(..builder, port:)
}

/// Sets listening port for server to a random port. Useful for testing.
/// 
pub fn listening_random(builder: Builder) -> Builder {
  Builder(..builder, port: 0)
}

/// Enables IPv6 support.
/// 
pub fn enable_ipv6(builder: Builder) -> Builder {
  Builder(..builder, ipv6: True)
}

/// Enables TLS support, requires certificate and key file.
/// 
pub fn enable_tls(
  builder: Builder,
  certificate_file certificate_file: String,
  key_file key_file: String,
) -> Builder {
  let cert = case file_.open(certificate_file) {
    Ok(_) -> certificate_file
    Error(_) -> panic as "Failed to find cert file"
  }

  let key = case file_.open(key_file) {
    Ok(_) -> key_file
    Error(_) -> panic as "Failed to find key file"
  }

  Builder(..builder, tls: Some(#(cert, key)))
}

/// Sets a custom process name for server information retrieval, allowing to
/// use `ewe.get_server_info` after server starts.
/// 
pub fn set_information_name(
  builder: Builder,
  name: process.Name(information.Message(SocketAddress)),
) -> Builder {
  Builder(..builder, information_name: name)
}

/// Sets a custom handler that will be called after server starts.
/// 
pub fn on_start(
  builder: Builder,
  on_start: fn(http.Scheme, SocketAddress) -> Nil,
) -> Builder {
  Builder(..builder, on_start:)
}

/// Sets empty `on_start` function.
/// 
pub fn quiet(builder: Builder) -> Builder {
  Builder(..builder, on_start: fn(_, _) { Nil })
}

/// Sets a custom response that will be sent when server crashes.
/// 
pub fn on_crash(builder: Builder, on_crash: Response(ResponseBody)) -> Builder {
  Builder(..builder, on_crash:)
}

// -----------------------------------------------------------------------------
// SERVER
// -----------------------------------------------------------------------------

/// Starts the server.
/// 
pub fn start(
  builder: Builder,
) -> Result(actor.Started(Supervisor), actor.StartError) {
  let name = process.new_name("ewe_glisten")

  let handler = fn(req) { transform_response_body(builder.handler(req)) }
  let on_crash = transform_response_body(builder.on_crash)

  let subject = process.named_subject(builder.information_name)
  let information = information.worker(builder.information_name)

  let glisten_supervisor =
    glisten.new(fn(_conn) { #(Nil, None) }, handler_.loop(handler, on_crash))
    |> glisten.bind(builder.interface)
    |> fn(glisten_builder) {
      case builder.ipv6 {
        True -> glisten.with_ipv6(glisten_builder)
        False -> glisten_builder
      }
    }
    |> fn(glisten_builder) {
      case builder.tls {
        Some(#(cert, key)) -> glisten.with_tls(glisten_builder, cert, key)
        None -> glisten_builder
      }
    }
    // https://github.com/rawhat/glisten/blob/master/src/glisten.gleam#L359
    |> glisten.start_with_listener_name(builder.port, name)
    |> result.map(fn(started) {
      let scheme = case builder.tls {
        Some(#(_, _)) -> http.Https
        None -> http.Http
      }

      let server_info = glisten.get_server_info(name, 10_000)
      let ip_address = glisten_to_ewe_ip(server_info.ip_address)

      let server = SocketAddress(ip: ip_address, port: server_info.port)

      information.set(subject, server)
      builder.on_start(scheme, server)

      started
    })

  let glisten_child = supervision.supervisor(fn() { glisten_supervisor })

  supervisor.new(supervisor.OneForAll)
  |> supervisor.add(glisten_child)
  |> supervisor.add(information)
  |> supervisor.start()
}

/// Creates a supervisor that can be appended to a supervision tree.
/// 
pub fn supervised(
  builder: Builder,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  supervision.supervisor(fn() { start(builder) })
}

// -----------------------------------------------------------------------------
// REQUEST
// -----------------------------------------------------------------------------

/// Possible errors that can occur when reading a body.
/// 
pub type BodyError {
  BodyTooLarge
  InvalidBody
}

/// Reads body from a request. If request body is malformed, `InvalidBody`
/// error is returned. On success, returns a request with body converted to
/// `BitArray`.
/// - When `transfer-encoding` header set as `chunked`, `BodyTooLarge` error is returned if
/// accumulated body is larger than `size_limit`.
/// - Ensures that `content-length` is in `size_limit` scope.
/// 
pub fn read_body(
  req: Request(Connection),
  bytes_limit bytes_limit: Int,
) -> Result(Request(BitArray), BodyError) {
  case http_.read_body(req, bytes_limit) {
    Ok(req) -> Ok(req)
    Error(http_.BodyTooLarge) -> Error(BodyTooLarge)
    Error(_) -> Error(InvalidBody)
  }
}

/// Alias for consumer type for reading N amount of bytes from the request body stream.
pub type Consumer =
  fn(Int) -> Result(Stream, BodyError)

/// Used to track the progress of reading the request body stream.
pub type Stream {
  Consumed(data: BitArray, next: Consumer)
  Done
}

/// Streams the request body.
/// 
pub fn stream_body(req: Request(Connection)) -> Result(Consumer, BodyError) {
  case http_.stream_body(req) {
    Ok(consumer) -> Ok(consumer_adapter(consumer))
    Error(_) -> Error(InvalidBody)
  }
}

// Helper function to convert internal consumer to public consumer
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

// -----------------------------------------------------------------------------
// WEBSOCKET
// -----------------------------------------------------------------------------

// TODO: pass all autobahn tests
// tests failing because of gramps:
// 3.*
// 4.*
// 5.1, 5.2
// 12.1.11

pub type WebsocketConnection =
  ewe_websocket.WebsocketConnection

/// Represents instruction on how WebSocket connection should proceed.
/// 
/// - continue processing the WebSocket connection.
/// - continue processing the WebSocket connection with selector for custom messages.
/// - stop the WebSocket connection.
/// - stop the WebSocket connection with abnormal reason.
/// 
pub opaque type Next(user_state, user_message) {
  Continue(user_state, Option(Selector(user_message)))
  NormalStop
  AbnormalStop(reason: String)
}

/// Instructs WebSocket connection to continue processing.
/// 
pub fn continue(user_state: user_state) -> Next(user_state, user_message) {
  Continue(user_state, None)
}

/// Instructs WebSocket connection to continue processing, including selector
/// for custom messages.
/// 
pub fn continue_with_selector(
  user_state: user_state,
  selector: Selector(user_message),
) -> Next(user_state, user_message) {
  Continue(user_state, Some(selector))
}

/// Instructs WebSocket connection to stop.
/// 
pub fn stop() -> Next(user_state, user_message) {
  NormalStop
}

/// Instructs WebSocket connection to stop with abnormal reason.
/// 
pub fn stop_abnormal(reason: String) -> Next(user_state, user_message) {
  AbnormalStop(reason)
}

fn to_internal_next(
  next: Next(user_state, user_message),
) -> ewe_websocket.WebsocketNext(user_state, user_message) {
  case next {
    Continue(user_state, selector) ->
      ewe_websocket.Continue(user_state, selector)
    NormalStop -> ewe_websocket.NormalStop
    AbnormalStop(reason) -> ewe_websocket.AbnormalStop(reason)
  }
}

/// Represents a WebSocket message received from the client.
pub type WebsocketMessage(user_message) {
  Text(String)
  Binary(BitArray)
  User(user_message)
}

fn transform_websocket_message(
  message: ewe_websocket.WebsocketMessage(user_message),
) -> Result(WebsocketMessage(user_message), Nil) {
  case message {
    ewe_websocket.WebsocketFrame(gramps.Data(frame)) -> {
      gramps.match_data_frame(
        frame,
        on_text: fn(payload, _) {
          bit_array.to_string(payload) |> result.map(Text)
        },
        on_binary: fn(payload, _) { Ok(Binary(payload)) },
      )
    }
    ewe_websocket.UserMessage(user_message) -> Ok(User(user_message))
    _ -> Error(Nil)
  }
}

/// Upgrade request to a WebSocket connection. If the initial request is not
/// valid for WebSocket upgrade, 400 response is sent. Handler must return
/// instruction on how WebSocket connection should proceed.
///  
pub fn upgrade_websocket(
  req: Request(Connection),
  on_init on_init: fn(WebsocketConnection, Selector(user_message)) ->
    #(user_state, Selector(user_message)),
  handler handler: fn(
    WebsocketConnection,
    user_state,
    WebsocketMessage(user_message),
  ) ->
    Next(user_state, user_message),
  on_close on_close: fn(WebsocketConnection, user_state) -> Nil,
) -> Response(ResponseBody) {
  let handler = fn(conn, state, msg) {
    transform_websocket_message(msg)
    |> result.map(handler(conn, state, _))
    |> result.unwrap(continue(state))
    |> to_internal_next()
  }

  let transport = req.body.transport
  let socket = req.body.socket

  let resp = {
    use #(extensions, permessage_deflate) <- result.try(
      http_.upgrade_websocket(req, transport, socket)
      |> result.replace_error(response.new(400) |> response.set_body(Empty)),
    )

    use selector <- result.try(
      ewe_websocket.start(
        transport,
        socket,
        on_init,
        handler,
        on_close,
        extensions,
        permessage_deflate,
      )
      |> result.replace_error(response.new(500) |> response.set_body(Empty)),
    )

    response.new(500)
    |> response.set_body(WebsocketConnection(selector))
    |> Ok
  }

  result.unwrap_both(resp)
}

/// Sends a binary frame to the websocket client.
/// 
pub fn send_binary_frame(
  conn: WebsocketConnection,
  bits: BitArray,
) -> Result(Nil, glisten.SocketReason) {
  ewe_websocket.send_frame(
    gramps.encode_binary_frame,
    conn.transport,
    conn.socket,
    conn.deflate,
    bits,
  )
}

/// Sends a text frame to the websocket client.
/// 
pub fn send_text_frame(
  conn: WebsocketConnection,
  text: String,
) -> Result(Nil, glisten.SocketReason) {
  ewe_websocket.send_frame(
    gramps.encode_text_frame,
    conn.transport,
    conn.socket,
    conn.deflate,
    text,
  )
}

// -----------------------------------------------------------------------------
// EXPERIMENTAL
// -----------------------------------------------------------------------------

/// Experimental function that simplifies error handling in handlers when
/// working with `Result` type.
/// 
/// ## Example
/// 
/// ```gleam
/// pub fn handle_echo(
///   req: Request(ewe.Connection),
/// ) -> Response(bytes_tree.BytesTree) {
///   let content_type =
///     request.get_header(req, "content-type")
///     |> result.unwrap("text/plain")
///
///    // Start the use_expression block
///    use <- ewe.use_expression()
///
///    // Now you can use result.try with use expressions
///    // If any step fails, the error response is automatically returned
///    use req <- result.try(
///      ewe.read_body(req, 1024)
///      |> result.replace_error(
///        response.new(400)
///        |> ewe.json(error_json("Invalid request body")),
///      ),
///    )
///
///    response.new(200)
///    |> ewe.bits(req.body)
///    |> response.set_header("content-type", content_type)
///    |> Ok 
///}
/// ```
///
pub fn use_expression(
  handler: fn() -> Result(Response(ResponseBody), Response(ResponseBody)),
) -> Response(ResponseBody) {
  result.unwrap_both(handler())
}
