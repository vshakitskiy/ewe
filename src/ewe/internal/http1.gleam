import ewe/internal/clock
import ewe/internal/connection
import ewe/internal/file
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import glisten
import glisten/internal/handler
import glisten/transport
import logging

pub type State {
  State(
    handler: fn(request.Request(connection.Connection)) ->
      response.Response(connection.Body),
    buffer: BitArray,
    idle_timer: option.Option(process.Timer),
  )
}

pub const idle_timeout = 10_000

pub type Next {
  Continue(State)
  Close
}

pub fn handle_message(
  state: State,
  connection: glisten.Connection(connection.Message),
) -> Next {
  case state.idle_timer {
    option.Some(timer) -> process.cancel_timer(timer)
    option.None -> process.TimerNotFound
  }

  case parse(state.buffer) {
    Ok(Complete(head, metadata, remaining)) -> {
      let scheme = case connection.transport {
        transport.Tcp -> http.Http
        transport.Ssl -> http.Https
      }

      let request =
        request.Request(
          method: head.method,
          headers: head.headers,
          body: connection.Http1(
            transport: connection.transport,
            socket: connection.socket,
            self: connection.subject,
            buffer: remaining,
          ),
          scheme:,
          host: head.host,
          port: head.port,
          path: head.path,
          query: head.query,
        )

      let response = state.handler(request)

      let sent = case encode_response(response, head.method, metadata) {
        Ok(Encoded(bytes:, keep_alive:, file: file_body)) -> {
          use Nil <- result.try(transport.send(
            connection.transport,
            connection.socket,
            bytes,
          ))

          case file_body {
            option.None -> Ok(keep_alive)
            option.Some(data) ->
              case file.send(connection.transport, connection.socket, data) {
                Ok(Nil) -> Ok(keep_alive)
                Error(reason) -> Error(reason)
              }
          }
        }
        Error(UnsafeHeader(name)) -> {
          logging.log(
            logging.Error,
            "Handler produced an unsafe response header: " <> name,
          )

          use Nil <- result.try(transport.send(
            connection.transport,
            connection.socket,
            internal_server_error(),
          ))

          Ok(False)
        }
      }

      case sent {
        Ok(True) -> {
          let timer =
            process.send_after(
              connection.subject,
              idle_timeout,
              handler.User(connection.Timeout),
            )

          State(..state, buffer: remaining, idle_timer: option.Some(timer))
          |> Continue
        }
        Ok(False) -> Close
        Error(_reason) -> Close
      }
    }
    Ok(Incomplete) -> {
      let timer =
        process.send_after(
          connection.subject,
          idle_timeout,
          handler.User(connection.Timeout),
        )

      Continue(State(..state, idle_timer: option.Some(timer)))
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "Failed to parse HTTP/1.x request: " <> error_to_string(error),
      )

      Close
    }
  }
}

/// Errors that can occur while turning a handler's `response.Response` into 
/// wire bytes.
pub type EncodeError {
  /// A header name or value contained a CR, LF, or NUL byte, which would let 
  /// it inject a new header or terminate the header block early.
  UnsafeHeader(name: String)
}

// Threaded through the pass over `response.headers` with the tree built so far 
// and whether the handler's own `connection` header asked to close.
type EncodeState {
  EncodeState(tree: bytes_tree.BytesTree, force_close: Bool)
}

fn initial_encode_state() -> EncodeState {
  EncodeState(tree: bytes_tree.new(), force_close: False)
}

/// The result of encoding a response: `bytes` is ready for a single
/// `transport.send`, and `file`, when present, still needs to be streamed
/// separately since it was never loaded into `bytes`.
pub type Encoded {
  Encoded(
    bytes: bytes_tree.BytesTree,
    keep_alive: Bool,
    file: option.Option(connection.File),
  )
}

/// Builds the response as a `BytesTree`. `Bytes`, `Text` and `Empty` bodies
/// are folded straight into it, so the whole response goes out in a single
/// `transport.send`.
pub fn encode_response(
  response: response.Response(connection.Body),
  method: http.Method,
  metadata: Metadata,
) -> Result(Encoded, EncodeError) {
  use state <- result.try(encode_headers(response.headers))
  let length = body_length(response.body)
  let keep_alive = metadata.keep_alive && !state.force_close

  let head =
    state.tree
    |> append_date()
    |> append_connection(keep_alive)
    |> bytes_tree.prepend(status_line(response.status))
    |> bytes_tree.append_string("content-length: " <> int.to_string(length))
    |> bytes_tree.append(<<"\r\n\r\n":utf8>>)

  case method, response.body {
    http.Head, _body -> Ok(Encoded(head, keep_alive, option.None))
    _method, connection.File(data) ->
      Ok(Encoded(head, keep_alive, option.Some(data)))
    _method, connection.Bytes(tree) ->
      Ok(Encoded(bytes_tree.append_tree(head, tree), keep_alive, option.None))
    _method, connection.Text(text) ->
      Ok(Encoded(bytes_tree.append_string(head, text), keep_alive, option.None))
    _method, connection.Empty -> Ok(Encoded(head, keep_alive, option.None))
  }
}

// Builds the header block.
fn encode_headers(
  headers: List(#(String, String)),
) -> Result(EncodeState, EncodeError) {
  use state, #(name, value) <- list.try_fold(headers, initial_encode_state())
  case name {
    "content-length" | "transfer-encoding" | "date" -> Ok(state)
    "connection" ->
      case find_unsafe_header_byte(value) {
        Error(Nil) -> {
          let lowered = value |> bit_array.from_string |> lowercase_ascii
          let force_close =
            state.force_close || has_token(lowered, <<"close":utf8>>)
          Ok(EncodeState(..state, force_close:))
        }
        Ok(_position) -> Error(UnsafeHeader(name))
      }
    _name ->
      case find_unsafe_header_byte(name), find_unsafe_header_byte(value) {
        Error(Nil), Error(Nil) -> {
          let tree =
            bytes_tree.append_string(state.tree, name)
            |> bytes_tree.append(<<": ":utf8>>)
            |> bytes_tree.append_string(value)
            |> bytes_tree.append(<<"\r\n":utf8>>)

          Ok(EncodeState(..state, tree:))
        }
        _other, _other -> Error(UnsafeHeader(name))
      }
  }
}

// Fills in `Date` from the shared clock (RFC 9110 §6.6.1). The clock actor 
// refreshes the cached value once a second.
fn append_date(tree: bytes_tree.BytesTree) -> bytes_tree.BytesTree {
  bytes_tree.append_string(tree, "date: ")
  |> bytes_tree.append(clock.get())
  |> bytes_tree.append(<<"\r\n":utf8>>)
}

fn append_connection(
  tree: bytes_tree.BytesTree,
  keep_alive: Bool,
) -> bytes_tree.BytesTree {
  let value = case keep_alive {
    True -> <<"keep-alive":utf8>>
    False -> <<"close":utf8>>
  }

  bytes_tree.append(tree, <<"connection: ":utf8>>)
  |> bytes_tree.append(value)
  |> bytes_tree.append(<<"\r\n":utf8>>)
}

// Precomputed `HTTP/1.1 NNN Reason\r\n` literals for every standard status 
// code. Codes with no registered meaning in this range fall through to the 
// general form with an empty reason phrase.
fn status_line(status: Int) -> BitArray {
  case status {
    100 -> <<"HTTP/1.1 100 Continue\r\n":utf8>>
    101 -> <<"HTTP/1.1 101 Switching Protocols\r\n":utf8>>
    102 -> <<"HTTP/1.1 102 Processing\r\n":utf8>>
    103 -> <<"HTTP/1.1 103 Early Hints\r\n":utf8>>
    200 -> <<"HTTP/1.1 200 OK\r\n":utf8>>
    201 -> <<"HTTP/1.1 201 Created\r\n":utf8>>
    202 -> <<"HTTP/1.1 202 Accepted\r\n":utf8>>
    203 -> <<"HTTP/1.1 203 Non-Authoritative Information\r\n":utf8>>
    204 -> <<"HTTP/1.1 204 No Content\r\n":utf8>>
    205 -> <<"HTTP/1.1 205 Reset Content\r\n":utf8>>
    206 -> <<"HTTP/1.1 206 Partial Content\r\n":utf8>>
    207 -> <<"HTTP/1.1 207 Multi-Status\r\n":utf8>>
    208 -> <<"HTTP/1.1 208 Already Reported\r\n":utf8>>
    226 -> <<"HTTP/1.1 226 IM Used\r\n":utf8>>
    300 -> <<"HTTP/1.1 300 Multiple Choices\r\n":utf8>>
    301 -> <<"HTTP/1.1 301 Moved Permanently\r\n":utf8>>
    302 -> <<"HTTP/1.1 302 Found\r\n":utf8>>
    303 -> <<"HTTP/1.1 303 See Other\r\n":utf8>>
    304 -> <<"HTTP/1.1 304 Not Modified\r\n":utf8>>
    305 -> <<"HTTP/1.1 305 Use Proxy\r\n":utf8>>
    307 -> <<"HTTP/1.1 307 Temporary Redirect\r\n":utf8>>
    308 -> <<"HTTP/1.1 308 Permanent Redirect\r\n":utf8>>
    400 -> <<"HTTP/1.1 400 Bad Request\r\n":utf8>>
    401 -> <<"HTTP/1.1 401 Unauthorized\r\n":utf8>>
    402 -> <<"HTTP/1.1 402 Payment Required\r\n":utf8>>
    403 -> <<"HTTP/1.1 403 Forbidden\r\n":utf8>>
    404 -> <<"HTTP/1.1 404 Not Found\r\n":utf8>>
    405 -> <<"HTTP/1.1 405 Method Not Allowed\r\n":utf8>>
    406 -> <<"HTTP/1.1 406 Not Acceptable\r\n":utf8>>
    407 -> <<"HTTP/1.1 407 Proxy Authentication Required\r\n":utf8>>
    408 -> <<"HTTP/1.1 408 Request Timeout\r\n":utf8>>
    409 -> <<"HTTP/1.1 409 Conflict\r\n":utf8>>
    410 -> <<"HTTP/1.1 410 Gone\r\n":utf8>>
    411 -> <<"HTTP/1.1 411 Length Required\r\n":utf8>>
    412 -> <<"HTTP/1.1 412 Precondition Failed\r\n":utf8>>
    413 -> <<"HTTP/1.1 413 Content Too Large\r\n":utf8>>
    414 -> <<"HTTP/1.1 414 URI Too Long\r\n":utf8>>
    415 -> <<"HTTP/1.1 415 Unsupported Media Type\r\n":utf8>>
    416 -> <<"HTTP/1.1 416 Range Not Satisfiable\r\n":utf8>>
    417 -> <<"HTTP/1.1 417 Expectation Failed\r\n":utf8>>
    418 -> <<"HTTP/1.1 418 I'm a Teapot\r\n":utf8>>
    421 -> <<"HTTP/1.1 421 Misdirected Request\r\n":utf8>>
    422 -> <<"HTTP/1.1 422 Unprocessable Content\r\n":utf8>>
    423 -> <<"HTTP/1.1 423 Locked\r\n":utf8>>
    424 -> <<"HTTP/1.1 424 Failed Dependency\r\n":utf8>>
    425 -> <<"HTTP/1.1 425 Too Early\r\n":utf8>>
    426 -> <<"HTTP/1.1 426 Upgrade Required\r\n":utf8>>
    428 -> <<"HTTP/1.1 428 Precondition Required\r\n":utf8>>
    429 -> <<"HTTP/1.1 429 Too Many Requests\r\n":utf8>>
    431 -> <<"HTTP/1.1 431 Request Header Fields Too Large\r\n":utf8>>
    451 -> <<"HTTP/1.1 451 Unavailable For Legal Reasons\r\n":utf8>>
    500 -> <<"HTTP/1.1 500 Internal Server Error\r\n":utf8>>
    501 -> <<"HTTP/1.1 501 Not Implemented\r\n":utf8>>
    502 -> <<"HTTP/1.1 502 Bad Gateway\r\n":utf8>>
    503 -> <<"HTTP/1.1 503 Service Unavailable\r\n":utf8>>
    504 -> <<"HTTP/1.1 504 Gateway Timeout\r\n":utf8>>
    505 -> <<"HTTP/1.1 505 HTTP Version Not Supported\r\n":utf8>>
    506 -> <<"HTTP/1.1 506 Variant Also Negotiates\r\n":utf8>>
    507 -> <<"HTTP/1.1 507 Insufficient Storage\r\n":utf8>>
    508 -> <<"HTTP/1.1 508 Loop Detected\r\n":utf8>>
    510 -> <<"HTTP/1.1 510 Not Extended\r\n":utf8>>
    511 -> <<"HTTP/1.1 511 Network Authentication Required\r\n":utf8>>
    _other -> <<"HTTP/1.1 ":utf8, int.to_string(status):utf8, " \r\n":utf8>>
  }
}

fn body_length(body: connection.Body) -> Int {
  case body {
    connection.Bytes(tree) -> bytes_tree.byte_size(tree)
    connection.Text(text) -> string.byte_size(text)
    connection.Empty -> 0
    connection.File(data) -> data.length
  }
}

fn internal_server_error() -> bytes_tree.BytesTree {
  bytes_tree.new()
  |> bytes_tree.append(<<
    "HTTP/1.1 500 Internal Server Error\r\ndate: ":utf8,
  >>)
  |> bytes_tree.append(clock.get())
  |> bytes_tree.append(<<
    "\r\nconnection: close\r\ncontent-length: 0\r\n\r\n":utf8,
  >>)
}

pub type Version {
  Http10
  Http11
}

/// The parsed request line and headers. Does not include the body. Carries
/// everything `request.Request` needs besides `scheme` and `body`, which
/// only the caller can supply.
pub type Head {
  Head(
    method: http.Method,
    host: String,
    port: option.Option(Int),
    path: String,
    query: option.Option(String),
    version: Version,
    headers: List(#(String, String)),
  )
}

/// Cheap conclusions drawn from `Head.headers` in one pass.
pub type Metadata {
  Metadata(
    content_length: option.Option(Int),
    chunked: Bool,
    keep_alive: Bool,
    upgrade: option.Option(String),
  )
}

pub type ParseError {
  RequestLineTooLong
  BadRequestLine
  BadMethod
  BadTarget
  BadVersion
  HeaderLineTooLong
  BadHeader
  TooManyHeaders
  DuplicateContentLength
  BadContentLength
  DuplicateHost
  BadHost
  MissingHost
  AmbiguousFraming
}

pub fn error_to_string(error: ParseError) -> String {
  case error {
    RequestLineTooLong ->
      "request line exceeds " <> int.to_string(max_request_line) <> " bytes"
    BadRequestLine -> "malformed request line"
    BadMethod -> "invalid request method"
    BadTarget -> "invalid request target"
    BadVersion -> "unsupported or malformed HTTP version"
    HeaderLineTooLong ->
      "header line exceeds " <> int.to_string(max_header_line) <> " bytes"
    BadHeader -> "malformed header line"
    TooManyHeaders ->
      "too many headers (max " <> int.to_string(max_headers) <> ")"
    DuplicateContentLength -> "duplicate Content-Length header"
    BadContentLength -> "invalid Content-Length value"
    DuplicateHost -> "duplicate Host header"
    BadHost -> "invalid Host header"
    MissingHost -> "missing required Host header"
    AmbiguousFraming ->
      "conflicting Content-Length and Transfer-Encoding headers"
  }
}

pub type Parsed {
  Complete(head: Head, metadata: Metadata, remaining: BitArray)
  Incomplete
}

const max_request_line = 8192

const max_header_line = 8192

const max_headers = 100

/// Parses as much of a request head as `buffer` contains.
pub fn parse(buffer: BitArray) -> Result(Parsed, ParseError) {
  let step = {
    use #(method, target, version, remaining) <- try_step(parse_request_line(
      buffer,
    ))

    use #(headers, state, remaining) <- try_step(parse_headers(
      remaining,
      [],
      0,
      initial_header_state(),
    ))

    use #(host, port, path, query) <- try_step(resolve_target(
      method,
      target,
      version,
      state.host,
    ))

    use metadata <- try_step(resolve_metadata(state, version))

    Done(Complete(
      Head(method:, host:, port:, path:, query:, version:, headers:),
      metadata,
      remaining,
    ))
  }

  case step {
    Done(parsed) -> Ok(parsed)
    More -> Ok(Incomplete)
    ParseError(error) -> Error(error)
  }
}

type Step(a) {
  Done(a)
  More
  ParseError(ParseError)
}

fn try_step(step: Step(a), next: fn(a) -> Step(b)) -> Step(b) {
  case step {
    Done(value) -> next(value)
    More -> More
    ParseError(error) -> ParseError(error)
  }
}

fn parse_request_line(
  buffer: BitArray,
) -> Step(#(http.Method, BitArray, Version, BitArray)) {
  use #(line, remaining) <- try_step(extract_line(
    buffer,
    max_request_line,
    RequestLineTooLong,
    BadRequestLine,
  ))

  use #(method, target_and_version) <- try_step(parse_method(line))

  use #(target, version) <- try_step(parse_target_version(target_and_version))

  Done(#(method, target, version, remaining))
}

fn parse_method(line: BitArray) -> Step(#(http.Method, BitArray)) {
  case line {
    <<"GET ":utf8, remaining:bits>> -> Done(#(http.Get, remaining))
    <<"POST ":utf8, remaining:bits>> -> Done(#(http.Post, remaining))
    <<"PUT ":utf8, remaining:bits>> -> Done(#(http.Put, remaining))
    <<"DELETE ":utf8, remaining:bits>> -> Done(#(http.Delete, remaining))
    <<"HEAD ":utf8, remaining:bits>> -> Done(#(http.Head, remaining))
    <<"OPTIONS ":utf8, remaining:bits>> -> Done(#(http.Options, remaining))
    <<"PATCH ":utf8, remaining:bits>> -> Done(#(http.Patch, remaining))
    <<"TRACE ":utf8, remaining:bits>> -> Done(#(http.Trace, remaining))
    <<"CONNECT ":utf8, remaining:bits>> -> Done(#(http.Connect, remaining))
    _other -> parse_other_method(line)
  }
}

fn parse_other_method(line: BitArray) -> Step(#(http.Method, BitArray)) {
  case find_space(line) {
    Error(Nil) -> ParseError(BadRequestLine)
    Ok(position) ->
      case line {
        <<name:bytes-size(position), " ":utf8, remaining:bits>> ->
          case bit_array_to_string(name) {
            Error(Nil) -> ParseError(BadMethod)
            Ok(name) ->
              case http.parse_method(name) {
                Ok(method) -> Done(#(method, remaining))
                Error(Nil) -> ParseError(BadMethod)
              }
          }
        _line -> ParseError(BadRequestLine)
      }
  }
}

fn parse_target_version(bits: BitArray) -> Step(#(BitArray, Version)) {
  let size = bit_array.byte_size(bits)

  case size < 10 {
    True -> ParseError(BadRequestLine)
    False -> {
      let target_size = size - 9
      case bits {
        <<target:bytes-size(target_size), " HTTP/1.1":utf8>> ->
          Done(#(target, Http11))
        <<target:bytes-size(target_size), " HTTP/1.0":utf8>> ->
          Done(#(target, Http10))
        _bits -> ParseError(BadVersion)
      }
    }
  }
}

// path[?query]. Used for every method except CONNECT.
fn split_target(target: BitArray) -> Step(#(String, option.Option(String))) {
  case find_question(target) {
    Error(Nil) -> {
      use path <- try_step(decode_component(target, BadTarget))
      Done(#(path, option.None))
    }
    Ok(position) -> {
      let size = bit_array.byte_size(target)

      case target {
        <<
          path:bytes-size(position),
          "?":utf8,
          query:bytes-size(size - position - 1),
        >> -> {
          use path <- try_step(decode_component(path, BadTarget))
          use query <- try_step(decode_component(query, BadTarget))
          Done(#(path, option.Some(query)))
        }
        _target -> ParseError(BadTarget)
      }
    }
  }
}

fn decode_component(bits: BitArray, on_error: ParseError) -> Step(String) {
  case bit_array_to_string(bits) {
    Ok(value) -> Done(value)
    Error(Nil) -> ParseError(on_error)
  }
}

// A path must be an absolute path except the "*" asterisk-form, which is only
// valid for OPTIONS (RFC 9112 §3.2).
fn validate_path(method: http.Method, path: String) -> Step(String) {
  case path, method {
    "*", http.Options -> Done(path)
    "/" <> _remaining, _method -> Done(path)
    _path, _method -> ParseError(BadTarget)
  }
}

// CONNECT's target is authority-form, every other method uses origin-form and
// gets its host from the Host header.
fn resolve_target(
  method: http.Method,
  target: BitArray,
  version: Version,
  header_host: option.Option(#(String, option.Option(Int))),
) -> Step(#(String, option.Option(Int), String, option.Option(String))) {
  case method {
    http.Connect ->
      // `target` is unvalidated wire bytes, so the host must go through real 
      // UTF-8 validation here.
      case split_host_port(target) {
        Ok(#(host, option.Some(_port) as port)) ->
          case bit_array_to_string(host) {
            Ok(host) -> Done(#(host, port, "", option.None))
            Error(Nil) -> ParseError(BadTarget)
          }
        Ok(#(_host, option.None)) -> ParseError(BadTarget)
        Error(Nil) -> ParseError(BadTarget)
      }
    _method -> {
      use #(path, query) <- try_step(split_target(target))
      use path <- try_step(validate_path(method, path))
      use #(host, port) <- try_step(resolve_host(version, header_host))
      Done(#(host, port, path, query))
    }
  }
}

// The `Host` header is required for HTTP/1.1 (RFC 9112 §3.2), optional for
// HTTP/1.0.
fn resolve_host(
  version: Version,
  header_host: option.Option(#(String, option.Option(Int))),
) -> Step(#(String, option.Option(Int))) {
  case header_host, version {
    option.Some(host_port), _version -> Done(host_port)
    option.None, Http10 -> Done(#("", option.None))
    option.None, Http11 -> ParseError(MissingHost)
  }
}

// Splits a `host[:port]` authority, respecting IPv6 literals in brackets.
// Returns the host as raw bytes, callers decide how to turn it into a
// `String`, since one of them already knows the bytes are valid UTF-8 and 
// the other doesn't.
fn split_host_port(
  value: BitArray,
) -> Result(#(BitArray, option.Option(Int)), Nil) {
  case value {
    <<"[":utf8, _remaining:bits>> -> split_bracketed_host(value)
    _value ->
      case find_colon(value) {
        Error(Nil) -> Ok(#(value, option.None))
        Ok(position) -> {
          let size = bit_array.byte_size(value)
          case value {
            <<
              host:bytes-size(position),
              ":":utf8,
              port:bytes-size(size - position - 1),
            >> ->
              case parse_port(port) {
                Ok(port) -> Ok(#(host, option.Some(port)))
                Error(Nil) -> Error(Nil)
              }
            _value -> Error(Nil)
          }
        }
      }
  }
}

fn split_bracketed_host(
  value: BitArray,
) -> Result(#(BitArray, option.Option(Int)), Nil) {
  case find_close_bracket(value) {
    Error(Nil) -> Error(Nil)
    Ok(position) -> {
      let size = bit_array.byte_size(value)

      case value {
        <<
          host:bytes-size(position + 1),
          remaining:bytes-size(size - position - 1),
        >> ->
          case remaining {
            <<>> -> Ok(#(host, option.None))
            <<":":utf8, port:bits>> ->
              case parse_port(port) {
                Ok(port) -> Ok(#(host, option.Some(port)))
                Error(Nil) -> Error(Nil)
              }
            _remaining -> Error(Nil)
          }
        _value -> Error(Nil)
      }
    }
  }
}

fn parse_port(bits: BitArray) -> Result(Int, Nil) {
  case bits {
    <<>> -> Error(Nil)
    _bits -> parse_port_digits(bits, 0)
  }
}

fn parse_port_digits(bits: BitArray, acc: Int) -> Result(Int, Nil) {
  case bits {
    <<>> ->
      case acc <= 65_535 {
        True -> Ok(acc)
        False -> Error(Nil)
      }
    <<byte, remaining:bits>> if byte >= 48 && byte <= 57 ->
      parse_port_digits(remaining, acc * 10 + { byte - 48 })
    _bits -> Error(Nil)
  }
}

// Threaded through `parse_headers`. 
type HeaderState {
  HeaderState(
    content_length: option.Option(Int),
    chunked: Bool,
    connection: option.Option(Bool),
    connection_upgrade: Bool,
    upgrade: option.Option(String),
    host: option.Option(#(String, option.Option(Int))),
  )
}

fn initial_header_state() -> HeaderState {
  HeaderState(
    content_length: option.None,
    chunked: False,
    connection: option.None,
    connection_upgrade: False,
    upgrade: option.None,
    host: option.None,
  )
}

// HTTP/1.1 connections default to persistent, HTTP/1.0 ones default to
// closing (RFC 9112 §9.3); an explicit `Connection` header overrides
// either default. A message framed by both `Content-Length` and
// `Transfer-Encoding` is rejected outright, since the two disagree on
// where the body ends. (RFC 9112 §6.1).
fn resolve_metadata(state: HeaderState, version: Version) -> Step(Metadata) {
  case state.content_length, state.chunked {
    option.Some(_length), True -> ParseError(AmbiguousFraming)
    content_length, chunked -> {
      let keep_alive = case state.connection, version {
        option.Some(keep_alive), _version -> keep_alive
        option.None, Http11 -> True
        option.None, Http10 -> False
      }
      let upgrade = case state.connection_upgrade {
        True -> state.upgrade
        False -> option.None
      }
      Done(Metadata(content_length:, chunked:, keep_alive:, upgrade:))
    }
  }
}

fn parse_headers(
  buffer: BitArray,
  acc: List(#(String, String)),
  count: Int,
  state: HeaderState,
) -> Step(#(List(#(String, String)), HeaderState, BitArray)) {
  use #(line, remaining) <- try_step(extract_line(
    buffer,
    max_header_line,
    HeaderLineTooLong,
    BadHeader,
  ))

  case line {
    <<>> -> Done(#(list.reverse(acc), state, remaining))
    _line if count >= max_headers -> ParseError(TooManyHeaders)
    _line -> {
      use #(header, state) <- try_step(parse_header_line(line, state))
      parse_headers(remaining, [header, ..acc], count + 1, state)
    }
  }
}

fn parse_header_line(
  line: BitArray,
  state: HeaderState,
) -> Step(#(#(String, String), HeaderState)) {
  case find_colon(line) {
    Error(Nil) -> ParseError(BadHeader)
    Ok(0) -> ParseError(BadHeader)
    Ok(position) ->
      case line {
        <<name:bytes-size(position), ":":utf8, value:bits>> -> {
          let name = lowercase_ascii(name)
          let value = trim_ows(value)
          case bit_array_to_string(name), bit_array_to_string(value) {
            Ok(name), Ok(value) -> {
              use state <- try_step(classify(name, value, state))
              Done(#(#(name, value), state))
            }
            _other, _other -> ParseError(BadHeader)
          }
        }
        _bad -> ParseError(BadHeader)
      }
  }
}

// Updates `content_length`, `chunked`, `connection`, `connection_upgrade`,
// `upgrade`, and `host` from a single already decoded header.
fn classify(
  name: String,
  value: String,
  state: HeaderState,
) -> Step(HeaderState) {
  case name {
    "content-length" ->
      case state.content_length {
        option.Some(_length) -> ParseError(DuplicateContentLength)
        option.None ->
          case int.parse(value) {
            Ok(length) if length >= 0 ->
              Done(HeaderState(..state, content_length: option.Some(length)))
            _bad -> ParseError(BadContentLength)
          }
      }
    "transfer-encoding" -> {
      let lowered = value |> bit_array.from_string |> lowercase_ascii
      let chunked = state.chunked || has_token(lowered, <<"chunked":utf8>>)
      Done(HeaderState(..state, chunked:))
    }
    "connection" -> {
      let lowered = value |> bit_array.from_string |> lowercase_ascii
      let connection = case has_token(lowered, <<"close":utf8>>) {
        True -> option.Some(False)
        False ->
          case has_token(lowered, <<"keep-alive":utf8>>) {
            True -> option.Some(True)
            False -> state.connection
          }
      }
      let connection_upgrade =
        state.connection_upgrade || has_token(lowered, <<"upgrade":utf8>>)
      Done(HeaderState(..state, connection:, connection_upgrade:))
    }
    "upgrade" -> {
      // ASCII-lowered bytes of a validated `String` are valid UTF-8.
      let lowered =
        value
        |> bit_array.from_string
        |> lowercase_ascii
        |> unsafe_to_string
      Done(HeaderState(..state, upgrade: option.Some(lowered)))
    }
    "host" ->
      case state.host {
        option.Some(_host) -> ParseError(DuplicateHost)
        option.None ->
          // `value` is already a validated `String`. The split only slices
          // at ASCII delimiters, so the host bytes are still valid UTF-8
          // and don't need re-validating.
          case split_host_port(bit_array.from_string(value)) {
            Ok(#(host, port)) -> {
              let host = option.Some(#(unsafe_to_string(host), port))
              Done(HeaderState(..state, host:))
            }
            Error(Nil) -> ParseError(BadHost)
          }
      }
    _other -> Done(state)
  }
}

// Finds the next LF, then splits off the line without CRLF and the remaining.
fn extract_line(
  buffer: BitArray,
  max_len: Int,
  too_long: ParseError,
  malformed: ParseError,
) -> Step(#(BitArray, BitArray)) {
  case find_lf(buffer) {
    Error(Nil) ->
      case bit_array.byte_size(buffer) > max_len {
        True -> ParseError(too_long)
        False -> More
      }
    Ok(0) -> ParseError(malformed)
    Ok(position) ->
      case buffer {
        <<line:bytes-size(position - 1), "\r\n":utf8, remaining:bits>> ->
          Done(#(line, remaining))
        _bad -> ParseError(malformed)
      }
  }
}

// Returns input untouched if already lowercase, avoiding an allocation.
fn lowercase_ascii(bits: BitArray) -> BitArray {
  case has_uppercase(bits) {
    False -> bits
    True -> lowercase_walk(bits) |> list_to_bit_array
  }
}

fn has_uppercase(bits: BitArray) -> Bool {
  case bits {
    <<>> -> False
    <<byte, _remaining:bits>> if byte >= 65 && byte <= 90 -> True
    <<_byte, remaining:bits>> -> has_uppercase(remaining)
    _other -> False
  }
}

// Builds a byte list, lowercasing letters. Flattened by `list_to_bit_array`.
fn lowercase_walk(bits: BitArray) -> List(Int) {
  case bits {
    <<>> -> []
    <<"A", remaining:bits>> -> [0x61, ..lowercase_walk(remaining)]
    <<"B", remaining:bits>> -> [0x62, ..lowercase_walk(remaining)]
    <<"C", remaining:bits>> -> [0x63, ..lowercase_walk(remaining)]
    <<"D", remaining:bits>> -> [0x64, ..lowercase_walk(remaining)]
    <<"E", remaining:bits>> -> [0x65, ..lowercase_walk(remaining)]
    <<"F", remaining:bits>> -> [0x66, ..lowercase_walk(remaining)]
    <<"G", remaining:bits>> -> [0x67, ..lowercase_walk(remaining)]
    <<"H", remaining:bits>> -> [0x68, ..lowercase_walk(remaining)]
    <<"I", remaining:bits>> -> [0x69, ..lowercase_walk(remaining)]
    <<"J", remaining:bits>> -> [0x6A, ..lowercase_walk(remaining)]
    <<"K", remaining:bits>> -> [0x6B, ..lowercase_walk(remaining)]
    <<"L", remaining:bits>> -> [0x6C, ..lowercase_walk(remaining)]
    <<"M", remaining:bits>> -> [0x6D, ..lowercase_walk(remaining)]
    <<"N", remaining:bits>> -> [0x6E, ..lowercase_walk(remaining)]
    <<"O", remaining:bits>> -> [0x6F, ..lowercase_walk(remaining)]
    <<"P", remaining:bits>> -> [0x70, ..lowercase_walk(remaining)]
    <<"Q", remaining:bits>> -> [0x71, ..lowercase_walk(remaining)]
    <<"R", remaining:bits>> -> [0x72, ..lowercase_walk(remaining)]
    <<"S", remaining:bits>> -> [0x73, ..lowercase_walk(remaining)]
    <<"T", remaining:bits>> -> [0x74, ..lowercase_walk(remaining)]
    <<"U", remaining:bits>> -> [0x75, ..lowercase_walk(remaining)]
    <<"V", remaining:bits>> -> [0x76, ..lowercase_walk(remaining)]
    <<"W", remaining:bits>> -> [0x77, ..lowercase_walk(remaining)]
    <<"X", remaining:bits>> -> [0x78, ..lowercase_walk(remaining)]
    <<"Y", remaining:bits>> -> [0x79, ..lowercase_walk(remaining)]
    <<"Z", remaining:bits>> -> [0x7A, ..lowercase_walk(remaining)]
    <<byte, remaining:bits>> -> [byte, ..lowercase_walk(remaining)]
    _other -> []
  }
}

// ASCII-only OWS trim.
fn trim_ows(bits: BitArray) -> BitArray {
  bits
  |> trim_leading_ows
  |> trim_trailing_ows
}

fn trim_leading_ows(bits: BitArray) -> BitArray {
  case bits {
    <<" ", remaining:bits>> -> trim_leading_ows(remaining)
    <<"\t", remaining:bits>> -> trim_leading_ows(remaining)
    _bits -> bits
  }
}

fn trim_trailing_ows(bits: BitArray) -> BitArray {
  case bit_array.byte_size(bits) {
    0 -> bits
    size ->
      case bits {
        <<init:bytes-size(size - 1), " ":utf8>> -> trim_trailing_ows(init)
        <<init:bytes-size(size - 1), "\t":utf8>> -> trim_trailing_ows(init)
        _bits -> bits
      }
  }
}

// Exact-token match against a comma-separated header value.
fn has_token(value: BitArray, token: BitArray) -> Bool {
  case value == token {
    True -> True
    False ->
      split_comma(value)
      |> list.any(fn(part) { trim_ows(part) == token })
  }
}

@external(erlang, "http1_ffi", "find_lf")
fn find_lf(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "http1_ffi", "find_colon")
fn find_colon(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "http1_ffi", "find_space")
fn find_space(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "http1_ffi", "find_question")
fn find_question(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "http1_ffi", "find_close_bracket")
fn find_close_bracket(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "http1_ffi", "find_unsafe_header_byte")
fn find_unsafe_header_byte(bits: String) -> Result(Int, Nil)

@external(erlang, "http1_ffi", "split_comma")
fn split_comma(bits: BitArray) -> List(BitArray)

@external(erlang, "http1_ffi", "list_to_bit_array")
fn list_to_bit_array(bytes: List(Int)) -> BitArray

// Validates UTF-8 via native BIFs, I assume should be faster than
// `bit_array.to_string`.
@external(erlang, "http1_ffi", "bit_array_to_string")
fn bit_array_to_string(bits: BitArray) -> Result(String, Nil)

// Used only for bytes already proven valid UTF-8 elsewhere!!
@external(erlang, "gleam_stdlib", "identity")
fn unsafe_to_string(bits: BitArray) -> String
