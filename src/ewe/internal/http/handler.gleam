import compresso
import ewe/internal/encoder
import ewe/internal/file
import ewe/internal/http.{
  type Connection, type HttpVersion, type ResponseBody, BitsData, BytesData,
  Chunked, Empty, File, SSE, StringTreeData, TextData, Websocket,
} as http_
import ewe/internal/http/buffer.{Buffer}
import exception
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree
import glisten
import glisten/internal/handler.{Close, Internal} as glisten_handler
import glisten/socket
import glisten/transport
import logging

/// HTTP/1.1 handler state.
///
pub type HttpHandler {
  HttpHandler(idle_timer: Option(process.Timer))
}

/// Initializes the HTTP/1.1 handler state.
///
pub fn init() -> HttpHandler {
  HttpHandler(idle_timer: None)
}

/// Action to take after handling a packet.
///
pub type Next {
  Continue(state: HttpHandler)
  Stop
  Http2Upgrade(upgrade: http_.Http2Upgrade)
}

/// Handles received glisten packet.
///
pub fn handle_packet(
  state: HttpHandler,
  connection: http_.Http,
  data: BitArray,
  glisten_subject: process.Subject(glisten_handler.Message(_)),
  handler: fn(Request(Connection)) -> Response(ResponseBody),
  on_crash: Response(ResponseBody),
  idle_timeout: Int,
) -> Next {
  case state.idle_timer {
    Some(timer) -> process.cancel_timer(timer)
    None -> process.TimerNotFound
  }

  case http_.parse_request(connection, Buffer(data, 0)) {
    Ok(http_.HttpRequest(request, version)) -> {
      let call_result =
        call(request, version, glisten_subject, handler, on_crash, idle_timeout)

      case call_result {
        Ok(state) -> Continue(state)
        Error(Nil) -> Stop
      }
    }
    Ok(http_.Http2Upgrade(upgrade)) -> Http2Upgrade(upgrade:)
    Error(reason) -> {
      let status = case reason {
        http_.InvalidVersion -> 505
        _ -> 400
      }

      let _ =
        response.new(status)
        |> response.set_body(<<>>)
        |> response.set_header("connection", "close")
        |> encoder.encode_response()
        |> transport.send(connection.transport, connection.socket, _)

      Stop
    }
  }
}

/// Takes parsed HTTP request and calls the handler.
///
fn call(
  request: Request(http_.Http),
  version: HttpVersion,
  glisten_subject: process.Subject(glisten_handler.Message(_)),
  handler: fn(Request(Connection)) -> Response(ResponseBody),
  on_crash: Response(ResponseBody),
  idle_timeout: Int,
) -> Result(HttpHandler, Nil) {
  let response = case
    exception.rescue(fn() {
      request.set_body(request, http_.HttpConnection(request.body))
      |> handler
    })
  {
    Ok(response) -> response
    Error(e) -> {
      logging.log(logging.Error, string.inspect(e))

      response.set_header(on_crash, "connection", "close")
    }
  }

  case response.body {
    Websocket | SSE | Chunked -> Error(Nil)
    File(descriptor, offset, size) ->
      send_file(request, version, response, descriptor, offset, size)
      |> on_sent(response, glisten_subject, idle_timeout)

    _ ->
      send_body(request, version, response)
      |> on_sent(response, glisten_subject, idle_timeout)
  }
}

/// Actions to take after response is sent.
///
fn on_sent(
  sent: Result(Nil, glisten.SocketReason),
  response: Response(ResponseBody),
  glisten_subject: process.Subject(glisten_handler.Message(_)),
  idle_timeout: Int,
) -> Result(HttpHandler, Nil) {
  case sent, is_connection_close(response) {
    Ok(Nil), False -> {
      let timer =
        process.send_after(glisten_subject, idle_timeout, Internal(Close))

      Ok(HttpHandler(Some(timer)))
    }
    _, _ -> Error(Nil)
  }
}

/// Sends a file to the client.
///
fn send_file(
  request: Request(http_.Http),
  version: HttpVersion,
  response: Response(ResponseBody),
  descriptor: file.IoDevice,
  offset: Int,
  size: Int,
) -> Result(Nil, glisten.SocketReason) {
  let response = case response.get_header(response, "content-length") {
    Ok(_) -> response
    Error(Nil) ->
      response.set_header(response, "content-length", int.to_string(size))
  }

  let sent =
    http_.append_default_headers(response, request, version)
    |> encoder.encode_response_partially()
    |> transport.send(request.body.transport, request.body.socket, _)
    |> result.try(fn(_) {
      file.send(
        request.body.transport,
        request.body.socket,
        descriptor,
        offset,
        size,
      )
      |> result.replace_error(socket.Badarg)
    })

  let _ = file.close(descriptor)

  sent
}

/// Sends a body to the client.
///
fn send_body(
  request: Request(http_.Http),
  version: HttpVersion,
  response: Response(ResponseBody),
) -> Result(Nil, glisten.SocketReason) {
  let bits = case response.body {
    TextData(text) -> bit_array.from_string(text)
    StringTreeData(string_tree) ->
      string_tree.to_string(string_tree) |> bit_array.from_string
    BitsData(bits) -> bits
    BytesData(bytes) -> bytes_tree.to_bit_array(bytes)
    Empty -> <<>>
    _ -> panic
  }

  let content_length = bit_array.byte_size(bits)
  let response = case content_length > 1024 {
    True ->
      case can_encode_gzip(request, response) {
        True -> {
          let compressed = compresso.gzip(bits)
          let content_length = bit_array.byte_size(compressed)

          remove_charset(response)
          |> response.set_header("content-encoding", "gzip")
          |> response.set_header("vary", "Accept-Encoding")
          |> response.set_header(
            "content-length",
            int.to_string(content_length),
          )
          |> response.set_body(compressed)
        }
        _ ->
          response.set_body(response, bits)
          |> response.set_header(
            "content-length",
            int.to_string(content_length),
          )
      }
    False ->
      response.set_body(response, bits)
      |> response.set_header("content-length", int.to_string(content_length))
  }

  http_.append_default_headers(response, request, version)
  |> encoder.encode_response()
  |> transport.send(request.body.transport, request.body.socket, _)
}

/// Can the body be encoded to gzip?
///
fn can_encode_gzip(request: Request(http_.Http), response: Response(_)) -> Bool {
  let accept_encoding =
    request.get_header(request, "accept-encoding")
    |> result.map(string.contains(_, "gzip"))

  let content_encoding = response.get_header(response, "content-encoding")

  case accept_encoding, content_encoding {
    Ok(True), Error(Nil) -> True
    _, _ -> False
  }
}

/// Removes the charset from the content-type header.
///
fn remove_charset(response: Response(_)) -> Response(_) {
  response.get_header(response, "content-type")
  |> result.try(string.split_once(_, ";"))
  |> result.map(fn(parts) {
    response.set_header(response, "content-type", parts.0)
  })
  |> result.unwrap(response)
}

/// Is the connection set to close?
///
fn is_connection_close(response: Response(_)) -> Bool {
  case response.get_header(response, "connection") {
    Ok("close") -> True
    _ -> False
  }
}
