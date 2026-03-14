import ewe/internal/clock
import ewe/internal/decoder.{
  AbsPath, HttpBin, HttpEoh, HttpHeader, HttpRequest, HttphBin, More, Packet,
}
import ewe/internal/encoder
import ewe/internal/file
import ewe/internal/http1/buffer.{type Buffer, Buffer}
import gleam/bit_array
import gleam/bool
import gleam/bytes_tree.{type BytesTree}
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request, Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/result.{replace_error, try}
import gleam/set.{type Set}
import gleam/string
import gleam/string_tree.{type StringTree}
import gleam/uri
import glisten
import glisten/socket.{type Socket}
import glisten/transport.{type Transport}
import websocks

// Connection
// -----------------------------------------------------------------------------

/// Connection to a client.
///
pub type Connection {
  Connection(
    transport: Transport,
    socket: Socket,
    buffer: Buffer,
    factory_name: process.Name(
      factory.Message(fn() -> Result(actor.Started(Nil), actor.StartError), Nil),
    ),
  )
}

/// Transforms a glisten connection.
///
pub fn transform_connection(
  conn: glisten.Connection(a),
  factory_name: process.Name(_),
) -> Connection {
  Connection(
    transport: conn.transport,
    socket: conn.socket,
    buffer: Buffer(<<>>, 0),
    factory_name:,
  )
}

/// Reads data from the socket with timeout and size limits.
///
fn read_from_socket(
  transport transport: Transport,
  socket socket: Socket,
  buffer buffer: Buffer,
  on_error on_error: ParseError,
) -> Result(Buffer, ParseError) {
  let read_size = int.min(buffer.pending, max_reading_size)

  use data <- try(
    transport.receive_timeout(transport, socket, read_size, 5000)
    |> replace_error(on_error),
  )

  let new_buffer = buffer.append(buffer, data)

  case new_buffer.pending {
    0 -> Ok(new_buffer)
    _ -> read_from_socket(transport:, socket:, buffer: new_buffer, on_error:)
  }
}

// HTTP/1.1
// -----------------------------------------------------------------------------

/// Errors that can occur when parsing a request.
///
pub type ParseError {
  // request line
  InvalidMethod
  InvalidTarget
  InvalidVersion
  // headers
  InvalidHeaders
  MissingHost
  DuplicateHost
  InvalidContentLength
  // body
  InvalidBody
  BodyTooLarge
  // anomalies
  MalformedRequest
  PacketDiscard
}

/// HTTP version enumeration.
///
pub type HttpVersion {
  Http10
  Http11
}

/// Result of parsing a request.
///
pub type ParsedRequest {
  Http1Request(req: Request(Connection), version: HttpVersion)
  Http2Upgrade(upgrade: Http2Upgrade)
}

/// HTTP/2 upgrade options.
///
pub type Http2Upgrade {
  Upgrade(req: Request(Connection), settings: String)
  Direct(data: BitArray)
}

/// Parses an HTTP request from the given buffer.
///
pub fn parse_request(
  conn: Connection,
  buffer: Buffer,
) -> Result(ParsedRequest, ParseError) {
  let transport = conn.transport
  let socket = conn.socket

  case decoder.decode_packet(HttpBin, buffer) {
    Ok(Packet(HttpRequest(atom_method, AbsPath(target), version), rest)) -> {
      // Request Line
      use method <- try(
        decoder.decode_method(atom_method)
        |> replace_error(InvalidMethod),
      )

      use uri <- try(
        bit_array.to_string(target)
        |> try(uri.parse)
        |> replace_error(InvalidTarget),
      )

      // Headers
      use #(headers, rest) <- try(parse_headers(
        transport,
        socket,
        buffer: Buffer(rest, 0),
        headers: dict.new(),
      ))

      // Forming the request
      let scheme = case transport {
        transport.Tcp(..) -> http.Http
        transport.Ssl(..) -> http.Https
      }

      use host <- try(
        dict.get(headers, "host")
        |> result.replace_error(MissingHost),
      )

      let #(host, port) = case string.split_once(host, ":") {
        Ok(#(host, port)) -> #(host, Some(port))
        Error(_) -> #(host, None)
      }

      let port =
        option.map(port, fn(port) {
          int.parse(port)
          |> result.unwrap(case scheme {
            http.Http -> 80
            http.Https -> 443
          })
        })

      let req =
        Request(
          method:,
          headers: dict.to_list(headers),
          body: Connection(..conn, buffer: Buffer(rest, 0)),
          scheme:,
          host:,
          port:,
          path: uri.path,
          query: uri.query,
        )

      case version {
        #(1, 0) -> Ok(Http1Request(req:, version: Http10))
        #(1, 1) -> {
          let connection = dict.get(headers, "connection")
          let upgrade = dict.get(headers, "upgrade")
          let settings = dict.get(headers, "http2-settings")

          case connection, upgrade, settings {
            Ok(connection), Ok("h2c"), Ok(settings) -> {
              let is_upgrade =
                string.contains(string.lowercase(connection), "upgrade")

              case is_upgrade {
                True -> Ok(Http2Upgrade(Upgrade(req:, settings:)))
                False -> Ok(Http1Request(req:, version: Http11))
              }
            }
            _, _, _ -> Ok(Http1Request(req:, version: Http11))
          }
        }
        _ -> Error(InvalidVersion)
      }
    }
    Ok(Packet(decoder.Http2Upgrade, <<"\r\nSM\r\n\r\n":utf8, data:bits>>)) ->
      Ok(Http2Upgrade(Direct(data:)))
    Ok(More(size)) -> {
      use new_buffer <- try(read_from_socket(
        transport,
        socket,
        buffer: Buffer(buffer.data, option.unwrap(size, 0)),
        on_error: MalformedRequest,
      ))

      parse_request(conn, new_buffer)
    }
    _ -> Error(PacketDiscard)
  }
}

/// Parses HTTP headers from the buffer.
///
fn parse_headers(
  transport transport: Transport,
  socket socket: Socket,
  buffer buffer: Buffer,
  headers headers: Dict(String, String),
) {
  case decoder.decode_packet(HttphBin, buffer) {
    Ok(Packet(HttpEoh, rest)) -> Ok(#(headers, rest))
    Ok(Packet(HttpHeader(idx, field, value), rest)) -> {
      use field <- try(case decoder.formatted_field_by_idx(idx) {
        Ok(field) -> Ok(field)
        Error(Nil) -> {
          bit_array.to_string(field)
          |> result.map(string.lowercase)
          |> replace_error(InvalidHeaders)
        }
      })

      use value <- try(
        validate_field_value(value) |> replace_error(InvalidHeaders),
      )

      let new_buffer = Buffer(rest, 0)

      use _ <- try(case field {
        "host" -> {
          case dict.has_key(headers, field) {
            True -> Error(DuplicateHost)
            False -> Ok(Nil)
          }
        }
        "content-length" -> {
          int.parse(value)
          |> result.try(fn(value) {
            case value < 0 {
              True -> Error(Nil)
              False -> Ok(Nil)
            }
          })
          |> result.replace_error(InvalidContentLength)
        }
        _ -> Ok(Nil)
      })

      insert_header(headers, field, value)
      |> parse_headers(transport:, socket:, buffer: new_buffer, headers: _)
    }
    Ok(More(size)) -> {
      let read_size = option.unwrap(size, 0)

      let sized_buffer = Buffer(buffer.data, read_size)

      use new_buffer <- try(read_from_socket(
        transport:,
        socket:,
        buffer: sized_buffer,
        on_error: InvalidHeaders,
      ))

      parse_headers(transport:, socket:, buffer: new_buffer, headers:)
    }
    _ -> Error(InvalidHeaders)
  }
}

@external(erlang, "ewe_ffi", "validate_field_value")
fn validate_field_value(value: BitArray) -> Result(String, Nil)

/// Inserts a header into the headers dictionary.
///
fn insert_header(
  headers: Dict(String, String),
  field: String,
  value: String,
) -> Dict(String, String) {
  case field != "set-cookie" {
    True ->
      dict.upsert(headers, field, fn(target) {
        case target {
          option.Some(existing) -> existing <> ", " <> value
          option.None -> value
        }
      })
    False -> dict.insert(headers, available_cookie_key(headers, 0), value)
  }
}

/// Finds an available key for set-cookie headers.
///
fn available_cookie_key(headers: Dict(String, String), idx: Int) -> String {
  let key = case idx {
    0 -> "set-cookie"
    n -> "set-cookie-" <> int.to_string(n)
  }

  case dict.has_key(headers, key) {
    True -> available_cookie_key(headers, idx + 1)
    False -> key
  }
}

// Reading Body
// -----------------------------------------------------------------------------

/// 2MB (2 million bytes).
///
const max_reading_size = 2_000_000

/// Reads the request body from the socket.
///
pub fn read_body(
  req: Request(Connection),
  size_limit: Int,
) -> Result(Request(BitArray), ParseError) {
  use _ <- try(handle_continue(req))

  let transport = req.body.transport
  let socket = req.body.socket

  let transfer_encoding =
    request.get_header(req, "transfer-encoding")
    |> result.map(string.lowercase)

  case transfer_encoding {
    Ok("chunked") -> {
      use #(body, rest_buffer) <- try(read_chunked_body(
        transport,
        socket,
        req.body.buffer,
        <<>>,
        size_limit,
        0,
      ))

      let req = request.set_body(req, body)

      case list.key_find(req.headers, "trailer") {
        Ok(trailer) -> {
          let set =
            trailer
            |> string.split(",")
            |> list.fold(set.new(), fn(set, field) {
              set.insert(set, string.trim(field) |> string.lowercase())
            })

          Ok(handle_trailers(req, set, rest_buffer))
        }
        Error(Nil) -> Ok(req)
      }
    }
    _ -> {
      let content_length =
        request.get_header(req, "content-length")
        |> try(int.parse)
        |> result.unwrap(0)

      use <- bool.guard(content_length > size_limit, Error(BodyTooLarge))

      let left = content_length - bit_array.byte_size(req.body.buffer.data)

      case content_length, left {
        0, 0 -> Ok(<<>>)
        0, _l | _cl, 0 -> Ok(req.body.buffer.data)
        _cl, _l ->
          read_from_socket(
            transport,
            socket,
            buffer: Buffer(req.body.buffer.data, left),
            on_error: InvalidBody,
          )
          |> result.map(fn(buffer) { buffer.data })
      }
      |> result.map(request.set_body(req, _))
    }
  }
}

/// Reads a chunked transfer-encoded body.
///
fn read_chunked_body(
  transport transport: Transport,
  socket socket: Socket,
  buffer buffer: Buffer,
  accumulated_body accumulated_body: BitArray,
  body_size_limit body_size_limit: Int,
  body_current_size body_current_size: Int,
) -> Result(#(BitArray, Buffer), ParseError) {
  use <- bool.guard(body_current_size > body_size_limit, Error(BodyTooLarge))

  case parse_body_chunk(buffer) {
    Ok(FinalChunk(rest)) -> Ok(#(accumulated_body, rest))
    Ok(Incomplete) -> {
      use new_buffer <- try(read_from_socket(
        transport:,
        socket:,
        buffer:,
        on_error: InvalidBody,
      ))

      read_chunked_body(
        transport:,
        socket:,
        buffer: new_buffer,
        accumulated_body:,
        body_size_limit:,
        body_current_size:,
      )
    }
    Ok(Chunk(chunk, size, rest)) ->
      read_chunked_body(
        transport:,
        socket:,
        buffer: rest,
        accumulated_body: <<accumulated_body:bits, chunk:bits>>,
        body_size_limit:,
        body_current_size: body_current_size + size,
      )
    Error(error) -> Error(error)
  }
}

/// Parses a single chunk from the chunked body.
///
fn parse_body_chunk(buffer: Buffer) -> Result(BodyChunk, ParseError) {
  case split(buffer.data, <<"\r\n">>, []) {
    [<<"0">>, rest] -> Ok(FinalChunk(Buffer(rest, 0)))
    [chunk_size, rest] -> {
      use size <- try(
        bit_array.to_string(chunk_size)
        |> try(int.base_parse(_, 16))
        |> replace_error(InvalidBody),
      )

      case split(rest, <<"\r\n">>, []) {
        [chunk, rest] -> {
          case bit_array.byte_size(chunk) == size {
            True -> Ok(Chunk(chunk, size, Buffer(rest, 0)))
            False -> Error(InvalidBody)
          }
        }
        _ -> Ok(Incomplete)
      }
    }
    _ -> Ok(Incomplete)
  }
}

@external(erlang, "binary", "split")
fn split(
  subject: BitArray,
  pattern: BitArray,
  options: List(atom.Atom),
) -> List(BitArray)

/// Handles trailer headers in chunked responses.
fn handle_trailers(
  req: Request(BitArray),
  set: Set(String),
  rest: Buffer,
) -> Request(BitArray) {
  case decoder.decode_packet(HttphBin, rest) {
    Ok(Packet(HttpEoh, _)) -> req
    Ok(Packet(HttpHeader(idx, field, value), header_rest)) -> {
      let field_name = case decoder.formatted_field_by_idx(idx) {
        Ok(field_name) -> Ok(field_name)
        Error(Nil) -> {
          bit_array.to_string(field)
          |> result.map(string.lowercase)
        }
      }

      case field_name {
        Ok(field_name) -> {
          case set.contains(set, field_name) && is_allowed_trailer(field_name) {
            True -> {
              case bit_array.to_string(value) {
                Ok(value) -> {
                  request.set_header(req, field_name, value)
                  |> handle_trailers(set, Buffer(header_rest, 0))
                }
                Error(Nil) -> handle_trailers(req, set, Buffer(header_rest, 0))
              }
            }
            False -> handle_trailers(req, set, Buffer(header_rest, 0))
          }
        }
        Error(Nil) -> handle_trailers(req, set, Buffer(header_rest, 0))
      }
    }
    _ -> req
  }
}

/// Checks if a trailer field is allowed.
fn is_allowed_trailer(field: String) -> Bool {
  case field {
    "server-timing" | "content-digest" | "repr-digest" -> True
    _ -> False
  }
}

// Streaming Body
// -----------------------------------------------------------------------------

/// Possible results of consuming some amount of data from the request body.
///
pub type Stream {
  Consumed(data: BitArray, next: fn(Int) -> Result(Stream, ParseError))
  Done
}

/// Chunked body parsing result.
///
type BodyChunk {
  Incomplete
  Chunk(BitArray, size: Int, rest: Buffer)
  FinalChunk(rest: Buffer)
}

/// State of the chunked body parsing.
///
type ChunkedStreamState {
  ChunkedStreamState(data: Buffer, chunk: Buffer, done: Bool)
}

/// Streams the request body from the socket.
///
pub fn stream_body(req: Request(Connection)) {
  use _ <- result.try(
    handle_continue(req)
    |> result.replace_error(InvalidBody),
  )

  case request.get_header(req, "transfer-encoding") {
    Ok("chunked") -> {
      let state = ChunkedStreamState(Buffer(<<>>, 0), req.body.buffer, False)
      Ok(do_stream_body_chunked(req, state))
    }
    _ -> {
      let content_length =
        request.get_header(req, "content-length")
        |> result.try(int.parse)
        |> result.unwrap(0)

      let pending = content_length - bit_array.byte_size(req.body.buffer.data)
      let stream_buffer = Buffer(req.body.buffer.data, int.max(0, pending))

      do_stream_body(req, stream_buffer)
      |> Ok
    }
  }
}

/// Creates a consumer function that reads `N` amount of bytes from the chunked
/// request body until it is fully consumed.
fn do_stream_body_chunked(
  req: Request(Connection),
  chunked_stream_state: ChunkedStreamState,
) -> fn(Int) -> Result(Stream, ParseError) {
  fn(size: Int) {
    let read_result =
      read_from_socket_until(
        transport: req.body.transport,
        socket: req.body.socket,
        state: chunked_stream_state,
        until: size,
      )

    case read_result {
      Ok(#(data, ChunkedStreamState(done: True, ..))) ->
        Ok(Consumed(data, fn(_) { Ok(Done) }))
      Ok(#(data, state)) ->
        Ok(Consumed(data, do_stream_body_chunked(req, state)))
      Error(_) -> Error(InvalidBody)
    }
  }
}

/// Reads data from the socket until `N` amount of bytes are read.
fn read_from_socket_until(
  transport transport: Transport,
  socket socket: Socket,
  state state: ChunkedStreamState,
  until until: Int,
) -> Result(#(BitArray, ChunkedStreamState), ParseError) {
  let size = bit_array.byte_size(state.data.data)

  case state.done, size {
    // Data buffer contains enough data to consume `until` bytes
    _, size if size >= until -> {
      let #(data, rest) = buffer.split(state.data, until)
      Ok(#(data, ChunkedStreamState(..state, data: Buffer(rest, 0))))
    }

    // Accomplished the reading
    True, _ -> Ok(#(state.data.data, state))

    // Data buffer does not contain enough data to consume `until` bytes
    False, _ -> {
      case parse_body_chunk(state.chunk) {
        Ok(FinalChunk(_)) ->
          read_from_socket_until(
            transport:,
            socket:,
            state: ChunkedStreamState(
              ..state,
              chunk: Buffer(<<>>, 0),
              done: True,
            ),
            until:,
          )
        Ok(Incomplete) -> {
          use new_buffer <- try(read_from_socket(
            transport:,
            socket:,
            buffer: state.chunk,
            on_error: InvalidBody,
          ))

          read_from_socket_until(
            transport:,
            socket:,
            state: ChunkedStreamState(..state, chunk: new_buffer),
            until:,
          )
        }
        Ok(Chunk(chunk, _, rest)) -> {
          read_from_socket_until(
            transport:,
            socket:,
            state: ChunkedStreamState(
              ..state,
              data: buffer.append(state.data, chunk),
              chunk: rest,
            ),
            until:,
          )
        }
        Error(error) -> Error(error)
      }
    }
  }
}

/// Creates a consumer function that reads `N` amount of bytes from the request
/// body until it is fully consumed.
///
fn do_stream_body(
  req: Request(Connection),
  buffer: Buffer,
) -> fn(Int) -> Result(Stream, ParseError) {
  fn(size: Int) {
    let buffer_size = bit_array.byte_size(buffer.data)

    case buffer.pending, buffer_size {
      // Request body is fully consumed
      0, 0 -> Ok(Done)

      // Request body is supposed to be fully consumed but there is more data
      // in buffer
      0, _ -> {
        let #(data, rest) = buffer.split(buffer, size)
        Ok(Consumed(data, do_stream_body(req, Buffer(rest, 0))))
      }

      // Request body is not fully consumed and there is enough data in buffer
      // to consume `size` bytes
      _, buffer_size if buffer_size >= size -> {
        let #(data, rest) = buffer.split(buffer, size)
        let new_buffer = Buffer(rest, buffer.pending)
        Ok(Consumed(data, do_stream_body(req, new_buffer)))
      }

      // Request body is not fully consumed and there is not enough data in
      // buffer to consume `size` bytes
      _, _ -> {
        use read_buffer <- try(read_from_socket(
          transport: req.body.transport,
          socket: req.body.socket,
          buffer: Buffer(<<>>, 0),
          on_error: InvalidBody,
        ))

        let new_buffer =
          Buffer(
            <<buffer.data:bits, read_buffer.data:bits>>,
            int.max(0, buffer.pending - bit_array.byte_size(read_buffer.data)),
          )

        let #(data, rest) = buffer.split(new_buffer, size)
        Ok(Consumed(data, do_stream_body(req, Buffer(rest, 0))))
      }
    }
  }
}

// Upgrades
// -----------------------------------------------------------------------------

/// Errors that can occur when upgrading a WebSocket connection.
///
pub type UpgradeWebsocketError {
  MethodNotGet
  MissingConnectionHeader
  InvalidConnectionHeader
  MissingUpgradeHeader
  InvalidUpgradeHeader
  MissingWebsocketVersion
  MissingWebsocketKey
}

/// Upgrades an HTTP connection to WebSocket.
///
pub fn upgrade_websocket(
  req: Request(Connection),
  transport: Transport,
  socket: Socket,
) -> Result(#(List(String), Bool), UpgradeWebsocketError) {
  use <- bool.guard(req.method != http.Get, Error(MethodNotGet))

  let is_upgrade =
    request.get_header(req, "connection")
    |> result.map(fn(connection) {
      string.lowercase(connection) |> string.contains("upgrade")
    })

  use _ <- try(case is_upgrade {
    Ok(True) -> Ok(Nil)
    Ok(False) -> Error(InvalidConnectionHeader)
    Error(_) -> Error(MissingConnectionHeader)
  })

  use _ <- try(
    case request.get_header(req, "upgrade") |> result.map(string.lowercase) {
      Ok("websocket") -> Ok(Nil)
      Ok(_) -> Error(InvalidUpgradeHeader)
      Error(_) -> Error(MissingUpgradeHeader)
    },
  )

  use <- bool.guard(
    request.get_header(req, "sec-websocket-version") == Error(Nil),
    Error(MissingWebsocketVersion),
  )

  use key <- try(
    request.get_header(req, "sec-websocket-key")
    |> result.replace_error(MissingWebsocketKey),
  )

  let accept_key = websocks.compute_accept(key)

  let extensions =
    request.get_header(req, "sec-websocket-extensions")
    |> result.map(string.split(_, ";"))
    |> result.unwrap([])

  let permessage_deflate = websocks.has_deflate(extensions)

  let resp =
    response.new(101)
    |> response.set_body(<<>>)
    |> response.set_header("connection", "upgrade")
    |> response.set_header("upgrade", "websocket")
    |> response.set_header("sec-websocket-accept", accept_key)
    |> response.set_header("sec-websocket-version", "13")

  let resp = case permessage_deflate {
    True ->
      response.set_header(
        resp,
        "sec-websocket-extensions",
        "permessage-deflate",
      )
    False -> resp
  }

  let _ =
    encoder.encode_response(resp)
    |> transport.send(transport, socket, _)

  Ok(#(extensions, permessage_deflate))
}

// Response
// -----------------------------------------------------------------------------

/// Response body variants.
///
pub type ResponseBody {
  TextData(String)
  BytesData(BytesTree)
  BitsData(BitArray)
  StringTreeData(StringTree)
  File(descriptor: file.IoDevice, offset: Int, size: Int)
  Chunked
  Websocket
  SSE
  Empty
}

/// Appends default headers to HTTP responses.
///
pub fn append_default_headers(
  resp: Response(a),
  req: Request(Connection),
  version: HttpVersion,
) -> Response(a) {
  let set_close = request.get_header(req, "connection") == Ok("close")

  let resp = case response.get_header(resp, "date") {
    Ok(_) -> resp
    Error(Nil) -> response.set_header(resp, "date", clock.get_http_date())
  }

  case version, set_close {
    Http10, _ -> response.set_header(resp, "connection", "close")
    _, True -> response.set_header(resp, "connection", "close")
    Http11, False ->
      case response.get_header(resp, "connection") {
        Ok(_) -> resp
        Error(Nil) -> response.set_header(resp, "connection", "keep-alive")
      }
  }
}

/// Sets the content length header if it is not already set.
///
pub fn set_content_length(resp: Response(BitArray)) -> Response(BitArray) {
  case response.get_header(resp, "content-length") {
    Ok(_) -> resp
    Error(Nil) -> {
      let body_size = bit_array.byte_size(resp.body) |> int.to_string
      response.set_header(resp, "content-length", body_size)
    }
  }
}

/// Handles 100-continue expectations.
///
pub fn handle_continue(req: Request(Connection)) -> Result(Nil, ParseError) {
  let expect =
    req.headers
    |> list.find(fn(tupple) {
      tupple.0 == "expect" && string.lowercase(tupple.1) == "100-continue"
    })

  case expect {
    Ok(_) -> {
      response.new(100)
      |> response.set_body(<<>>)
      |> encoder.encode_response()
      |> transport.send(req.body.transport, req.body.socket, _)
      |> result.replace_error(MalformedRequest)
    }
    Error(Nil) -> Ok(Nil)
  }
}
