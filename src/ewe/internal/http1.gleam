import gleam/bit_array
import gleam/http
import gleam/int
import gleam/list
import gleam/option

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
  Metadata(content_length: option.Option(Int), chunked: Bool, keep_alive: Bool)
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
}

pub type Parsed {
  Complete(head: Head, metadata: Metadata, remaining: BitArray)
  Incomplete
  Failed(ParseError)
}

const max_request_line = 8192

const max_header_line = 8192

const max_headers = 100

/// Parses as much of a request head as `buffer` contains.
pub fn parse(buffer: BitArray) -> Parsed {
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

    Done(Complete(
      Head(method:, host:, port:, path:, query:, version:, headers:),
      state.metadata,
      remaining,
    ))
  }

  case step {
    Done(parsed) -> parsed
    More -> Incomplete
    ParseError(error) -> Failed(error)
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

// Threaded through `parse_headers`. `metadata` mirrors `Head.headers` in
// one pass, `host` holds the `Host` header once seen.
type HeaderState {
  HeaderState(
    metadata: Metadata,
    host: option.Option(#(String, option.Option(Int))),
  )
}

fn initial_header_state() -> HeaderState {
  HeaderState(
    metadata: Metadata(
      content_length: option.None,
      chunked: False,
      keep_alive: True,
    ),
    host: option.None,
  )
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

// Updates `metadata` and `host` from a single already decoded header.
fn classify(
  name: String,
  value: String,
  state: HeaderState,
) -> Step(HeaderState) {
  let meta = state.metadata
  case name {
    "content-length" ->
      case meta.content_length {
        option.Some(_length) -> ParseError(DuplicateContentLength)
        option.None ->
          case int.parse(value) {
            Ok(length) if length >= 0 -> {
              let content_length = option.Some(length)
              let metadata = Metadata(..meta, content_length:)
              Done(HeaderState(..state, metadata:))
            }
            _bad -> ParseError(BadContentLength)
          }
      }
    "transfer-encoding" -> {
      let lowered = value |> bit_array.from_string |> lowercase_ascii
      let chunked = meta.chunked || lowered == <<"chunked":utf8>>
      Done(HeaderState(..state, metadata: Metadata(..meta, chunked:)))
    }
    "connection" -> {
      let lowered = value |> bit_array.from_string |> lowercase_ascii
      let closing = has_token(lowered, <<"close":utf8>>)
      HeaderState(..state, metadata: Metadata(..meta, keep_alive: !closing))
      |> Done
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
        <<init:bytes-size(size - 1), 32>> -> trim_trailing_ows(init)
        <<init:bytes-size(size - 1), 9>> -> trim_trailing_ows(init)
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
