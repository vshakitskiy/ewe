import ewe/internal/websocket
import websocks

fn close_code(error: websocks.ProcessError) -> websocks.CloseCode {
  let assert websocks.CloseReason(code, "") = websocket.close_reason(error)
  code
}

pub fn invalid_utf8_closes_with_invalid_payload_data_test() {
  assert close_code(websocks.ResolveFailed(websocks.NotUtf8))
    == websocks.InvalidPayloadData
}

pub fn failed_decompression_closes_with_invalid_payload_data_test() {
  assert close_code(websocks.ResolveFailed(websocks.DecompressionFailed))
    == websocks.InvalidPayloadData
}

pub fn oversized_message_closes_with_message_too_big_test() {
  assert close_code(websocks.ResolveFailed(websocks.MessageTooLarge(2, 1)))
    == websocks.MessageTooBig
}

pub fn oversized_frame_closes_with_message_too_big_test() {
  assert close_code(websocks.DecodeFailed(websocks.FrameTooLarge(2, 1)))
    == websocks.MessageTooBig
}

pub fn broken_fragmentation_closes_with_protocol_error_test() {
  assert close_code(websocks.ResolveFailed(websocks.OrphanedContinuation))
    == websocks.ProtocolError
  assert close_code(websocks.ResolveFailed(websocks.FragmentationInterrupted))
    == websocks.ProtocolError
  assert close_code(websocks.ResolveFailed(websocks.ConcurrentFragmentation))
    == websocks.ProtocolError
}

pub fn invalid_frame_closes_with_protocol_error_test() {
  assert close_code(websocks.DecodeFailed(websocks.InvalidFrame))
    == websocks.ProtocolError
}
