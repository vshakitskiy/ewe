import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}

pub type Frame {
  Data(stream_id: Int, end_stream: Bool, data: BitArray, size: Int)
  Headers(
    stream_id: Int,
    end_stream: Bool,
    end_headers: Bool,
    dependency: option.Option(Int),
    fragment: BitArray,
  )
  Priority(stream_id: Int, dependency: Int)
  RstStream(stream_id: Int, error: ErrorCode)
  Settings(ack: Bool, settings: List(Setting))
  PushPromise(stream_id: Int, promised_stream_id: Int, fragment: BitArray)
  Ping(ack: Bool, data: BitArray)
  Goaway(last_stream_id: Int, error: ErrorCode, debug: BitArray)
  WindowUpdate(stream_id: Int, increment: Int)
  Continuation(stream_id: Int, end_headers: Bool, fragment: BitArray)
  Unknown(stream_id: Int, frame_type: Int)
}

pub type Setting {
  HeaderTableSize(Int)
  EnablePush(Bool)
  MaxConcurrentStreams(Int)
  InitialWindowSize(Int)
  MaxFrameSize(Int)
  MaxHeaderListSize(Int)
  EnableConnectProtocol(Bool)
}

pub type ErrorCode {
  NoError
  ProtocolError
  InternalError
  FlowControlError
  SettingsTimeout
  StreamClosed
  FrameSizeError
  RefusedStream
  Cancel
  CompressionError
  ConnectError
  EnhanceYourCalm
  InadequateSecurity
  Http11Required
  UnknownErrorCode(Int)
}

pub type Decoded {
  Decoded(frame: Frame, rest: BitArray)
  StreamError(stream_id: Int, error: ErrorCode, rest: BitArray)
  ConnectionError(error: ErrorCode)
  NeedMoreData
}

pub const max_window_size = 2_147_483_647

pub const default_window_size = 65_535

pub const min_frame_size = 16_384

pub const max_frame_size = 16_777_215

pub const default_header_table_size = 4096

pub fn decode(bytes: BitArray, max_size: Int) -> Decoded {
  case bytes {
    <<
      length:24,
      frame_type:8,
      flags:bits-size(8),
      _reserved:1,
      stream_id:31,
      rest:bits,
    >> ->
      case length > max_size {
        True -> ConnectionError(FrameSizeError)
        False ->
          case rest {
            <<payload:bytes-size(length), rest:bits>> ->
              decode_payload(frame_type, flags, stream_id, payload, rest)
            _partial -> NeedMoreData
          }
      }
    _partial -> NeedMoreData
  }
}

fn decode_payload(
  frame_type: Int,
  flags: BitArray,
  stream_id: Int,
  payload: BitArray,
  rest: BitArray,
) -> Decoded {
  let assert <<
    _unused:2,
    priority_flag:1,
    _unused:1,
    padded_flag:1,
    end_headers_flag:1,
    _unused:1,
    end_stream_or_ack:1,
  >> = flags
  let padded = padded_flag == 1
  let end_stream = end_stream_or_ack == 1

  case frame_type {
    0x0 -> {
      use <- require_stream(stream_id)
      use content <- unpad(padded, payload)

      let size = bit_array.byte_size(payload)
      Decoded(Data(stream_id:, end_stream:, data: content, size:), rest)
    }
    0x1 -> {
      use <- require_stream(stream_id)
      use content <- unpad(padded, payload)
      use dependency, fragment <- priority_fields(priority_flag == 1, content)
      Decoded(
        Headers(
          stream_id:,
          end_stream:,
          end_headers: end_headers_flag == 1,
          dependency:,
          fragment:,
        ),
        rest,
      )
    }
    0x2 -> {
      use <- require_stream(stream_id)
      case payload {
        <<_exclusive:1, dependency:31, _weight:8>> ->
          Decoded(Priority(stream_id:, dependency:), rest)
        _payload -> StreamError(stream_id, FrameSizeError, rest)
      }
    }
    0x3 -> {
      use <- require_stream(stream_id)
      case payload {
        <<code:32>> ->
          Decoded(RstStream(stream_id:, error: error_code(code)), rest)
        _payload -> ConnectionError(FrameSizeError)
      }
    }
    0x4 -> {
      use <- require_connection(stream_id)
      case end_stream, payload {
        True, <<>> -> Decoded(Settings(ack: True, settings: []), rest)
        True, _payload -> ConnectionError(FrameSizeError)
        False, _payload ->
          case decode_settings(payload, []) {
            Ok(settings) -> Decoded(Settings(ack: False, settings:), rest)
            Error(error) -> ConnectionError(error)
          }
      }
    }
    0x5 -> {
      use <- require_stream(stream_id)
      use content <- unpad(padded, payload)
      case content {
        <<_reserved:1, promised_stream_id:31, fragment:bits>> ->
          Decoded(PushPromise(stream_id:, promised_stream_id:, fragment:), rest)
        _content -> ConnectionError(FrameSizeError)
      }
    }
    0x6 -> {
      use <- require_connection(stream_id)
      case payload {
        <<_opaque:bytes-size(8)>> ->
          Decoded(Ping(ack: end_stream, data: payload), rest)
        _payload -> ConnectionError(FrameSizeError)
      }
    }
    0x7 -> {
      use <- require_connection(stream_id)
      case payload {
        <<_reserved:1, last_stream_id:31, code:32, debug:bits>> ->
          Decoded(
            Goaway(last_stream_id:, error: error_code(code), debug:),
            rest,
          )
        _payload -> ConnectionError(FrameSizeError)
      }
    }
    0x8 ->
      case payload {
        <<_reserved:1, increment:31>> ->
          Decoded(WindowUpdate(stream_id:, increment:), rest)
        _payload -> ConnectionError(FrameSizeError)
      }
    0x9 -> {
      use <- require_stream(stream_id)
      Decoded(
        Continuation(
          stream_id:,
          end_headers: end_headers_flag == 1,
          fragment: payload,
        ),
        rest,
      )
    }
    frame_type -> Decoded(Unknown(stream_id:, frame_type:), rest)
  }
}

fn require_stream(stream_id: Int, decode: fn() -> Decoded) -> Decoded {
  case stream_id {
    0 -> ConnectionError(ProtocolError)
    _stream_id -> decode()
  }
}

fn require_connection(stream_id: Int, decode: fn() -> Decoded) -> Decoded {
  case stream_id {
    0 -> decode()
    _stream_id -> ConnectionError(ProtocolError)
  }
}

fn unpad(
  padded: Bool,
  payload: BitArray,
  decode: fn(BitArray) -> Decoded,
) -> Decoded {
  case padded, payload {
    False, _payload -> decode(payload)
    True, <<pad_length:8, rest:bits>> ->
      case bit_array.byte_size(rest) - pad_length {
        content_size if content_size >= 0 -> {
          let assert <<content:bytes-size(content_size), _padding:bits>> = rest
          decode(content)
        }
        _negative -> ConnectionError(ProtocolError)
      }
    True, _payload -> ConnectionError(FrameSizeError)
  }
}

fn priority_fields(
  present: Bool,
  content: BitArray,
  decode: fn(option.Option(Int), BitArray) -> Decoded,
) -> Decoded {
  case present, content {
    False, _content -> decode(None, content)
    True, <<_exclusive:1, dependency:31, _weight:8, fragment:bits>> ->
      decode(Some(dependency), fragment)
    True, _content -> ConnectionError(FrameSizeError)
  }
}

fn decode_settings(
  payload: BitArray,
  settings: List(Setting),
) -> Result(List(Setting), ErrorCode) {
  case payload {
    <<>> -> Ok(list.reverse(settings))
    <<identifier:16, value:32, payload:bits>> ->
      case decode_setting(identifier, value) {
        Ok(Some(setting)) -> decode_settings(payload, [setting, ..settings])
        Ok(None) -> decode_settings(payload, settings)
        Error(error) -> Error(error)
      }
    _payload -> Error(FrameSizeError)
  }
}

fn decode_setting(
  identifier: Int,
  value: Int,
) -> Result(option.Option(Setting), ErrorCode) {
  case identifier, value {
    0x1, _value -> Ok(Some(HeaderTableSize(value)))
    0x2, 0 -> Ok(Some(EnablePush(False)))
    0x2, 1 -> Ok(Some(EnablePush(True)))
    0x2, _value -> Error(ProtocolError)
    0x3, _value -> Ok(Some(MaxConcurrentStreams(value)))
    0x4, _value if value > max_window_size -> Error(FlowControlError)
    0x4, _value -> Ok(Some(InitialWindowSize(value)))
    0x5, _value if value < min_frame_size || value > max_frame_size ->
      Error(ProtocolError)
    0x5, _value -> Ok(Some(MaxFrameSize(value)))
    0x6, _value -> Ok(Some(MaxHeaderListSize(value)))
    0x8, 0 -> Ok(Some(EnableConnectProtocol(False)))
    0x8, 1 -> Ok(Some(EnableConnectProtocol(True)))
    0x8, _value -> Error(ProtocolError)
    _identifier, _value -> Ok(None)
  }
}

pub fn encode(frame: Frame) -> BitArray {
  case frame {
    Data(stream_id:, end_stream:, data:, size: _size) -> <<
      data_header(stream_id, end_stream, bit_array.byte_size(data)):bits,
      data:bits,
    >>
    Headers(stream_id:, end_stream:, end_headers:, dependency:, fragment:) ->
      case dependency {
        None -> header(0x1, flags(end_stream, end_headers), stream_id, fragment)
        Some(dependency) ->
          header(
            0x1,
            <<0:2, 1:1, 0:2, bit(end_headers):1, 0:1, bit(end_stream):1>>,
            stream_id,
            <<0:1, dependency:31, 15:8, fragment:bits>>,
          )
      }
    Priority(stream_id:, dependency:) ->
      header(0x2, <<0>>, stream_id, <<0:1, dependency:31, 15:8>>)
    RstStream(stream_id:, error:) ->
      header(0x3, <<0>>, stream_id, <<encode_error_code(error):32>>)
    Settings(ack:, settings:) ->
      header(0x4, flags(ack, False), 0, encode_settings(settings))
    PushPromise(stream_id:, promised_stream_id:, fragment:) ->
      header(0x5, flags(False, True), stream_id, <<
        0:1,
        promised_stream_id:31,
        fragment:bits,
      >>)
    Ping(ack:, data:) -> header(0x6, flags(ack, False), 0, data)
    Goaway(last_stream_id:, error:, debug:) ->
      header(0x7, <<0>>, 0, <<
        0:1,
        last_stream_id:31,
        encode_error_code(error):32,
        debug:bits,
      >>)
    WindowUpdate(stream_id:, increment:) ->
      header(0x8, <<0>>, stream_id, <<0:1, increment:31>>)
    Continuation(stream_id:, end_headers:, fragment:) ->
      header(0x9, flags(False, end_headers), stream_id, fragment)
    Unknown(stream_id:, frame_type:) ->
      header(frame_type, <<0>>, stream_id, <<>>)
  }
}

pub fn data_header(stream_id: Int, end_stream: Bool, length: Int) -> BitArray {
  <<length:24, 0x0:8, flags(end_stream, False):bits, 0:1, stream_id:31>>
}

fn header(
  frame_type: Int,
  flags: BitArray,
  stream_id: Int,
  payload: BitArray,
) -> BitArray {
  <<
    bit_array.byte_size(payload):24,
    frame_type:8,
    flags:bits,
    0:1,
    stream_id:31,
    payload:bits,
  >>
}

fn flags(end_stream_or_ack: Bool, end_headers: Bool) -> BitArray {
  <<0:5, bit(end_headers):1, 0:1, bit(end_stream_or_ack):1>>
}

fn bit(value: Bool) -> Int {
  case value {
    True -> 1
    False -> 0
  }
}

fn encode_settings(settings: List(Setting)) -> BitArray {
  use encoded, setting <- list.fold(settings, <<>>)
  let #(identifier, value) = case setting {
    HeaderTableSize(value) -> #(0x1, value)
    EnablePush(value) -> #(0x2, bit(value))
    MaxConcurrentStreams(value) -> #(0x3, value)
    InitialWindowSize(value) -> #(0x4, value)
    MaxFrameSize(value) -> #(0x5, value)
    MaxHeaderListSize(value) -> #(0x6, value)
    EnableConnectProtocol(value) -> #(0x8, bit(value))
  }
  <<encoded:bits, identifier:16, value:32>>
}

fn error_code(code: Int) -> ErrorCode {
  case code {
    0x0 -> NoError
    0x1 -> ProtocolError
    0x2 -> InternalError
    0x3 -> FlowControlError
    0x4 -> SettingsTimeout
    0x5 -> StreamClosed
    0x6 -> FrameSizeError
    0x7 -> RefusedStream
    0x8 -> Cancel
    0x9 -> CompressionError
    0xa -> ConnectError
    0xb -> EnhanceYourCalm
    0xc -> InadequateSecurity
    0xd -> Http11Required
    code -> UnknownErrorCode(code)
  }
}

fn encode_error_code(error: ErrorCode) -> Int {
  case error {
    NoError -> 0x0
    ProtocolError -> 0x1
    InternalError -> 0x2
    FlowControlError -> 0x3
    SettingsTimeout -> 0x4
    StreamClosed -> 0x5
    FrameSizeError -> 0x6
    RefusedStream -> 0x7
    Cancel -> 0x8
    CompressionError -> 0x9
    ConnectError -> 0xa
    EnhanceYourCalm -> 0xb
    InadequateSecurity -> 0xc
    Http11Required -> 0xd
    UnknownErrorCode(code) -> code
  }
}
