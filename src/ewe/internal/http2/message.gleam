import ewe/internal/http2/frame
import gleam/http/response

pub type StreamMessage {
  Data(data: BitArray, end_stream: Bool)
  Reset(code: frame.ErrorCode)
  // TODO: trailers
}

pub type ConnectionMessage {
  WindowUpdate(stream_id: Int, increment: Int)
  SendResponse(stream_id: Int, response: response.Response(BitArray))
  StreamDone(stream_id: Int)
}
