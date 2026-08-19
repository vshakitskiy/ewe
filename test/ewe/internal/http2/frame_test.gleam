import ewe/internal/http2/frame
import gleam/bit_array

pub fn data_frame_test() {
  assert <<0:size(24), 0x0:8, 0x1:8, 0:1, 1:31, "":utf8>>
    |> frame.decode(16_384)
    == Ok(#(frame.Data(1, True, <<>>, 0), <<>>))
}

pub fn data_frame_with_payload_test() {
  assert <<5:size(24), 0x0:8, 0x0:8, 0:1, 3:31, "hello":utf8, "extra":utf8>>
    |> frame.decode(16_384)
    == Ok(#(frame.Data(3, False, <<"hello":utf8>>, 5), <<"extra":utf8>>))
}

pub fn incomplete_header_test() {
  assert frame.decode(<<0:size(24), 0x0:8>>, 16_384) == Error(frame.Incomplete)
}

pub fn incomplete_payload_test() {
  assert <<5:size(24), 0x0:8, 0x0:8, 0:1, 1:31, "hi":utf8>>
    |> frame.decode(16_384)
    == Error(frame.Incomplete)
}

pub fn settings_frame_test() {
  assert <<
      12:size(24), 0x4:8, 0x0:8, 0:1, 0:31, 0x1:16, 4096:32, 0x3:16, 100:32,
    >>
    |> frame.decode(16_384)
    == Ok(
      #(
        frame.Settings(0, False, [
          frame.HeaderTableSize(4096),
          frame.MaxConcurrentStreams(100),
        ]),
        <<>>,
      ),
    )
}

pub fn settings_ack_test() {
  assert <<0:size(24), 0x4:8, 0x1:8, 0:1, 0:31>>
    |> frame.decode(16_384)
    == Ok(#(frame.Settings(0, True, []), <<>>))
}

pub fn settings_ack_with_payload_is_frame_size_error_test() {
  assert <<6:size(24), 0x4:8, 0x1:8, 0:1, 0:31, 0x1:16, 4096:32>>
    |> frame.decode(16_384)
    == Error(frame.Violation(frame.FrameSizeError))
}

pub fn padded_data_frame_test() {
  assert <<5:size(24), 0x0:8, 0x8:8, 0:1, 1:31, 2:8, "hi":utf8, 0:8, 0:8>>
    |> frame.decode(16_384)
    == Ok(#(frame.Data(1, False, <<"hi":utf8>>, 5), <<>>))
}

pub fn headers_with_priority_test() {
  assert <<
      10:size(24), 0x1:8, 0x24:8, 0:1, 1:31, 0:1, 0:31, 16:8, "block":utf8,
    >>
    |> frame.decode(16_384)
    == Ok(#(frame.Headers(1, False, True, <<"block":utf8>>), <<>>))
}

pub fn window_update_test() {
  assert <<4:size(24), 0x8:8, 0x0:8, 0:1, 5:31, 0:1, 1000:31>>
    |> frame.decode(16_384)
    == Ok(#(frame.WindowUpdate(5, 1000), <<>>))
}

pub fn unknown_frame_type_test() {
  assert <<3:size(24), 0xf:8, 0x0:8, 0:1, 0:31, "abc":utf8>>
    |> frame.decode(16_384)
    == Ok(#(frame.Unknown(0, 0xf, <<"abc":utf8>>), <<>>))
}

pub fn rst_stream_error_code_test() {
  assert <<4:size(24), 0x3:8, 0x0:8, 0:1, 1:31, 0x1:32>>
    |> frame.decode(16_384)
    == Ok(#(frame.RstStream(1, frame.ProtocolError), <<>>))
}

pub fn rst_stream_wrong_size_test() {
  assert <<2:size(24), 0x3:8, 0x0:8, 0:1, 1:31, 0:16>>
    |> frame.decode(16_384)
    == Error(frame.Violation(frame.FrameSizeError))
}

pub fn goaway_unknown_error_code_test() {
  assert <<8:size(24), 0x7:8, 0x0:8, 0:1, 0:31, 0:1, 3:31, 999:32>>
    |> frame.decode(16_384)
    == Ok(#(frame.Goaway(0, 3, frame.UnknownErrorCode(999), <<>>), <<>>))
}

pub fn settings_enable_push_test() {
  assert <<6:size(24), 0x4:8, 0x0:8, 0:1, 0:31, 0x2:16, 0:32>>
    |> frame.decode(16_384)
    == Ok(#(frame.Settings(0, False, [frame.EnablePush(False)]), <<>>))
}

pub fn settings_enable_push_invalid_value_test() {
  assert <<6:size(24), 0x4:8, 0x0:8, 0:1, 0:31, 0x2:16, 2:32>>
    |> frame.decode(16_384)
    == Error(frame.Violation(frame.ProtocolError))
}

pub fn settings_initial_window_size_overflow_test() {
  assert <<6:size(24), 0x4:8, 0x0:8, 0:1, 0:31, 0x4:16, 2_147_483_648:32>>
    |> frame.decode(16_384)
    == Error(frame.Violation(frame.FlowControlError))
}

pub fn settings_max_frame_size_out_of_range_test() {
  assert <<6:size(24), 0x4:8, 0x0:8, 0:1, 0:31, 0x5:16, 100:32>>
    |> frame.decode(16_384)
    == Error(frame.Violation(frame.ProtocolError))
}

pub fn padding_exceeds_payload_is_protocol_error_test() {
  assert <<3:size(24), 0x0:8, 0x8:8, 0:1, 1:31, 10:8, "hi":utf8>>
    |> frame.decode(16_384)
    == Error(frame.Violation(frame.ProtocolError))
}

pub fn frame_exceeding_max_frame_size_is_frame_size_error_test() {
  assert <<5:size(24), 0x0:8, 0x0:8, 0:1, 3:31, "hello":utf8, "extra":utf8>>
    |> frame.decode(4)
    == Error(frame.Violation(frame.FrameSizeError))
}

pub fn priority_frame_with_stream_id_zero_is_protocol_error_test() {
  assert <<5:size(24), 0x2:8, 0x0:8, 0:1, 0:31, 0:1, 2:31, 16:8>>
    |> frame.decode(16_384)
    == Error(frame.Violation(frame.ProtocolError))
}

pub fn priority_frame_self_dependency_is_protocol_error_test() {
  assert <<5:size(24), 0x2:8, 0x0:8, 0:1, 1:31, 0:1, 1:31, 16:8>>
    |> frame.decode(16_384)
    == Error(frame.Violation(frame.ProtocolError))
}

pub fn priority_frame_test() {
  assert <<5:size(24), 0x2:8, 0x0:8, 0:1, 1:31, 0:1, 2:31, 16:8>>
    |> frame.decode(16_384)
    == Ok(#(frame.Priority(1), <<>>))
}

pub fn rst_stream_with_stream_id_zero_is_protocol_error_test() {
  assert <<4:size(24), 0x3:8, 0x0:8, 0:1, 0:31, 0x1:32>>
    |> frame.decode(16_384)
    == Error(frame.Violation(frame.ProtocolError))
}

pub fn goaway_with_nonzero_stream_id_is_protocol_error_test() {
  assert <<8:size(24), 0x7:8, 0x0:8, 0:1, 1:31, 0:1, 3:31, 999:32>>
    |> frame.decode(16_384)
    == Error(frame.Violation(frame.ProtocolError))
}

pub fn headers_with_priority_self_dependency_is_protocol_error_test() {
  assert <<
      10:size(24), 0x1:8, 0x24:8, 0:1, 1:31, 0:1, 1:31, 16:8, "block":utf8,
    >>
    |> frame.decode(16_384)
    == Error(frame.Violation(frame.ProtocolError))
}

pub fn encode_data_roundtrip_test() {
  let frame = frame.Data(1, True, <<"hello":utf8>>, 5)
  assert frame.encode(frame) |> frame.decode(16_384) == Ok(#(frame, <<>>))
}

pub fn encode_headers_roundtrip_test() {
  let frame = frame.Headers(3, False, True, <<"block":utf8>>)
  assert frame.encode(frame) |> frame.decode(16_384) == Ok(#(frame, <<>>))
}

pub fn encode_settings_roundtrip_test() {
  let frame =
    frame.Settings(0, False, [
      frame.MaxConcurrentStreams(100),
      frame.EnablePush(False),
    ])
  assert frame.encode(frame) |> frame.decode(16_384) == Ok(#(frame, <<>>))
}

pub fn encode_rst_stream_roundtrip_test() {
  let frame = frame.RstStream(5, frame.Cancel)
  assert frame.encode(frame) |> frame.decode(16_384) == Ok(#(frame, <<>>))
}

pub fn encode_goaway_roundtrip_test() {
  let frame = frame.Goaway(0, 7, frame.EnhanceYourCalm, <<"bye":utf8>>)
  assert frame.encode(frame) |> frame.decode(16_384) == Ok(#(frame, <<>>))
}

pub fn encode_window_update_roundtrip_test() {
  let frame = frame.WindowUpdate(9, 65_535)
  assert frame.encode(frame) |> frame.decode(16_384) == Ok(#(frame, <<>>))
}

pub fn encode_ping_roundtrip_test() {
  let frame = frame.Ping(0, True, <<1, 2, 3, 4, 5, 6, 7, 8>>)
  assert frame.encode(frame) |> frame.decode(16_384) == Ok(#(frame, <<>>))
}

pub fn encode_data_header_declares_length_without_payload_test() {
  let header = frame.encode_data_header(1, True, 5)
  assert header
    |> bit_array.append(<<"hello":utf8>>)
    |> frame.decode(16_384)
    == Ok(#(frame.Data(1, True, <<"hello":utf8>>, 5), <<>>))
}
