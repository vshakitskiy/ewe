import gleam/bit_array
import gleam/pair
import gleam/result

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
  InvalidFrameOnConnectionControlStream
  // Stream cannot depend on itself.
  StreamDependingOnItself
}

pub type PayloadError {
  // Padding exceeds payload size.
  ExceedingPadding
  // Padded frame too short.
  TooShort
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
    0 -> Error(ProtocolViolation(InvalidFrameOnConnectionControlStream))
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
    0, _ -> Error(ProtocolViolation(InvalidFrameOnConnectionControlStream))
    _, False -> {
      use field_block <- result.try(strip_padding(payload, padded))
      Ok(Headers(stream_id:, end_headers:, end_stream:, field_block:))
    }
    _, True -> {
      use payload <- result.try(strip_padding(payload, padded))

      case payload {
        // Even tho RFC 9113 deprecated priority fields, I am still going to
        // strict there.
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
