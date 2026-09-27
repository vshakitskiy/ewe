import ewe/internal/http1/connection as http1
import ewe/internal/target
import gleam/bit_array
import gleam/http
import gleam/list
import gleam/option
import gleam/result

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
    upgrade: option.Option(http1.Upgrade),
    expect_continue: Bool,
  )
}

pub type ParseError {
  RequestLineTooLong
  BadRequestLine
  BadMethod
  BadTarget
  BadVersion
  UnsupportedVersion
  HeaderLineTooLong
  BadHeader
  TooManyHeaders
  DuplicateContentLength
  BadContentLength
  DuplicateHost
  BadHost
  MissingHost
  AmbiguousFraming
  UnsupportedTransferEncoding
  ChunkSizeLineTooLong
  BadChunkSize
  BadChunkFraming
  ChunkTooLarge
  BodyReadFailed
}

pub fn error_to_string(error: ParseError) -> String {
  case error {
    RequestLineTooLong -> "request line exceeds the configured limit"
    BadRequestLine -> "malformed request line"
    BadMethod -> "invalid request method"
    BadTarget -> "invalid request target"
    BadVersion -> "malformed HTTP version"
    UnsupportedVersion -> "unsupported HTTP version"
    HeaderLineTooLong -> "header line exceeds the configured limit"
    BadHeader -> "malformed header line"
    TooManyHeaders -> "too many headers"
    DuplicateContentLength -> "duplicate Content-Length header"
    BadContentLength -> "invalid Content-Length value"
    DuplicateHost -> "duplicate Host header"
    BadHost -> "invalid Host header"
    MissingHost -> "missing required Host header"
    AmbiguousFraming ->
      "conflicting Content-Length and Transfer-Encoding headers"
    UnsupportedTransferEncoding -> "unsupported transfer coding"
    ChunkSizeLineTooLong -> "chunk size line exceeds the configured limit"
    BadChunkSize -> "malformed chunk size"
    BadChunkFraming -> "malformed chunk data framing"
    ChunkTooLarge -> "chunked body exceeds size limit"
    BodyReadFailed -> "failed to read request body from the socket"
  }
}

pub fn error_to_status(error: ParseError) -> Int {
  case error {
    RequestLineTooLong -> 414
    HeaderLineTooLong | TooManyHeaders -> 431
    ChunkTooLarge -> 413
    UnsupportedVersion -> 505
    UnsupportedTransferEncoding -> 501
    BadRequestLine
    | BadVersion
    | BadMethod
    | BadTarget
    | BadHeader
    | DuplicateContentLength
    | BadContentLength
    | DuplicateHost
    | BadHost
    | MissingHost
    | AmbiguousFraming
    | ChunkSizeLineTooLong
    | BadChunkSize
    | BadChunkFraming
    | BodyReadFailed -> 400
  }
}

pub type Parsed {
  Complete(head: Head, metadata: Metadata, remaining: BitArray)
  Incomplete
}

pub fn parse(
  buffer: BitArray,
  options: http1.Options,
) -> Result(Parsed, ParseError) {
  let step = {
    use #(method, target, version, remaining) <- try_step(parse_request_line(
      buffer,
      options,
    ))

    use #(headers, state, remaining) <- try_step(parse_headers(
      remaining,
      [],
      0,
      initial_header_state(),
      options,
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
  options: http1.Options,
) -> Step(#(http.Method, BitArray, Version, BitArray)) {
  use #(line, remaining) <- try_step(extract_line(
    skip_empty_line(buffer),
    options.max_request_line,
    RequestLineTooLong,
    BadRequestLine,
  ))

  use #(method, target_and_version) <- try_step(parse_method(line))

  use #(target, version) <- try_step(parse_target_version(target_and_version))

  StepDone(#(method, target, version, remaining))
}

fn skip_empty_line(buffer: BitArray) -> BitArray {
  case buffer {
    <<"\r\n":utf8, remaining:bits>> -> remaining
    _buffer -> buffer
  }
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
        <<
          _target:bytes-size(target_size),
          " HTTP/":utf8,
          major,
          ".":utf8,
          minor,
        >>
          if major >= 48 && major <= 57 && minor >= 48 && minor <= 57
        -> ParseError(UnsupportedVersion)
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
  case target.is_valid_path(method, path) {
    True -> StepDone(path)
    False -> ParseError(BadTarget)
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
      case target.split_host_port(target) {
        Ok(#(host, option.Some(_port) as port)) ->
          case bit_array_to_string(host) {
            Ok(host) -> StepDone(#(host, port, "", option.None))
            Error(Nil) -> ParseError(BadTarget)
          }
        Ok(#(_host, option.None)) -> ParseError(BadTarget)
        Error(Nil) -> ParseError(BadTarget)
      }
    _method -> {
      use #(authority, origin) <- try_step(split_absolute_form(target))
      use #(path, query) <- try_step(split_target(origin))
      use path <- try_step(validate_path(method, path))
      use header_host <- try_step(resolve_host(version, header_host))
      let #(host, port) = option.unwrap(authority, header_host)
      StepDone(#(host, port, path, query))
    }
  }
}

fn split_absolute_form(
  target: BitArray,
) -> Step(#(option.Option(#(String, option.Option(Int))), BitArray)) {
  case target {
    <<"/":utf8, _path:bits>> -> StepDone(#(option.None, target))
    <<scheme:bytes-size(4), "://":utf8, remaining:bits>>
    | <<scheme:bytes-size(5), "://":utf8, remaining:bits>> ->
      case lowercase_ascii(scheme) {
        <<"http":utf8>> | <<"https":utf8>> -> split_authority(remaining)
        _scheme -> ParseError(BadTarget)
      }
    _target -> StepDone(#(option.None, target))
  }
}

fn split_authority(
  bits: BitArray,
) -> Step(#(option.Option(#(String, option.Option(Int))), BitArray)) {
  let position =
    find_authority_end(bits) |> result.unwrap(bit_array.byte_size(bits))

  case bits {
    <<authority:bytes-size(position), origin:bits>> ->
      case target.parse_authority(authority) {
        Ok(#(host, port)) -> {
          use host <- try_step(decode_component(host, BadTarget))
          StepDone(#(option.Some(#(host, port)), origin_form(origin)))
        }
        Error(Nil) -> ParseError(BadTarget)
      }
    _bits -> ParseError(BadTarget)
  }
}

fn origin_form(origin: BitArray) -> BitArray {
  case origin {
    <<"/":utf8, _path:bits>> -> origin
    _query -> <<"/":utf8, origin:bits>>
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

pub type ConnectionIntent {
  RequestedKeepAlive
  RequestedClose
  NothingRequested
}

pub type TransferEncoding {
  NoTransferEncoding
  ChunkedFinal
  UnsupportedFinal
}

pub type HeaderState {
  HeaderState(
    content_length: option.Option(Int),
    transfer_encoding: TransferEncoding,
    connection: ConnectionIntent,
    connection_upgrade: Bool,
    upgrade: option.Option(String),
    websocket_key: option.Option(String),
    websocket_version: option.Option(String),
    websocket_extensions: option.Option(String),
    host: option.Option(#(String, option.Option(Int))),
    expect_continue: Bool,
  )
}

pub fn initial_header_state() -> HeaderState {
  HeaderState(
    content_length: option.None,
    transfer_encoding: NoTransferEncoding,
    connection: NothingRequested,
    connection_upgrade: False,
    upgrade: option.None,
    websocket_key: option.None,
    websocket_version: option.None,
    websocket_extensions: option.None,
    host: option.None,
    expect_continue: False,
  )
}

fn resolve_metadata(state: HeaderState, version: Version) -> Step(Metadata) {
  case state.content_length, state.transfer_encoding {
    _length, UnsupportedFinal -> ParseError(UnsupportedTransferEncoding)
    option.Some(_length), ChunkedFinal -> ParseError(AmbiguousFraming)
    option.Some(length), NoTransferEncoding ->
      StepDone(complete_metadata(state, version, http1.Fixed(length)))
    option.None, ChunkedFinal ->
      case version {
        Http11 -> StepDone(complete_metadata(state, version, http1.Chunked))
        Http10 -> ParseError(AmbiguousFraming)
      }
    option.None, NoTransferEncoding ->
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
  let expect_continue = case framing, version {
    http1.NoBody, _version | http1.Fixed(0), _version | _framing, Http10 ->
      False
    http1.Fixed(_length), Http11 | http1.Chunked, Http11 ->
      state.expect_continue
  }
  Metadata(
    framing:,
    keep_alive:,
    upgrade: resolve_upgrade(state),
    expect_continue:,
  )
}

fn resolve_upgrade(state: HeaderState) -> option.Option(http1.Upgrade) {
  case state.connection_upgrade, state.upgrade {
    True, option.Some("websocket") ->
      option.Some(http1.WebsocketUpgrade(
        key: state.websocket_key,
        version: state.websocket_version,
        extensions: state.websocket_extensions,
      ))
    True, option.Some(name) -> option.Some(http1.OtherUpgrade(name))
    True, option.None | False, _upgrade -> option.None
  }
}

pub fn parse_headers(
  buffer: BitArray,
  acc: List(#(String, String)),
  count: Int,
  state: HeaderState,
  options: http1.Options,
) -> Step(#(List(#(String, String)), HeaderState, BitArray)) {
  use #(line, remaining) <- try_step(extract_line(
    buffer,
    options.max_header_line,
    HeaderLineTooLong,
    BadHeader,
  ))

  case line {
    <<>> -> StepDone(#(list.reverse(acc), state, remaining))
    _line if count >= options.max_headers -> ParseError(TooManyHeaders)
    _line -> {
      use #(header, state) <- try_step(parse_header_line(line, state))
      parse_headers(remaining, [header, ..acc], count + 1, state, options)
    }
  }
}

fn parse_header_line(
  line: BitArray,
  state: HeaderState,
) -> Step(#(#(String, String), HeaderState)) {
  case find_colon(line) {
    Error(Nil) -> ParseError(BadHeader)
    Ok(position) ->
      case line {
        <<name:bytes-size(position), ":":utf8, value:bits>> -> {
          let name = lowercase_ascii(name)
          let value = trim_ows(value)
          case is_field_name(name) && is_field_value(value) {
            True -> {
              let name = unsafe_to_string(name)
              use state <- try_step(classify(name, value, state))
              StepDone(#(#(name, unsafe_to_string(value)), state))
            }
            False -> ParseError(BadHeader)
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
          case target.parse_decimal(value) {
            Ok(length) ->
              StepDone(
                HeaderState(..state, content_length: option.Some(length)),
              )
            Error(Nil) -> ParseError(BadContentLength)
          }
      }
    "transfer-encoding" -> {
      let transfer_encoding = case
        state.transfer_encoding,
        value |> lowercase_ascii |> tokens
      {
        NoTransferEncoding, [<<"chunked":utf8>>] -> ChunkedFinal
        _transfer_encoding, _codings -> UnsupportedFinal
      }
      StepDone(HeaderState(..state, transfer_encoding:))
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
    "sec-websocket-key" ->
      StepDone(
        HeaderState(
          ..state,
          websocket_key: option.Some(unsafe_to_string(value)),
        ),
      )
    "sec-websocket-version" ->
      StepDone(
        HeaderState(
          ..state,
          websocket_version: option.Some(unsafe_to_string(value)),
        ),
      )
    "sec-websocket-extensions" -> {
      let lowered = value |> lowercase_ascii |> unsafe_to_string
      StepDone(HeaderState(..state, websocket_extensions: option.Some(lowered)))
    }
    "expect" -> {
      let expect_continue = lowercase_ascii(value) == <<"100-continue":utf8>>
      StepDone(HeaderState(..state, expect_continue:))
    }
    "host" ->
      case state.host {
        option.Some(_host) -> ParseError(DuplicateHost)
        option.None ->
          case target.split_host_port(value) {
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
      case position - 1 > max_len {
        True -> ParseError(too_long)
        False ->
          case buffer {
            <<line:bytes-size(position - 1), "\r\n":utf8, remaining:bits>> ->
              StepDone(#(line, remaining))
            _bad -> ParseError(malformed)
          }
      }
  }
}

fn trim_ows(bits: BitArray) -> BitArray {
  bits
  |> trim_leading_ows
  |> trim_trailing_ows
}

pub fn trim_leading_ows(bits: BitArray) -> BitArray {
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

pub fn tokens(value: BitArray) -> List(BitArray) {
  split_comma(value) |> list.map(trim_ows)
}

pub fn has_token(value: BitArray, token: BitArray) -> Bool {
  value == token || list.contains(tokens(value), token)
}

@external(erlang, "ewe_ffi", "find_lf")
fn find_lf(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "ewe_ffi", "find_colon")
fn find_colon(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "ewe_ffi", "find_space")
fn find_space(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "ewe_ffi", "find_question")
fn find_question(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "ewe_ffi", "find_authority_end")
fn find_authority_end(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "ewe_ffi", "is_field_name")
fn is_field_name(name: BitArray) -> Bool

@external(erlang, "ewe_ffi", "is_field_value")
fn is_field_value(value: BitArray) -> Bool

@external(erlang, "ewe_ffi", "find_unsafe_header_byte")
pub fn find_unsafe_header_byte(value: String) -> Result(Int, Nil)

@external(erlang, "ewe_ffi", "split_comma")
fn split_comma(bits: BitArray) -> List(BitArray)

@external(erlang, "ewe_ffi", "lowercase_ascii")
pub fn lowercase_ascii(bits: BitArray) -> BitArray

@external(erlang, "ewe_ffi", "bit_array_to_string")
fn bit_array_to_string(bits: BitArray) -> Result(String, Nil)

@external(erlang, "ewe_ffi", "identity")
fn unsafe_to_string(bits: BitArray) -> String
