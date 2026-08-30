import websocks

pub type Message(user_message) {
  TextFrame(text: String)
  BinaryFrame(data: BitArray)
  UserMessage(message: user_message)
}

pub fn close_reason(error: websocks.ProcessError) -> websocks.CloseReason {
  let code = case error {
    websocks.ResolveFailed(websocks.NotUtf8)
    | websocks.ResolveFailed(websocks.DecompressionFailed) ->
      websocks.InvalidPayloadData

    websocks.ResolveFailed(websocks.MessageTooLarge(..))
    | websocks.DecodeFailed(websocks.FrameTooLarge(..)) ->
      websocks.MessageTooBig

    websocks.ResolveFailed(websocks.OrphanedContinuation)
    | websocks.ResolveFailed(websocks.FragmentationInterrupted)
    | websocks.ResolveFailed(websocks.ConcurrentFragmentation)
    | websocks.DecodeFailed(websocks.InvalidFrame)
    | websocks.DecodeFailed(websocks.NotEnoughData(_data)) ->
      websocks.ProtocolError
  }

  websocks.CloseReason(code, "")
}
