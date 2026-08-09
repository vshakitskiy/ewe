import gleam/bit_array
import gleam/list
import gleam/result

pub type Frame {
  Data(
    stream_id: Int,
    end_stream: Bool,
    payload: BitArray,
    flow_control_size: Int,
  )
  Headers(
    stream_id: Int,
    end_stream: Bool,
    end_headers: Bool,
    payload: BitArray,
  )
  Priority(stream_id: Int)
  RstStream(stream_id: Int, error_code: ErrorCode)
  Settings(stream_id: Int, ack: Bool, params: List(Setting))
  PushPromise(stream_id: Int, payload: BitArray)
  Ping(stream_id: Int, ack: Bool, opaque_data: BitArray)
  Goaway(
    stream_id: Int,
    last_stream_id: Int,
    error_code: ErrorCode,
    debug_data: BitArray,
  )
  WindowUpdate(stream_id: Int, increment: Int)
  Continuation(stream_id: Int, end_headers: Bool, payload: BitArray)
  Unknown(stream_id: Int, frame_type: Int, payload: BitArray)
}

pub const settings_ack = Settings(0, True, [])

pub type Setting {
  HeaderTableSize(Int)
  EnablePush(Bool)
  MaxConcurrentStreams(Int)
  InitialWindowSize(Int)
  MaxFrameSize(Int)
  MaxHeaderListSize(Int)
  UnknownSetting(Int, Int)
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

pub type FrameError {
  Incomplete
  Violation(ErrorCode)
}

pub fn decode(
  data: BitArray,
  max_frame_size: Int,
) -> Result(#(Frame, BitArray), FrameError) {
  case data {
    <<
      length:size(24),
      type_:8,
      _unused_flags:2,
      priority:1,
      _unused_flag_high:1,
      padded:1,
      end_headers:1,
      _unused_flag_low:1,
      end_stream_or_ack:1,
      _reserved_bit:1,
      stream_id:31,
      remaining:bits,
    >> ->
      case length > max_frame_size {
        True -> Error(Violation(FrameSizeError))
        False ->
          case remaining {
            <<payload:bytes-size(length), remaining:bits>> -> {
              use frame <- result.try(decode_payload(
                type_,
                stream_id,
                end_stream_or_ack == 1,
                end_headers == 1,
                padded == 1,
                priority == 1,
                payload,
              ))
              Ok(#(frame, remaining))
            }
            _remaining -> Error(Incomplete)
          }
      }
    _data -> Error(Incomplete)
  }
}

fn decode_payload(
  type_: Int,
  stream_id: Int,
  end_stream_or_ack: Bool,
  end_headers: Bool,
  padded: Bool,
  priority: Bool,
  payload: BitArray,
) -> Result(Frame, FrameError) {
  case type_ {
    0x0 -> {
      use content <- result.try(strip_padding(padded, payload))
      Ok(Data(
        stream_id:,
        end_stream: end_stream_or_ack,
        payload: content,
        flow_control_size: bit_array.byte_size(payload),
      ))
    }
    0x1 -> {
      use content <- result.try(strip_padding(padded, payload))
      use header_block <- result.try(strip_priority(
        priority,
        stream_id,
        content,
      ))
      Ok(Headers(
        stream_id:,
        end_stream: end_stream_or_ack,
        end_headers:,
        payload: header_block,
      ))
    }
    0x2 ->
      case payload {
        <<_exclusive:1, stream_dependency:31, _weight:8>> ->
          // Stream 0 can't be prioritized and a stream depending on itself
          // is a cycle of one which both are protocol errors.
          case stream_id == 0, stream_dependency == stream_id {
            True, _self_dependent | _on_stream_zero, True ->
              Error(Violation(ProtocolError))
            False, False -> Ok(Priority(stream_id:))
          }
        _payload -> Error(Violation(FrameSizeError))
      }
    0x3 ->
      case stream_id == 0, payload {
        True, _payload -> Error(Violation(ProtocolError))
        False, <<error_code:32>> ->
          Ok(RstStream(stream_id:, error_code: decode_error_code(error_code)))
        False, _payload -> Error(Violation(FrameSizeError))
      }
    0x4 ->
      // SETTINGS ACKs never carry params.
      case end_stream_or_ack, payload {
        True, <<>> -> Ok(Settings(stream_id, True, []))
        True, _payload -> Error(Violation(FrameSizeError))
        False, _payload -> {
          use params <- result.try(decode_settings(payload, []))
          Ok(Settings(stream_id:, ack: False, params:))
        }
      }
    0x5 -> {
      use content <- result.try(strip_padding(padded, payload))
      Ok(PushPromise(stream_id:, payload: content))
    }
    0x6 ->
      case payload {
        <<opaque_data:bytes-size(8)>> ->
          Ok(Ping(stream_id:, ack: end_stream_or_ack, opaque_data:))
        _payload -> Error(Violation(FrameSizeError))
      }
    0x7 ->
      case stream_id == 0, payload {
        False, _payload -> Error(Violation(ProtocolError))
        True,
          <<_reserved_bit:1, last_stream_id:31, error_code:32, debug_data:bits>>
        ->
          Ok(Goaway(
            stream_id:,
            last_stream_id:,
            error_code: decode_error_code(error_code),
            debug_data:,
          ))
        True, _payload -> Error(Violation(FrameSizeError))
      }
    0x8 ->
      case payload {
        <<_reserved_bit:1, increment:31>> ->
          Ok(WindowUpdate(stream_id:, increment:))
        _payload -> Error(Violation(FrameSizeError))
      }
    0x9 -> Ok(Continuation(stream_id:, end_headers:, payload:))
    other -> Ok(Unknown(stream_id, other, payload))
  }
}

fn strip_padding(
  padded: Bool,
  payload: BitArray,
) -> Result(BitArray, FrameError) {
  case padded {
    False -> Ok(payload)
    True ->
      case payload {
        <<pad_length:8, remaining:bits>> -> {
          let content_length = bit_array.byte_size(remaining) - pad_length
          // A client can claim more padding than bytes actually follow
          case content_length >= 0 {
            True ->
              case remaining {
                <<content:bytes-size(content_length), _padding:bits>> ->
                  Ok(content)
                _remaining -> Error(Violation(FrameSizeError))
              }
            False -> Error(Violation(ProtocolError))
          }
        }
        _payload -> Error(Violation(FrameSizeError))
      }
  }
}

fn strip_priority(
  priority: Bool,
  stream_id: Int,
  payload: BitArray,
) -> Result(BitArray, FrameError) {
  case priority {
    False -> Ok(payload)
    True ->
      case payload {
        <<_exclusive:1, stream_dependency:31, _weight:8, remaining:bits>> ->
          case stream_dependency == stream_id {
            True -> Error(Violation(ProtocolError))
            False -> Ok(remaining)
          }
        _payload -> Error(Violation(FrameSizeError))
      }
  }
}

fn decode_settings(
  payload: BitArray,
  acc: List(Setting),
) -> Result(List(Setting), FrameError) {
  case payload {
    <<>> -> Ok(list.reverse(acc))
    <<id:16, value:32, remaining:bits>> -> {
      use setting <- result.try(decode_setting(id, value))
      decode_settings(remaining, [setting, ..acc])
    }
    _payload -> Error(Violation(FrameSizeError))
  }
}

const max_window_size = 2_147_483_647

const min_max_frame_size = 16_384

const max_max_frame_size = 16_777_215

fn decode_setting(id: Int, value: Int) -> Result(Setting, FrameError) {
  case id {
    0x1 -> Ok(HeaderTableSize(value))
    0x2 ->
      case value {
        0 -> Ok(EnablePush(False))
        1 -> Ok(EnablePush(True))
        _value -> Error(Violation(ProtocolError))
      }
    0x3 -> Ok(MaxConcurrentStreams(value))
    0x4 ->
      case value > max_window_size {
        True -> Error(Violation(FlowControlError))
        False -> Ok(InitialWindowSize(value))
      }
    0x5 ->
      case value < min_max_frame_size || value > max_max_frame_size {
        True -> Error(Violation(ProtocolError))
        False -> Ok(MaxFrameSize(value))
      }
    0x6 -> Ok(MaxHeaderListSize(value))
    other -> Ok(UnknownSetting(other, value))
  }
}

fn decode_error_code(code: Int) -> ErrorCode {
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
    other -> UnknownErrorCode(other)
  }
}

pub fn encode(frame: Frame) -> BitArray {
  let #(type_, flags, payload) = encode_payload(frame)
  let length = bit_array.byte_size(payload)
  <<
    length:size(24),
    type_:8,
    flags:bits,
    0:1,
    frame.stream_id:31,
    payload:bits,
  >>
}

fn encode_payload(frame: Frame) -> #(Int, BitArray, BitArray) {
  case frame {
    Data(end_stream:, payload:, ..) -> #(
      0x0,
      encode_flags(end_stream, False),
      payload,
    )
    Headers(end_stream:, end_headers:, payload:, ..) -> #(
      0x1,
      encode_flags(end_stream, end_headers),
      payload,
    )
    Priority(..) -> #(0x2, encode_flags(False, False), <<0:1, 0:31, 0:8>>)
    RstStream(error_code:, ..) -> #(0x3, encode_flags(False, False), <<
      encode_error_code(error_code):32,
    >>)
    Settings(ack:, params:, ..) -> #(
      0x4,
      encode_flags(ack, False),
      encode_settings(params),
    )
    PushPromise(payload:, ..) -> #(0x5, encode_flags(False, False), payload)
    Ping(ack:, opaque_data:, ..) -> #(
      0x6,
      encode_flags(ack, False),
      opaque_data,
    )
    Goaway(last_stream_id:, error_code:, debug_data:, ..) -> #(
      0x7,
      encode_flags(False, False),
      <<
        0:1,
        last_stream_id:31,
        encode_error_code(error_code):32,
        debug_data:bits,
      >>,
    )
    WindowUpdate(increment:, ..) -> #(0x8, encode_flags(False, False), <<
      0:1,
      increment:31,
    >>)
    Continuation(end_headers:, payload:, ..) -> #(
      0x9,
      encode_flags(False, end_headers),
      payload,
    )
    Unknown(frame_type:, payload:, ..) -> #(frame_type, <<0:8>>, payload)
  }
}

fn encode_flags(end_stream_or_ack: Bool, end_headers: Bool) -> BitArray {
  <<0:5, bit(end_headers):1, 0:1, bit(end_stream_or_ack):1>>
}

/// Frames a DATA payload without copying it into the header, so a body already
/// held as a `BytesTree` can be written straight after this.
pub fn encode_data_header(
  stream_id: Int,
  end_stream: Bool,
  length: Int,
) -> BitArray {
  <<
    length:size(24),
    0x0:8,
    encode_flags(end_stream, False):bits,
    0:1,
    stream_id:31,
  >>
}

fn bit(value: Bool) -> Int {
  case value {
    True -> 1
    False -> 0
  }
}

fn encode_settings(params: List(Setting)) -> BitArray {
  case params {
    [] -> <<>>
    [setting, ..rest] -> {
      let #(id, value) = encode_setting(setting)
      <<id:16, value:32, encode_settings(rest):bits>>
    }
  }
}

fn encode_setting(setting: Setting) -> #(Int, Int) {
  case setting {
    HeaderTableSize(value) -> #(0x1, value)
    EnablePush(value) -> #(0x2, bit(value))
    MaxConcurrentStreams(value) -> #(0x3, value)
    InitialWindowSize(value) -> #(0x4, value)
    MaxFrameSize(value) -> #(0x5, value)
    MaxHeaderListSize(value) -> #(0x6, value)
    UnknownSetting(id, value) -> #(id, value)
  }
}

fn encode_error_code(code: ErrorCode) -> Int {
  case code {
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
    UnknownErrorCode(other) -> other
  }
}
