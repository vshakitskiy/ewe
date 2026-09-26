import ewe/internal/http2/frame.{ConnectionError, Decoded, NeedMoreData}
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}

fn raw(
  frame_type: Int,
  flags: Int,
  stream_id: Int,
  payload: BitArray,
) -> BitArray {
  <<
    { bit_array.byte_size(payload) }:24,
    frame_type:8,
    flags:8,
    0:1,
    stream_id:31,
    payload:bits,
  >>
}

fn decode(bits: BitArray) -> frame.Decoded {
  frame.decode(bits, 16_384)
}

pub fn partial_header_is_incomplete_test() {
  assert decode(<<0:24, 0x0:8>>) == NeedMoreData
}

pub fn partial_payload_is_incomplete_test() {
  assert decode(<<5:24, 0x0:8, 0:8, 0:1, 1:31, "hi":utf8>>) == NeedMoreData
}

pub fn bytes_after_a_frame_are_left_test() {
  assert decode(<<raw(0x0, 0x0, 3, <<"hello":utf8>>):bits, "extra":utf8>>)
    == Decoded(frame.Data(3, False, <<"hello":utf8>>, 5), <<"extra":utf8>>)
}

pub fn reserved_bit_is_ignored_test() {
  assert decode(<<0:24, 0x0:8, 0x1:8, 1:1, 1:31>>)
    == Decoded(frame.Data(1, True, <<>>, 0), <<>>)
}

pub fn unused_flags_are_ignored_test() {
  assert decode(raw(0x6, 0xfe, 0, <<0:64>>))
    == Decoded(frame.Ping(ack: False, data: <<0:64>>), <<>>)
}

pub fn frame_over_max_frame_size_is_frame_size_error_test() {
  assert decode(<<16_385:24, 0x0:8, 0:8, 0:1, 1:31>>)
    == ConnectionError(frame.FrameSizeError)
}

pub fn padded_data_counts_padding_in_size_test() {
  assert decode(raw(0x0, 0x8, 1, <<2, "hi":utf8, 0, 0>>))
    == Decoded(frame.Data(1, False, <<"hi":utf8>>, 5), <<>>)
}

pub fn padding_as_long_as_the_payload_is_protocol_error_test() {
  assert decode(raw(0x0, 0x8, 1, <<5, "hi":utf8, 0, 0>>))
    == ConnectionError(frame.ProtocolError)
}

pub fn padded_frame_without_pad_length_is_frame_size_error_test() {
  assert decode(raw(0x0, 0x8, 1, <<>>)) == ConnectionError(frame.FrameSizeError)
}

pub fn headers_priority_fields_are_stripped_test() {
  assert decode(raw(0x1, 0x24, 3, <<1:1, 1:31, 16:8, 0x82>>))
    == Decoded(frame.Headers(3, False, True, Some(1), <<0x82>>), <<>>)
}

pub fn headers_too_short_for_priority_is_frame_size_error_test() {
  assert decode(raw(0x1, 0x24, 3, <<0, 0>>))
    == ConnectionError(frame.FrameSizeError)
}

pub fn priority_of_wrong_length_is_a_stream_error_test() {
  assert decode(<<raw(0x2, 0x0, 3, <<0:32>>):bits, "rest":utf8>>)
    == frame.StreamError(3, frame.FrameSizeError, <<"rest":utf8>>)
}

pub fn settings_ack_with_payload_is_frame_size_error_test() {
  assert decode(raw(0x4, 0x1, 0, <<0x1:16, 4096:32>>))
    == ConnectionError(frame.FrameSizeError)
}

pub fn settings_not_a_multiple_of_six_is_frame_size_error_test() {
  assert decode(raw(0x4, 0x0, 0, <<0x1:16, 4096:24>>))
    == ConnectionError(frame.FrameSizeError)
}

pub fn unknown_setting_is_dropped_test() {
  assert decode(raw(0x4, 0x0, 0, <<0xff:16, 1:32, 0x5:16, 20_000:32>>))
    == Decoded(
      frame.Settings(ack: False, settings: [frame.MaxFrameSize(20_000)]),
      <<>>,
    )
}

fn round_trip(sent: frame.Frame) -> Nil {
  assert decode(frame.encode(sent)) == Decoded(sent, <<>>)
}

pub fn encoded_frames_decode_to_themselves_test() {
  round_trip(frame.Data(1, True, <<"hi":utf8>>, 2))
  round_trip(frame.Headers(1, False, True, None, <<0x82>>))
  round_trip(frame.Headers(3, True, False, Some(1), <<0x82>>))
  round_trip(frame.Priority(3, 1))
  round_trip(frame.RstStream(1, frame.RefusedStream))
  round_trip(
    frame.Settings(ack: False, settings: [
      frame.HeaderTableSize(0),
      frame.EnablePush(False),
      frame.MaxConcurrentStreams(100),
      frame.InitialWindowSize(1),
      frame.MaxFrameSize(16_384),
      frame.MaxHeaderListSize(8192),
      frame.EnableConnectProtocol(True),
    ]),
  )
  round_trip(frame.Settings(ack: True, settings: []))
  round_trip(frame.PushPromise(1, 2, <<0x82>>))
  round_trip(frame.Ping(ack: False, data: <<"12345678":utf8>>))
  round_trip(frame.Goaway(5, frame.EnhanceYourCalm, <<"calm":utf8>>))
  round_trip(frame.WindowUpdate(0, 1))
  round_trip(frame.Continuation(1, True, <<0x82>>))
}

pub fn data_header_declares_a_payload_sent_separately_test() {
  assert <<frame.data_header(1, True, 2):bits, "hi":utf8>>
    == frame.encode(frame.Data(1, True, <<"hi":utf8>>, 2))
}

pub fn stream_frames_on_stream_zero_are_protocol_errors_test() {
  use #(frame_type, payload) <- list.each([
    #(0x0, <<>>),
    #(0x1, <<0x82>>),
    #(0x2, <<0:1, 1:31, 16:8>>),
    #(0x3, <<0:32>>),
    #(0x9, <<0x82>>),
  ])
  assert decode(raw(frame_type, 0x4, 0, payload))
    == ConnectionError(frame.ProtocolError)
}

pub fn connection_frames_on_a_stream_are_protocol_errors_test() {
  use #(frame_type, payload) <- list.each([
    #(0x4, <<>>),
    #(0x6, <<0:64>>),
    #(0x7, <<0:64>>),
  ])
  assert decode(raw(frame_type, 0x0, 1, payload))
    == ConnectionError(frame.ProtocolError)
}

pub fn fixed_size_frames_of_wrong_length_are_frame_size_errors_test() {
  use #(frame_type, stream_id, payload) <- list.each([
    #(0x3, 1, <<0:24>>),
    #(0x6, 0, <<0:32>>),
    #(0x8, 1, <<100:40>>),
  ])
  assert decode(raw(frame_type, 0x0, stream_id, payload))
    == ConnectionError(frame.FrameSizeError)
}

pub fn invalid_setting_values_are_rejected_test() {
  use #(identifier, value, error) <- list.each([
    #(0x2, 2, frame.ProtocolError),
    #(0x4, 2_147_483_648, frame.FlowControlError),
    #(0x5, 16_383, frame.ProtocolError),
    #(0x5, 16_777_216, frame.ProtocolError),
    #(0x8, 2, frame.ProtocolError),
  ])
  assert decode(raw(0x4, 0x0, 0, <<identifier:16, value:32>>))
    == ConnectionError(error)
}
