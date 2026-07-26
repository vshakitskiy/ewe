import ewe/internal/http1/connection as http1
import gleam/bit_array
import gleam/http
import gleam/int
import gleam/list
import gleam/option

pub type Version {
  Http10
  Http11
}

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

pub type Metadata {
  Metadata(
    framing: http1.Framing,
    keep_alive: http1.KeepAlive,
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
  ChunkSizeLineTooLong
  BadChunkSize
  BadChunkFraming
  ChunkTooLarge
  BodyReadFailed
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
    ChunkSizeLineTooLong ->
      "chunk size line exceeds "
      <> int.to_string(max_chunk_size_line)
      <> " bytes"
    BadChunkSize -> "malformed chunk size"
    BadChunkFraming -> "malformed chunk data framing"
    ChunkTooLarge -> "chunked body exceeds size limit"
    BodyReadFailed -> "failed to read request body from the socket"
  }
}

pub type Parsed {
  Complete(head: Head, metadata: Metadata, remaining: BitArray)
  Incomplete
}

const max_request_line = 8192

const max_header_line = 8192

const max_headers = 100

pub const max_chunk_size_line = 128

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

    StepDone(Complete(
      Head(method:, host:, port:, path:, query:, version:, headers:),
      metadata,
      remaining,
    ))
  }

  case step {
    StepDone(parsed) -> Ok(parsed)
    More -> Ok(Incomplete)
    ParseError(error) -> Error(error)
  }
}

pub type Step(a) {
  StepDone(a)
  More
  ParseError(ParseError)
}

pub fn try_step(step: Step(a), next: fn(a) -> Step(b)) -> Step(b) {
  case step {
    StepDone(value) -> next(value)
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

  StepDone(#(method, target, version, remaining))
}

fn parse_method(line: BitArray) -> Step(#(http.Method, BitArray)) {
  case line {
    <<"GET ":utf8, remaining:bits>> -> StepDone(#(http.Get, remaining))
    <<"POST ":utf8, remaining:bits>> -> StepDone(#(http.Post, remaining))
    <<"PUT ":utf8, remaining:bits>> -> StepDone(#(http.Put, remaining))
    <<"DELETE ":utf8, remaining:bits>> -> StepDone(#(http.Delete, remaining))
    <<"HEAD ":utf8, remaining:bits>> -> StepDone(#(http.Head, remaining))
    <<"OPTIONS ":utf8, remaining:bits>> -> StepDone(#(http.Options, remaining))
    <<"PATCH ":utf8, remaining:bits>> -> StepDone(#(http.Patch, remaining))
    <<"TRACE ":utf8, remaining:bits>> -> StepDone(#(http.Trace, remaining))
    <<"CONNECT ":utf8, remaining:bits>> -> StepDone(#(http.Connect, remaining))
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
                Ok(method) -> StepDone(#(method, remaining))
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
          StepDone(#(target, Http11))
        <<target:bytes-size(target_size), " HTTP/1.0":utf8>> ->
          StepDone(#(target, Http10))
        _bits -> ParseError(BadVersion)
      }
    }
  }
}

fn split_target(target: BitArray) -> Step(#(String, option.Option(String))) {
  case find_question(target) {
    Error(Nil) -> {
      use path <- try_step(decode_component(target, BadTarget))
      StepDone(#(path, option.None))
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
          StepDone(#(path, option.Some(query)))
        }
        _target -> ParseError(BadTarget)
      }
    }
  }
}

fn decode_component(bits: BitArray, on_error: ParseError) -> Step(String) {
  case bit_array_to_string(bits) {
    Ok(value) -> StepDone(value)
    Error(Nil) -> ParseError(on_error)
  }
}

fn validate_path(method: http.Method, path: String) -> Step(String) {
  case path, method {
    "*", http.Options -> StepDone(path)
    "/" <> _remaining, _method -> StepDone(path)
    _path, _method -> ParseError(BadTarget)
  }
}

fn resolve_target(
  method: http.Method,
  target: BitArray,
  version: Version,
  header_host: option.Option(#(String, option.Option(Int))),
) -> Step(#(String, option.Option(Int), String, option.Option(String))) {
  case method {
    http.Connect ->
      case split_host_port(target) {
        Ok(#(host, option.Some(_port) as port)) ->
          case bit_array_to_string(host) {
            Ok(host) -> StepDone(#(host, port, "", option.None))
            Error(Nil) -> ParseError(BadTarget)
          }
        Ok(#(_host, option.None)) -> ParseError(BadTarget)
        Error(Nil) -> ParseError(BadTarget)
      }
    _method -> {
      use #(path, query) <- try_step(split_target(target))
      use path <- try_step(validate_path(method, path))
      use #(host, port) <- try_step(resolve_host(version, header_host))
      StepDone(#(host, port, path, query))
    }
  }
}

fn resolve_host(
  version: Version,
  header_host: option.Option(#(String, option.Option(Int))),
) -> Step(#(String, option.Option(Int))) {
  case header_host, version {
    option.Some(host_port), _version -> StepDone(host_port)
    option.None, Http10 -> StepDone(#("", option.None))
    option.None, Http11 -> ParseError(MissingHost)
  }
}

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
  case parse_decimal(bits) {
    Ok(port) if port <= 65_535 -> Ok(port)
    Ok(_port) -> Error(Nil)
    Error(Nil) -> Error(Nil)
  }
}

fn parse_decimal(bits: BitArray) -> Result(Int, Nil) {
  case bits {
    <<byte, remaining:bits>> if byte >= 48 && byte <= 57 ->
      parse_decimal_digits(remaining, byte - 48)
    _bits -> Error(Nil)
  }
}

fn parse_decimal_digits(bits: BitArray, acc: Int) -> Result(Int, Nil) {
  case bits {
    <<byte, remaining:bits>> if byte >= 48 && byte <= 57 ->
      parse_decimal_digits(remaining, acc * 10 + { byte - 48 })
    <<>> -> Ok(acc)
    _bits -> Error(Nil)
  }
}

/// What the request's `Connection` header asked for, before the version's
/// default is applied.
pub type ConnectionIntent {
  RequestedKeepAlive
  RequestedClose
  NothingRequested
}

pub type HeaderState {
  HeaderState(
    content_length: option.Option(Int),
    chunked: Bool,
    connection: ConnectionIntent,
    connection_upgrade: Bool,
    upgrade: option.Option(String),
    host: option.Option(#(String, option.Option(Int))),
  )
}

pub fn initial_header_state() -> HeaderState {
  HeaderState(
    content_length: option.None,
    chunked: False,
    connection: NothingRequested,
    connection_upgrade: False,
    upgrade: option.None,
    host: option.None,
  )
}

fn resolve_metadata(state: HeaderState, version: Version) -> Step(Metadata) {
  case state.content_length, state.chunked {
    option.Some(_length), True -> ParseError(AmbiguousFraming)
    option.Some(length), False ->
      StepDone(complete_metadata(state, version, http1.Fixed(length)))
    option.None, True ->
      StepDone(complete_metadata(state, version, http1.Chunked))
    option.None, False ->
      StepDone(complete_metadata(state, version, http1.NoBody))
  }
}

fn complete_metadata(
  state: HeaderState,
  version: Version,
  framing: http1.Framing,
) -> Metadata {
  let keep_alive = case state.connection, version {
    RequestedKeepAlive, _version -> http1.KeepAlive
    RequestedClose, _version -> http1.CloseAfterResponse
    NothingRequested, Http11 -> http1.KeepAlive
    NothingRequested, Http10 -> http1.CloseAfterResponse
  }
  let upgrade = case state.connection_upgrade {
    True -> state.upgrade
    False -> option.None
  }

  Metadata(framing:, keep_alive:, upgrade:)
}

pub fn parse_headers(
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
    <<>> -> StepDone(#(list.reverse(acc), state, remaining))
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
            Ok(name_text), Ok(value_text) -> {
              use state <- try_step(classify(name_text, value, state))
              StepDone(#(#(name_text, value_text), state))
            }
            _name, _value -> ParseError(BadHeader)
          }
        }
        _bad -> ParseError(BadHeader)
      }
  }
}

fn classify(
  name: String,
  value: BitArray,
  state: HeaderState,
) -> Step(HeaderState) {
  case name {
    "content-length" ->
      case state.content_length {
        option.Some(_length) -> ParseError(DuplicateContentLength)
        option.None ->
          case parse_decimal(value) {
            Ok(length) ->
              StepDone(
                HeaderState(..state, content_length: option.Some(length)),
              )
            Error(Nil) -> ParseError(BadContentLength)
          }
      }
    "transfer-encoding" -> {
      let lowered = lowercase_ascii(value)
      let chunked = state.chunked || has_token(lowered, <<"chunked":utf8>>)
      StepDone(HeaderState(..state, chunked:))
    }
    "connection" -> {
      let requested = value |> lowercase_ascii |> tokens
      let connection = case
        list.contains(requested, <<"close":utf8>>),
        list.contains(requested, <<"keep-alive":utf8>>)
      {
        True, _keep_alive -> RequestedClose
        False, True -> RequestedKeepAlive
        False, False -> state.connection
      }
      let connection_upgrade =
        state.connection_upgrade || list.contains(requested, <<"upgrade":utf8>>)
      StepDone(HeaderState(..state, connection:, connection_upgrade:))
    }
    "upgrade" -> {
      let lowered = value |> lowercase_ascii |> unsafe_to_string
      StepDone(HeaderState(..state, upgrade: option.Some(lowered)))
    }
    "host" ->
      case state.host {
        option.Some(_host) -> ParseError(DuplicateHost)
        option.None ->
          case split_host_port(value) {
            Ok(#(host, port)) -> {
              let host = option.Some(#(unsafe_to_string(host), port))
              StepDone(HeaderState(..state, host:))
            }
            Error(Nil) -> ParseError(BadHost)
          }
      }
    _other -> StepDone(state)
  }
}

pub fn extract_line(
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
          StepDone(#(line, remaining))
        _bad -> ParseError(malformed)
      }
  }
}

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

/// The comma separated list a header value carries, one trimmed token per
/// element.
pub fn tokens(value: BitArray) -> List(BitArray) {
  split_comma(value) |> list.map(trim_ows)
}

pub fn has_token(value: BitArray, token: BitArray) -> Bool {
  value == token || list.contains(tokens(value), token)
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
pub fn find_unsafe_header_byte(value: String) -> Result(Int, Nil)

@external(erlang, "http1_ffi", "split_comma")
fn split_comma(bits: BitArray) -> List(BitArray)

@external(erlang, "http1_ffi", "lowercase_ascii")
pub fn lowercase_ascii(bits: BitArray) -> BitArray

@external(erlang, "http1_ffi", "bit_array_to_string")
fn bit_array_to_string(bits: BitArray) -> Result(String, Nil)

@external(erlang, "ewe_ffi", "identity")
fn unsafe_to_string(bits: BitArray) -> String
