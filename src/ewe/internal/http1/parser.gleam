import ewe/internal/field
import ewe/internal/http1/connection as http1
import ewe/internal/target
import gleam/bit_array
import gleam/http
import gleam/int
import gleam/list
import gleam/option
import gleam/result

// The version suffix occupies nine bytes after the request target: a space
// followed by HTTP/1.x. The target occupies at least one byte before it.
//
// ```txt
//   /hello HTTP/1.1\r\n
//        |--------|
//          9 bytes
// ```
const http_version_suffix_size = 9

const question_mark = 63

const slash = 47

const digit_zero = 48

const digit_nine = 57

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

type HeadContext {
  HeadContext(
    method: http.Method,
    version: Version,
    headers: List(#(String, String)),
    state: HeaderState,
    remaining: BitArray,
  )
}

pub fn parse(
  buffer: BitArray,
  options: http1.Options,
) -> Result(Parsed, ParseError) {
  case parse_request_line(buffer, options) {
    More -> Ok(Incomplete)
    ParseError(error) -> Error(error)
    StepDone(#(method, target, version, remaining)) -> {
      let parsed_headers =
        parse_headers(
          buffer: remaining,
          headers: [],
          count: 0,
          state: initial_header_state(),
          options:,
        )

      case parsed_headers {
        More -> Ok(Incomplete)
        ParseError(error) -> Error(error)
        StepDone(#(headers, state, remaining)) -> {
          let context =
            HeadContext(method:, version:, headers:, state:, remaining:)

          finish_target(target, context)
        }
      }
    }
  }
}

fn finish_target(
  target: BitArray,
  context: HeadContext,
) -> Result(Parsed, ParseError) {
  case context.method, target {
    http.Connect, _target ->
      case target.split_host_port(target) {
        Ok(#(host, option.Some(_port) as port)) ->
          case bit_array.to_string(host) {
            Ok(host) ->
              finish_head(host:, port:, path: "", query: option.None, context:)
            Error(Nil) -> Error(BadTarget)
          }
        Ok(#(_host, option.None)) | Error(Nil) -> Error(BadTarget)
      }
    _method, <<"/", _path:bits>> -> finish_origin(target, option.None, context)
    _method, _target ->
      case split_absolute_form(target) {
        StepDone(#(authority, origin)) ->
          finish_origin(origin, authority, context)
        More -> Ok(Incomplete)
        ParseError(error) -> Error(error)
      }
  }
}

fn finish_origin(
  origin: BitArray,
  authority: option.Option(#(String, option.Option(Int))),
  context: HeadContext,
) -> Result(Parsed, ParseError) {
  case find_byte(origin, question_mark, 0) {
    Error(Nil) ->
      finish_path(path: origin, query: option.None, authority:, context:)
    Ok(position) -> {
      let path = binary_part(origin, 0, position)
      let query_start = position + 1
      let query_size = bit_array.byte_size(origin) - query_start
      let query = binary_part(origin, query_start, query_size)

      case bit_array.is_utf8(query) {
        True ->
          finish_path(
            path:,
            query: option.Some(unsafe_to_string(query)),
            authority:,
            context:,
          )
        False -> Error(BadTarget)
      }
    }
  }
}

fn finish_path(
  path path: BitArray,
  query query: option.Option(String),
  authority authority: option.Option(#(String, option.Option(Int))),
  context context: HeadContext,
) -> Result(Parsed, ParseError) {
  case bit_array.is_utf8(path) {
    False -> Error(BadTarget)
    True -> {
      let path = unsafe_to_string(path)

      case target.is_valid_path(context.method, path) {
        False -> Error(BadTarget)
        True ->
          case context.state.host, context.version {
            option.None, Http11 -> Error(MissingHost)
            option.None, Http10 ->
              finish_authority(
                authority:,
                header_host: #("", option.None),
                path:,
                query:,
                context:,
              )
            option.Some(host), _version ->
              finish_authority(
                authority:,
                header_host: host,
                path:,
                query:,
                context:,
              )
          }
      }
    }
  }
}

fn finish_authority(
  authority authority: option.Option(#(String, option.Option(Int))),
  header_host header_host: #(String, option.Option(Int)),
  path path: String,
  query query: option.Option(String),
  context context: HeadContext,
) -> Result(Parsed, ParseError) {
  let #(host, port) = option.unwrap(authority, header_host)

  finish_head(host:, port:, path:, query:, context:)
}

fn finish_head(
  host host: String,
  port port: option.Option(Int),
  path path: String,
  query query: option.Option(String),
  context context: HeadContext,
) -> Result(Parsed, ParseError) {
  case resolve_metadata(context.state, context.version) {
    More -> Ok(Incomplete)
    ParseError(error) -> Error(error)
    StepDone(metadata) -> {
      let head =
        Head(
          method: context.method,
          host:,
          port:,
          path:,
          query:,
          version: context.version,
          headers: context.headers,
        )

      Ok(Complete(head, metadata, context.remaining))
    }
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
  let buffer = skip_empty_line(buffer)
  let buffer_size = bit_array.byte_size(buffer)
  let limit =
    int.min(buffer_size, options.max_request_line + field.line_ending_size)

  case find_line_feed(buffer, 0, limit) {
    Error(Nil) if buffer_size > options.max_request_line ->
      ParseError(RequestLineTooLong)
    Error(Nil) -> More
    Ok(0) -> ParseError(BadRequestLine)
    Ok(line_feed_position) ->
      case byte_at(buffer, line_feed_position - 1) {
        byte if byte == field.carriage_return ->
          parse_request_method(buffer, line_feed_position - 1)
        _byte -> ParseError(BadRequestLine)
      }
  }
}

fn parse_request_method(
  buffer: BitArray,
  line_size: Int,
) -> Step(#(http.Method, BitArray, Version, BitArray)) {
  case buffer {
    <<"GET ", rest:bits>> ->
      parse_request_version(
        rest,
        http.Get,
        line_size - bit_array.byte_size(<<"GET ">>),
      )
    <<"POST ", rest:bits>> ->
      parse_request_version(
        rest,
        http.Post,
        line_size - bit_array.byte_size(<<"POST ">>),
      )
    <<"PUT ", rest:bits>> ->
      parse_request_version(
        rest,
        http.Put,
        line_size - bit_array.byte_size(<<"PUT ">>),
      )
    <<"DELETE ", rest:bits>> ->
      parse_request_version(
        rest,
        http.Delete,
        line_size - bit_array.byte_size(<<"DELETE ">>),
      )
    <<"HEAD ", rest:bits>> ->
      parse_request_version(
        rest,
        http.Head,
        line_size - bit_array.byte_size(<<"HEAD ">>),
      )
    <<"OPTIONS ", rest:bits>> ->
      parse_request_version(
        rest,
        http.Options,
        line_size - bit_array.byte_size(<<"OPTIONS ">>),
      )
    <<"PATCH ", rest:bits>> ->
      parse_request_version(
        rest,
        http.Patch,
        line_size - bit_array.byte_size(<<"PATCH ">>),
      )
    <<"TRACE ", rest:bits>> ->
      parse_request_version(
        rest,
        http.Trace,
        line_size - bit_array.byte_size(<<"TRACE ">>),
      )
    <<"CONNECT ", rest:bits>> ->
      parse_request_version(
        rest,
        http.Connect,
        line_size - bit_array.byte_size(<<"CONNECT ">>),
      )
    _method -> parse_other_request_method(buffer, line_size)
  }
}

fn parse_request_version(
  bits: BitArray,
  method: http.Method,
  size: Int,
) -> Step(#(http.Method, BitArray, Version, BitArray)) {
  case size <= http_version_suffix_size {
    True -> ParseError(BadRequestLine)
    False -> {
      let target_size = size - http_version_suffix_size

      case bits {
        <<target:bytes-size(target_size), " HTTP/1.1\r\n", remaining:bits>> ->
          StepDone(#(method, target, Http11, remaining))
        <<target:bytes-size(target_size), " HTTP/1.0\r\n", remaining:bits>> ->
          StepDone(#(method, target, Http10, remaining))
        <<
          _target:bytes-size(target_size),
          " HTTP/",
          major,
          ".",
          minor,
          "\r\n",
          _rest:bits,
        >>
          if major >= digit_zero
          && major <= digit_nine
          && minor >= digit_zero
          && minor <= digit_nine
        -> ParseError(UnsupportedVersion)
        _bits -> ParseError(BadVersion)
      }
    }
  }
}

fn skip_empty_line(buffer: BitArray) -> BitArray {
  case buffer {
    <<"\r\n", remaining:bits>> -> remaining
    _buffer -> buffer
  }
}

fn parse_other_request_method(
  buffer: BitArray,
  line_size: Int,
) -> Step(#(http.Method, BitArray, Version, BitArray)) {
  let line = binary_part(buffer, 0, line_size)

  case find_byte(line, field.space, 0) {
    Ok(position) if position < line_size -> {
      let name = binary_part(buffer, 0, position)

      case bit_array.to_string(name) {
        Error(Nil) -> ParseError(BadMethod)
        Ok(name) ->
          case http.parse_method(name) {
            Error(Nil) -> ParseError(BadMethod)
            Ok(method) -> {
              let remaining_start = position + 1
              let remaining_size = bit_array.byte_size(buffer) - remaining_start
              let remaining =
                binary_part(buffer, remaining_start, remaining_size)
              let target_and_version_size = line_size - remaining_start

              parse_request_version(remaining, method, target_and_version_size)
            }
          }
      }
    }
    Ok(_position) | Error(Nil) -> ParseError(BadRequestLine)
  }
}

fn decode_component(bits: BitArray, on_error: ParseError) -> Step(String) {
  case bit_array.to_string(bits) {
    Ok(value) -> StepDone(value)
    Error(Nil) -> ParseError(on_error)
  }
}

fn split_absolute_form(
  target: BitArray,
) -> Step(#(option.Option(#(String, option.Option(Int))), BitArray)) {
  case target {
    <<"/", _path:bits>> -> StepDone(#(option.None, target))
    <<scheme:bytes-size(4), "://", remaining:bits>>
    | <<scheme:bytes-size(5), "://", remaining:bits>> ->
      case field.lowercase_ascii(scheme) {
        <<"http">> | <<"https">> -> split_authority(remaining)
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
    <<"/", _path:bits>> -> origin
    _query -> <<"/", origin:bits>>
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

/// Parses header lines, returning their fields, metadata state, and unconsumed
/// input. Returns `More` if a complete head has not arrived yet.
///
/// The scanner keeps `buffer` fixed and advances a separate matching tail. All
/// positions are absolute byte offsets into that buffer, so completed fields
/// can be sliced directly from it.
///
/// ```txt
///   host: example.com\r\nx-mode: fast\r\n\r\n
///                        ^     ^ position = 25
///                        line_start = 19
///
///   remaining = : fast\r\n\r\n
/// ```
///
/// This separates byte matching from field extraction as the BEAM can advance
/// the tail's match context while field slices use the original buffer.
///
pub fn parse_headers(
  buffer buffer: BitArray,
  headers headers: List(#(String, String)),
  count count: Int,
  state state: HeaderState,
  options options: http1.Options,
) -> Step(#(List(#(String, String)), HeaderState, BitArray)) {
  scan_name(
    remaining: buffer,
    buffer:,
    line_start: 0,
    position: 0,
    is_lowercase: True,
    is_invalid: False,
    headers:,
    count:,
    state:,
    options:,
  )
}

/// Scans a field name up to its colon, tracking its case and validity.
///
/// Each step advances `remaining` and its absolute `position` in the source
/// buffer. `line_start` stays at the beginning of the name. `is_lowercase` is
/// true until an uppercase ASCII byte is seen; `is_invalid` stays true after
/// the first space, control, or non-ASCII byte.
///
fn scan_name(
  remaining remaining: BitArray,
  buffer buffer: BitArray,
  line_start line_start: Int,
  position position: Int,
  is_lowercase is_lowercase: Bool,
  is_invalid is_invalid: Bool,
  headers headers: List(#(String, String)),
  count count: Int,
  state state: HeaderState,
  options options: http1.Options,
) -> Step(#(List(#(String, String)), HeaderState, BitArray)) {
  case remaining {
    <<"\r\n", rest:bits>> if position - line_start <= options.max_header_line -> {
      case position == line_start {
        True -> StepDone(#(list.reverse(headers), state, rest))
        False if count >= options.max_headers -> ParseError(TooManyHeaders)
        False -> ParseError(BadHeader)
      }
    }
    <<"\n", _rest:bits>>
      if position - line_start < options.max_header_line + field.line_ending_size
    -> ParseError(BadHeader)
    <<":", rest:bits>>
      if position - line_start < options.max_header_line + field.line_ending_size
    ->
      scan_value(
        remaining: rest,
        buffer:,
        line_start:,
        position: position + 1,
        colon: position,
        is_lowercase:,
        has_unicode: False,
        is_invalid: is_invalid || position == line_start,
        headers:,
        count:,
        state:,
        options:,
      )
    <<byte, rest:bits>>
      if position - line_start < options.max_header_line + field.line_ending_size
    ->
      scan_name(
        remaining: rest,
        buffer:,
        line_start:,
        position: position + 1,
        is_lowercase: is_lowercase
          && { byte < field.uppercase_a || byte > field.uppercase_z },
        is_invalid: is_invalid || byte <= field.space || byte >= field.delete,
        headers:,
        count:,
        state:,
        options:,
      )
    _remaining ->
      case bit_array.byte_size(buffer) - line_start > options.max_header_line {
        True -> ParseError(HeaderLineTooLong)
        False -> More
      }
  }
}

/// Advances over ASCII values in blocks of 28 bytes when possible.
///
/// Each successful block check advances `position` by 28. A block containing
/// bytes outside 14..127 goes to the byte scanner, which handles the rest of
/// the line, including its ending and any UTF-8 validation. Short tails take
/// the same byte-scanning path.
///
fn scan_value(
  remaining remaining: BitArray,
  buffer buffer: BitArray,
  line_start line_start: Int,
  position position: Int,
  colon colon: Int,
  is_lowercase is_lowercase: Bool,
  has_unicode has_unicode: Bool,
  is_invalid is_invalid: Bool,
  headers headers: List(#(String, String)),
  count count: Int,
  state state: HeaderState,
  options options: http1.Options,
) -> Step(#(List(#(String, String)), HeaderState, BitArray)) {
  let word_bits = field.ascii_word_bits

  case remaining {
    <<
      first:size(word_bits),
      second:size(word_bits),
      third:size(word_bits),
      fourth:size(word_bits),
      rest:bits,
    >>
      if position - line_start + field.ascii_chunk_size
      <= options.max_header_line + field.line_ending_size
    -> {
      // Keep the range check local to avoid a cross-module call for each block.
      // See `field.is_ascii_chunk` for the arithmetic behind the check.
      let first_pair =
        int.bitwise_or(
          int.bitwise_or(
            first - field.first_chunk_byte * field.byte_low_bits,
            first,
          ),
          int.bitwise_or(
            second - field.first_chunk_byte * field.byte_low_bits,
            second,
          ),
        )
      let second_pair =
        int.bitwise_or(
          int.bitwise_or(
            third - field.first_chunk_byte * field.byte_low_bits,
            third,
          ),
          int.bitwise_or(
            fourth - field.first_chunk_byte * field.byte_low_bits,
            fourth,
          ),
        )

      let can_skip_byte_scan =
        int.bitwise_and(
          int.bitwise_or(first_pair, second_pair),
          field.byte_high_bits,
        )
        == 0

      case can_skip_byte_scan {
        True ->
          scan_value(
            remaining: rest,
            buffer:,
            line_start:,
            position: position + field.ascii_chunk_size,
            colon:,
            is_lowercase:,
            has_unicode:,
            is_invalid:,
            headers:,
            count:,
            state:,
            options:,
          )
        False ->
          scan_value_bytes(
            remaining:,
            buffer:,
            line_start:,
            position:,
            colon:,
            is_lowercase:,
            has_unicode:,
            is_invalid:,
            headers:,
            count:,
            state:,
            options:,
          )
      }
    }
    _remaining ->
      scan_value_bytes(
        remaining:,
        buffer:,
        line_start:,
        position:,
        colon:,
        is_lowercase:,
        has_unicode:,
        is_invalid:,
        headers:,
        count:,
        state:,
        options:,
      )
  }
}

fn scan_value_bytes(
  remaining remaining: BitArray,
  buffer buffer: BitArray,
  line_start line_start: Int,
  position position: Int,
  colon colon: Int,
  is_lowercase is_lowercase: Bool,
  has_unicode has_unicode: Bool,
  is_invalid is_invalid: Bool,
  headers headers: List(#(String, String)),
  count count: Int,
  state state: HeaderState,
  options options: http1.Options,
) -> Step(#(List(#(String, String)), HeaderState, BitArray)) {
  case remaining {
    <<"\r\n", rest:bits>> if position - line_start <= options.max_header_line -> {
      case count >= options.max_headers {
        True -> ParseError(TooManyHeaders)
        False if is_invalid -> ParseError(BadHeader)
        False -> {
          let from = field.skip_leading_whitespace(buffer, colon + 1, position)
          let to = field.skip_trailing_whitespace(buffer, from, position)
          let value = binary_part(buffer, from, to - from)

          case has_unicode && !bit_array.is_utf8(value) {
            True -> ParseError(BadHeader)
            False -> {
              let name = binary_part(buffer, line_start, colon - line_start)
              let name = case is_lowercase {
                True -> unsafe_to_string(name)
                False -> unsafe_to_string(field.lowercase_ascii(name))
              }
              let headers = [#(name, unsafe_to_string(value)), ..headers]
              let next_line_start = position + field.line_ending_size

              case name {
                "content-length"
                | "transfer-encoding"
                | "connection"
                | "upgrade"
                | "sec-websocket-key"
                | "sec-websocket-version"
                | "sec-websocket-extensions"
                | "expect"
                | "host" ->
                  case classify(name, value, state) {
                    StepDone(state) ->
                      scan_name(
                        remaining: rest,
                        buffer:,
                        line_start: next_line_start,
                        position: next_line_start,
                        is_lowercase: True,
                        is_invalid: False,
                        headers:,
                        count: count + 1,
                        state:,
                        options:,
                      )
                    More -> More
                    ParseError(error) -> ParseError(error)
                  }
                _name ->
                  scan_name(
                    remaining: rest,
                    buffer:,
                    line_start: next_line_start,
                    position: next_line_start,
                    is_lowercase: True,
                    is_invalid: False,
                    headers:,
                    count: count + 1,
                    state:,
                    options:,
                  )
              }
            }
          }
        }
      }
    }
    <<"\n", _rest:bits>>
      if position - line_start < options.max_header_line + field.line_ending_size
    -> ParseError(BadHeader)
    <<byte, rest:bits>>
      if position - line_start < options.max_header_line + field.line_ending_size
    -> {
      scan_value_bytes(
        remaining: rest,
        buffer:,
        line_start:,
        position: position + 1,
        colon:,
        is_lowercase:,
        has_unicode: has_unicode || byte >= field.non_ascii_start,
        is_invalid: is_invalid
          || byte == field.null_byte
          || byte == field.carriage_return,
        headers:,
        count:,
        state:,
        options:,
      )
    }
    _remaining ->
      case bit_array.byte_size(buffer) - line_start > options.max_header_line {
        True -> ParseError(HeaderLineTooLong)
        False -> More
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
      let codings = value |> field.lowercase_ascii |> tokens
      let transfer_encoding = case state.transfer_encoding, codings {
        NoTransferEncoding, [<<"chunked">>] -> ChunkedFinal
        _transfer_encoding, _codings -> UnsupportedFinal
      }
      StepDone(HeaderState(..state, transfer_encoding:))
    }
    "connection" -> {
      let requested = value |> field.lowercase_ascii |> tokens
      let requests_close = list.contains(requested, <<"close">>)
      let requests_keep_alive = list.contains(requested, <<"keep-alive">>)
      let connection = case requests_close, requests_keep_alive {
        True, _keep_alive -> RequestedClose
        False, True -> RequestedKeepAlive
        False, False -> state.connection
      }
      let connection_upgrade =
        state.connection_upgrade || list.contains(requested, <<"upgrade">>)
      StepDone(HeaderState(..state, connection:, connection_upgrade:))
    }
    "upgrade" -> {
      let lowered = value |> field.lowercase_ascii |> unsafe_to_string
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
      let lowered = value |> field.lowercase_ascii |> unsafe_to_string
      StepDone(HeaderState(..state, websocket_extensions: option.Some(lowered)))
    }
    "expect" -> {
      let expect_continue = field.lowercase_ascii(value) == <<"100-continue">>
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

type Line {
  Line(content: BitArray, rest: BitArray)
  NeedMore
  LineTooLong
  BadFraming
}

pub fn extract_line(
  buffer buffer: BitArray,
  max_len max_len: Int,
  too_long too_long: ParseError,
  malformed malformed: ParseError,
) -> Step(#(BitArray, BitArray)) {
  case split_line(buffer, max_len) {
    Line(content:, rest:) -> StepDone(#(content, rest))
    NeedMore -> More
    LineTooLong -> ParseError(too_long)
    BadFraming -> ParseError(malformed)
  }
}

pub fn tokens(value: BitArray) -> List(BitArray) {
  split_comma(value) |> list.map(field.trim_whitespace)
}

pub fn has_token(value: BitArray, token: BitArray) -> Bool {
  value == token || list.contains(tokens(value), token)
}

fn find_byte(bits: BitArray, needle: Int, position: Int) -> Result(Int, Nil) {
  case bits {
    <<byte, _rest:bits>> if byte == needle -> Ok(position)
    <<_byte, rest:bits>> -> find_byte(rest, needle, position + 1)
    _bits -> Error(Nil)
  }
}

fn find_authority_end(bits: BitArray) -> Result(Int, Nil) {
  find_authority_byte(bits, 0)
}

fn find_authority_byte(bits: BitArray, position: Int) -> Result(Int, Nil) {
  case bits {
    <<byte, _rest:bits>> if byte == slash || byte == question_mark ->
      Ok(position)
    <<_byte, rest:bits>> -> find_authority_byte(rest, position + 1)
    _bits -> Error(Nil)
  }
}

fn split_line(buffer: BitArray, max_len: Int) -> Line {
  let size = bit_array.byte_size(buffer)
  let limit = int.min(size, max_len + field.line_ending_size)

  case find_line_feed(buffer, 0, limit) {
    Error(Nil) if size > max_len -> LineTooLong
    Error(Nil) -> NeedMore
    Ok(0) -> BadFraming
    Ok(line_feed_position) ->
      case byte_at(buffer, line_feed_position - 1) {
        byte if byte == field.carriage_return -> {
          let content_size = line_feed_position - 1
          let rest_start = line_feed_position + 1
          let rest_size = size - rest_start
          let content = binary_part(buffer, 0, content_size)
          let rest = binary_part(buffer, rest_start, rest_size)

          Line(content:, rest:)
        }
        _byte -> BadFraming
      }
  }
}

fn find_line_feed(
  bits: BitArray,
  position: Int,
  limit: Int,
) -> Result(Int, Nil) {
  case bits {
    <<"\n", _rest:bits>> if position < limit -> Ok(position)
    <<_byte, rest:bits>> if position < limit ->
      find_line_feed(rest, position + 1, limit)
    _bits -> Error(Nil)
  }
}

fn split_comma(bits: BitArray) -> List(BitArray) {
  do_split_comma(original: bits, remaining: bits, position: 0, pieces: [])
}

fn do_split_comma(
  original original: BitArray,
  remaining remaining: BitArray,
  position position: Int,
  pieces pieces: List(BitArray),
) -> List(BitArray) {
  case remaining {
    <<",", rest:bits>> -> {
      let piece = binary_part(original, 0, position)

      do_split_comma(original: rest, remaining: rest, position: 0, pieces: [
        piece,
        ..pieces
      ])
    }
    <<_byte, rest:bits>> ->
      do_split_comma(
        original:,
        remaining: rest,
        position: position + 1,
        pieces:,
      )
    _remaining -> list.reverse([original, ..pieces])
  }
}

@external(erlang, "ewe_ffi", "identity")
fn unsafe_to_string(bits: BitArray) -> String

@external(erlang, "binary", "at")
fn byte_at(bits: BitArray, position: Int) -> Int

@external(erlang, "binary", "part")
fn binary_part(bits: BitArray, position: Int, size: Int) -> BitArray
