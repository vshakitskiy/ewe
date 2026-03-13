import gleam/bit_array
import gleam/bytes_tree
import gleam/list
import gleam/pair
import gleam/result

// Possible error code that appears in RST_STREAM/GOAWAY frame.
// https://www.rfc-editor.org/rfc/rfc9113.html#section-7
pub type ErrorCode {
  // 0x00; Graceful shutdown or any successfull completions.
  NoError
  // 0x01; Unspecific protocol error.
  ProtocolError
  // 0x02; Unexpected internal error.
  InternalError
  // 0x03; Flow control limits were violated.
  FlowControlError
  // 0x04; Settings not acknowledged within timeout.
  SettingsTimeout
  // 0x05; Frame received after stream was half-closed/closed.
  StreamClosed
  // 0x06; Frame size was incorrect for the frame type.
  FrameSizeError
  // 0x07; Stream was refused before any processing occurred.
  RefusedStream
  // 0x08; Stream is no longer needed.
  Cancel
  // 0x09; HPACK decompression failed.
  CompressionError
  // 0x0a; Connection established via CONNECT was reset or abnormally closed.
  ConnectError
  // 0x0b; Peer is generating excessive load. Used for rate limiting.
  EnhanceYourCalm
  // 0x0c; Transport security requirements not met.
  InadequateSecurity
  // 0x0d; Endpoint requires HTTP/1.1 for this request.
  Http11Required
}

pub type Setting {
  // 0x01; Maximum size of the HPACK dynamic table. The initial value is 4096
  // octets.
  HeaderTableSize(Int)
  // 0x02; Whether server push is enabled.
  EnablePush(Int)
  // 0x03; Maximum concurrent streams allowed. There is no limit by default.
  MaxConcurrentStreams(Int)
  // 0x04; Initial flow control window size. The initial value is 65_535 octets.
  InitialWindowSize(Int)
  // 0x05; Maximum frame payload size. The initial value is 16_384 octets. The
  // maximum allowed size is 16_777_215 octets.
  MaxFrameSize(Int)
  // 0x06; Maximum ammount of field section size that the sender is prepared to
  // accept, in units of octets. There is no limit by default.
  MaxHeaderListSize(Int)
}

pub type Frame {
  // 6.1 DATA; Carries request/response data associated with a stream.
  // https://www.rfc-editor.org/rfc/rfc9113.html#section-6.1
  Data(
    // Which stream it belongs to, must be larger than 0.
    stream_id: Int,
    // Flag that indicates that this frame is the last that the endpoint will
    // send for the stream.
    end_stream: Bool,
    // Actual application data.
    data: BitArray,
  )

  // 6.2 HEADERS; Opens a new stream and carries a header or trailer section.
  // Priority is not included since it was deprecated.
  // https://www.rfc-editor.org/rfc/rfc9113.html#section-6.2
  Headers(
    // Which stream it belongs to, must be larger than 0.
    stream_id: Int,
    // Flag that indicates is containing entire field block and is not followed
    // by any CONTINUATION frames. A header with this flag unset must be
    // followed by CONTINUATION frame for the same stream.
    end_headers: Bool,
    // Flag that indicates that this frame is the last that the endpoint will
    // send for the stream.
    end_stream: Bool,
    // HPACK-encoded headers.
    field_block: BitArray,
  )

  // 6.3 PRIORITY; Adjusts stream priority, which is deprecated.
  // https://www.rfc-editor.org/rfc/rfc9113.html#section-6.3
  Priority(
    // Which stream it belongs to, must be larger than 0.
    stream_id: Int,
    // Flag that shows whenever stream becomes the sole dependency or not.
    exclusive: Bool,
    // Stream identifier we depend on.
    dependency: Int,
    // Number from 1 to 256, where higher means more priority.
    weight: Int,
  )

  // 6.4 RST_STREAM; Allows termination of a stream with an error code.
  // https://www.rfc-editor.org/rfc/rfc9113.html#section-6.4
  RstStream(
    // Which stream it belongs to, must be larger than 0.
    stream_id: Int,
    // Reason why we are killing the stream.
    code: ErrorCode,
  )

  // 6.5 SETTINGS; Consists of zero or more settings for a connection.
  // https://www.rfc-editor.org/rfc/rfc9113.html#section-6.5
  Settings(settings: List(Setting))

  // 6.5 SETTINGS; Acknowledges the receipt of a SETTINGS frame.
  // https://www.rfc-editor.org/rfc/rfc9113.html#section-6.5
  SettingsAck

  // 6.6 PUSH_PROMISE; Notifies the peer endpoint in advance of streams the
  // sender intends to initiate.
  // https://www.rfc-editor.org/rfc/rfc9113.html#section-6.6
  PushPromise(
    // Which stream it belongs to, must be larger than 0.
    stream_id: Int,
    // The new stream identificator for the pushed resource.
    promised_stream_id: Int,
    // Flag that indicates is containing entire field block and is not followed
    // by any CONTINUATION frames. A header with this flag unset must be
    // followed by CONTINUATION frame for the same stream.
    end_headers: Bool,
    // HPACK-encoded headers for the pushed request.
    field_block: BitArray,
  )

  // 6.7 PING; Checks if the connection is alive, measuring a minimal round-trip
  // time from the sender.
  // https://www.rfc-editor.org/rfc/rfc9113.html#section-6.7
  Ping(
    // Flag that indicates that this frame is a PING response.
    ack: Bool,
    // 8 octets of opaque data, PING response must have identical payload.
    data: BitArray,
  )

  // 6.8 GOAWAY; initiates shutdown of a connection or signals serious error
  // conditions. Allows an endpoint to gracefully stop accepting new streams
  // while finishing the ones in progress.
  // https://www.rfc-editor.org/rfc/rfc9113.html#section-6.8
  GoAway(
    // Highest stream identificator we have processed. Any streams with id more
    // than this value will not be processed.
    last_stream_id: Int,
    // Reason why we are killing the connection.
    code: ErrorCode,
    // Optional human-readable debug information.
    debug: BitArray,
  )

  // 6.9 WINDOW_UPDATE; Increases the flow control window, allowing sender to
  // transmit more data bytes on each individual stream and on the entire
  // connection
  // https://www.rfc-editor.org/rfc/rfc9113.html#section-6.9
  WindowUpdate(
    // Which stream it belongs to. For connection-level updates value zero is
    // used.
    stream_id: Int,
    // Amount of bytes that is being added to the window. Must be from 1 to
    // 2^31 - 1 octets.
    increment: Int,
  )

  // 6.10; CONTINUATION; Continues a sequence of field block fragments.
  // https://www.rfc-editor.org/rfc/rfc9113.html#section-6.10
  Continuation(
    // Which stream it belongs to, must be larger than 0 and preceding previous
    // frame.
    stream_id: Int,
    // Flag that indicates is containing entire field block and is not followed
    // by any CONTINUATION frames. A header with this flag unset must be
    // followed by CONTINUATION frame for the same stream.
    end_headers: Bool,
    // Next fragment of HPACK-encoded headers.
    field_block: BitArray,
  )

  // Unknown frame, must be ignored.
  Unknown
}

pub type DecodeError {
  // Not enough bytes to parse a complete frame.
  Incomplete
  // Frame violates protocol rules.
  ProtocolViolation(ViolationError)
  // Payload doesn't match expected format.
  InvalidPayload(PayloadError)
}

pub type ViolationError {
  // Frame cannot be on a stream 0.
  FrameOnControlStream
  // Stream cannot depend on itself.
  StreamDependingOnItself
  // Frame must be on a stream 0.
  FrameOnWrongStream
  // A setting value violates protocol limits.
  InvalidSettingValue
  // INITIAL_WINDOW_SIZE exceeded the maximum allowed limit of 2^31 - 1.
  InitialWindowSizeOverflow
  // WINDOW_UPDATE increment cannot be 0.
  InvalidWindowUpdateValue
}

pub type PayloadError {
  // Padding exceeds payload size.
  ExceedingPadding
  // Padded frame too short.
  TooShort
  // Used when a frame is strictly required to be a specific length.
  BadSize
  // SETTINGS with ACK flag must have empty payload.
  AckWithPayload
}

pub fn decode(data: BitArray) {
  // HTTP Frame {
  //   Length (24),
  //   Type (8),
  //   Flags (8),
  //   Reserved (1),
  //   Stream Identifier (31),
  //   Frame Payload (..),
  // }
  case data {
    <<
      length:24,
      type_:8,
      _unused:2,
      priority:1,
      _unused:1,
      padded:1,
      end_headers:1,
      _unused:1,
      ack_end_stream:1,
      _reserved:1,
      stream_id:31,
      payload:bytes-size(length),
      remaining:bits,
    >> -> {
      let ack_end_stream = ack_end_stream == 1
      do_decode(
        stream_id:,
        type_:,
        priority: priority == 1,
        padded: padded == 1,
        end_headers: end_headers == 1,
        ack: ack_end_stream,
        end_stream: ack_end_stream,
        payload:,
      )
      |> result.map(pair.new(_, remaining))
    }
    _ -> Error(Incomplete)
  }
}

fn do_decode(
  stream_id stream_id: Int,
  type_ type_: Int,
  priority priority: Bool,
  padded padded: Bool,
  end_headers end_headers: Bool,
  ack ack: Bool,
  end_stream end_stream: Bool,
  payload payload: BitArray,
) -> Result(Frame, DecodeError) {
  case type_ {
    0x00 -> decode_data(stream_id:, padded:, end_stream:, payload:)
    0x01 ->
      decode_headers(
        stream_id:,
        priority:,
        padded:,
        end_headers:,
        end_stream:,
        payload:,
      )
    0x02 -> decode_priority(stream_id:, payload:)
    0x03 -> decode_rst_stream(stream_id:, payload:)
    0x04 -> decode_settings(stream_id:, ack:, payload:)
    0x05 -> decode_push_promise(stream_id:, padded:, end_headers:, payload:)
    0x06 -> decode_ping(stream_id:, ack:, payload:)
    0x07 -> decode_goaway(stream_id:, payload:)
    0x08 -> decode_window_update(stream_id:, payload:)
    0x09 -> decode_continuation(stream_id:, end_headers:, payload:)
    _unknown -> Ok(Unknown)
  }
}

fn decode_data(
  stream_id stream_id: Int,
  padded padded: Bool,
  end_stream end_stream: Bool,
  payload payload: BitArray,
) -> Result(Frame, DecodeError) {
  case stream_id {
    0 -> Error(ProtocolViolation(FrameOnControlStream))
    _ -> {
      use data <- result.try(strip_padding(payload, padded))
      Ok(Data(stream_id:, end_stream:, data:))
    }
  }
}

fn decode_headers(
  stream_id stream_id: Int,
  priority priority: Bool,
  padded padded: Bool,
  end_headers end_headers: Bool,
  end_stream end_stream: Bool,
  payload payload: BitArray,
) -> Result(Frame, DecodeError) {
  case stream_id, priority {
    0, _ -> Error(ProtocolViolation(FrameOnControlStream))
    _, False -> {
      use field_block <- result.try(strip_padding(payload, padded))
      Ok(Headers(stream_id:, end_headers:, end_stream:, field_block:))
    }
    _, True -> {
      use payload <- result.try(strip_padding(payload, padded))

      case payload {
        // Even tho RFC 9113 deprecated priority fields, I am still going to
        // be strict here.
        <<_exclusive:1, dependency:31, _weight:8, _field_block:bits>>
          if dependency == stream_id
        -> Error(ProtocolViolation(StreamDependingOnItself))
        <<_exclusive:1, _dependency:31, _weight:8, field_block:bits>> ->
          Ok(Headers(stream_id:, end_headers:, end_stream:, field_block:))
        _ -> Error(InvalidPayload(TooShort))
      }
    }
  }
}

fn decode_priority(
  stream_id stream_id: Int,
  payload payload: BitArray,
) -> Result(Frame, DecodeError) {
  case stream_id, payload {
    0, _ -> Error(ProtocolViolation(FrameOnControlStream))
    _, <<_exclusive:1, dependency:31, _weight:8>> if dependency == stream_id ->
      Error(ProtocolViolation(StreamDependingOnItself))
    _, <<exclusive:1, dependency:31, weight:8>> ->
      Ok(Priority(
        stream_id:,
        exclusive: exclusive == 1,
        dependency:,
        weight: weight + 1,
      ))
    _, _ -> Error(InvalidPayload(TooShort))
  }
}

fn decode_rst_stream(
  stream_id stream_id: Int,
  payload payload: BitArray,
) -> Result(Frame, DecodeError) {
  case stream_id, payload {
    0, _ -> Error(ProtocolViolation(FrameOnControlStream))
    _, <<code:32>> -> Ok(RstStream(stream_id:, code: decode_code(code)))
    _, _ -> Error(InvalidPayload(BadSize))
  }
}

fn decode_code(code: Int) -> ErrorCode {
  case code {
    0x00 -> NoError
    0x01 -> ProtocolError
    0x02 -> InternalError
    0x03 -> FlowControlError
    0x04 -> SettingsTimeout
    0x05 -> StreamClosed
    0x06 -> FrameSizeError
    0x07 -> RefusedStream
    0x08 -> Cancel
    0x09 -> CompressionError
    0x0a -> ConnectError
    0x0b -> EnhanceYourCalm
    0x0c -> InadequateSecurity
    0x0d -> Http11Required
    _ -> InternalError
  }
}

fn decode_settings(
  stream_id stream_id: Int,
  ack ack: Bool,
  payload payload: BitArray,
) -> Result(Frame, DecodeError) {
  case stream_id, ack, bit_array.byte_size(payload) {
    0, True, 0 -> Ok(SettingsAck)
    0, True, _ -> Error(InvalidPayload(AckWithPayload))
    0, False, _ -> do_decode_settings(payload, [])
    _, _, _ -> Error(ProtocolViolation(FrameOnWrongStream))
  }
}

pub fn decode_settings_payload(payload: BitArray) -> Result(Frame, DecodeError) {
  do_decode_settings(payload, [])
}

fn do_decode_settings(
  payload: BitArray,
  acc: List(Setting),
) -> Result(Frame, DecodeError) {
  case payload {
    <<>> -> Ok(Settings(settings: list.reverse(acc)))
    <<id:16, value:32, remaining:bits>> -> {
      case id, value {
        0x01, _ ->
          do_decode_settings(remaining, [HeaderTableSize(value), ..acc])

        0x02, 1 | 0x02, 0 ->
          do_decode_settings(remaining, [EnablePush(value), ..acc])
        0x02, _ -> Error(ProtocolViolation(InvalidSettingValue))

        0x03, _ ->
          do_decode_settings(remaining, [MaxConcurrentStreams(value), ..acc])

        0x04, value if value <= 2_147_483_647 ->
          do_decode_settings(remaining, [InitialWindowSize(value), ..acc])
        0x04, _ -> Error(ProtocolViolation(InitialWindowSizeOverflow))

        0x05, value if value >= 16_384 && value <= 16_777_215 ->
          do_decode_settings(remaining, [MaxFrameSize(value), ..acc])
        0x05, _ -> Error(ProtocolViolation(InvalidSettingValue))

        0x06, _ ->
          do_decode_settings(remaining, [MaxHeaderListSize(value), ..acc])

        _, _ -> do_decode_settings(remaining, acc)
      }
    }
    _ -> Error(InvalidPayload(BadSize))
  }
}

fn decode_push_promise(
  stream_id stream_id: Int,
  padded padded: Bool,
  end_headers end_headers: Bool,
  payload payload: BitArray,
) -> Result(Frame, DecodeError) {
  case stream_id, payload {
    0, _ -> Error(ProtocolViolation(FrameOnControlStream))
    _, _ -> {
      use payload <- result.try(strip_padding(payload, padded))
      case payload {
        <<_reserved:1, promised_stream_id:31, field_block:bits>> ->
          Ok(PushPromise(
            stream_id:,
            promised_stream_id:,
            end_headers:,
            field_block:,
          ))
        _ -> Error(InvalidPayload(TooShort))
      }
    }
  }
}

fn decode_ping(
  stream_id stream_id: Int,
  ack ack: Bool,
  payload payload: BitArray,
) -> Result(Frame, DecodeError) {
  case stream_id, bit_array.byte_size(payload) {
    0, 8 -> Ok(Ping(ack:, data: payload))
    0, _ -> Error(InvalidPayload(BadSize))
    _, _ -> Error(ProtocolViolation(FrameOnWrongStream))
  }
}

fn decode_goaway(
  stream_id stream_id: Int,
  payload payload: BitArray,
) -> Result(Frame, DecodeError) {
  case stream_id, payload {
    0, <<_reserved:1, last_stream_id:31, code:32, debug:bits>> ->
      Ok(GoAway(last_stream_id:, code: decode_code(code), debug:))
    0, _ -> Error(InvalidPayload(TooShort))
    _, _ -> Error(ProtocolViolation(FrameOnWrongStream))
  }
}

fn decode_window_update(
  stream_id stream_id: Int,
  payload payload: BitArray,
) -> Result(Frame, DecodeError) {
  case payload {
    <<_reserved:1, 0:31>> -> Error(ProtocolViolation(InvalidWindowUpdateValue))
    <<_reserved:1, increment:31>> -> Ok(WindowUpdate(stream_id:, increment:))
    _ -> Error(InvalidPayload(BadSize))
  }
}

fn decode_continuation(
  stream_id stream_id: Int,
  end_headers end_headers: Bool,
  payload payload: BitArray,
) -> Result(Frame, DecodeError) {
  case stream_id {
    0 -> Error(ProtocolViolation(FrameOnControlStream))
    _ -> Ok(Continuation(stream_id:, end_headers:, field_block: payload))
  }
}

fn strip_padding(
  payload: BitArray,
  padded: Bool,
) -> Result(BitArray, DecodeError) {
  case padded, payload {
    False, _ -> Ok(payload)
    True, <<pad_length:8, remaining:bits>> -> {
      let data_length = bit_array.byte_size(remaining) - pad_length
      case remaining {
        <<data:bytes-size(data_length), _padding:bits>> -> Ok(data)
        _ -> Error(InvalidPayload(ExceedingPadding))
      }
    }
    True, _ -> Error(InvalidPayload(TooShort))
  }
}

pub fn encode(frame: Frame) -> bytes_tree.BytesTree {
  case frame {
    Data(stream_id:, end_stream:, data:) ->
      <<0:7, encode_flag(end_stream):1>>
      |> encode_frame(type_: 0x00, stream_id:, payload: data)

    Headers(stream_id:, end_headers:, end_stream:, field_block:) ->
      <<0:5, encode_flag(end_headers):1, 0:1, encode_flag(end_stream):1>>
      |> encode_frame(type_: 0x01, stream_id:, payload: field_block)

    Priority(stream_id:, exclusive:, dependency:, weight:) ->
      <<encode_flag(exclusive):1, dependency:31, { weight - 1 }:8>>
      |> encode_frame(type_: 0x02, flags: <<0:8>>, stream_id:)

    RstStream(stream_id:, code:) ->
      <<encode_code(code):32>>
      |> encode_frame(type_: 0x03, flags: <<0:8>>, stream_id:)

    Settings(settings:) ->
      encode_settings_payload(settings, <<>>)
      |> encode_frame(type_: 0x04, flags: <<0:8>>, stream_id: 0)
    SettingsAck ->
      <<0:7, 1:1>>
      |> encode_frame(type_: 0x04, stream_id: 0, payload: <<>>)

    PushPromise(stream_id:, promised_stream_id:, end_headers:, field_block:) ->
      encode_frame(
        type_: 0x05,
        flags: <<0:5, encode_flag(end_headers):1, 0:2>>,
        stream_id:,
        payload: <<0:1, promised_stream_id:31, field_block:bits>>,
      )

    Ping(ack:, data:) ->
      <<0:7, encode_flag(ack):1>>
      |> encode_frame(type_: 0x06, stream_id: 0, payload: data)

    GoAway(last_stream_id:, code:, debug:) ->
      <<0:1, last_stream_id:31, encode_code(code):32, debug:bits>>
      |> encode_frame(type_: 0x07, flags: <<0:8>>, stream_id: 0)

    WindowUpdate(stream_id:, increment:) ->
      <<0:1, increment:31>>
      |> encode_frame(type_: 0x08, flags: <<0:8>>, stream_id:)

    Continuation(stream_id:, end_headers:, field_block:) ->
      <<0:5, encode_flag(end_headers):1, 0:2>>
      |> encode_frame(type_: 0x09, stream_id:, payload: field_block)

    Unknown -> bytes_tree.new()
  }
}

fn encode_code(code: ErrorCode) -> Int {
  case code {
    NoError -> 0x00
    ProtocolError -> 0x01
    InternalError -> 0x02
    FlowControlError -> 0x03
    SettingsTimeout -> 0x04
    StreamClosed -> 0x05
    FrameSizeError -> 0x06
    RefusedStream -> 0x07
    Cancel -> 0x08
    CompressionError -> 0x09
    ConnectError -> 0x0a
    EnhanceYourCalm -> 0x0b
    InadequateSecurity -> 0x0c
    Http11Required -> 0x0d
  }
}

fn encode_settings_payload(settings: List(Setting), acc: BitArray) -> BitArray {
  case settings {
    [] -> acc
    [setting, ..remaining] -> {
      let #(id, value) = case setting {
        HeaderTableSize(value) -> #(0x01, value)
        EnablePush(value) -> #(0x02, value)
        MaxConcurrentStreams(value) -> #(0x03, value)
        InitialWindowSize(value) -> #(0x04, value)
        MaxFrameSize(value) -> #(0x05, value)
        MaxHeaderListSize(value) -> #(0x06, value)
      }

      encode_settings_payload(remaining, <<acc:bits, id:16, value:32>>)
    }
  }
}

fn encode_frame(
  type_ type_: Int,
  flags flags: BitArray,
  stream_id stream_id: Int,
  payload payload: BitArray,
) -> bytes_tree.BytesTree {
  <<
    bit_array.byte_size(payload):24,
    type_:8,
    flags:bits,
    0:1,
    stream_id:31,
    payload:bits,
  >>
  |> bytes_tree.from_bit_array
}

fn encode_flag(flag: Bool) -> Int {
  case flag {
    True -> 1
    False -> 0
  }
}
