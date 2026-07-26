import ewe/internal/http1/connection as http1
import gleam/bytes_tree
import gleam/erlang/process
import gleam/option
import glisten
import glisten/internal/handler

pub type Connection {
  Http1(http1.Connection)
  Http2
}

pub type Body {
  Bytes(bytes_tree.BytesTree)
  Text(String)
  Empty
  File(File)
  Streaming(Streaming)
  Sse(Sse)
}

pub type Sse {
  SseMetadata(handler: fn(SseConnection) -> Outcome)
}

pub type Streaming {
  StreamingMetadata(handler: fn(ResponseWriter) -> Nil)
}

pub type File {
  FileMetadata(path: String, offset: Int, length: Int)
}

pub type ResponseWriter {
  Http1Writer(http1.ResponseWriter)
  Http2Writer
}

pub type SseConnection {
  Http1Sse(http1.SseConnection)
  Http2Sse
}

pub type Outcome {
  Stopped
  StoppedAbnormal(reason: String)
}

pub type Message {
  Timeout
}

/// Concatenating onto an empty buffer would copy the incoming bytes for
/// nothing, which is the common case on a connection with no pipelining.
pub fn append_buffer(buffer: BitArray, data: BitArray) -> BitArray {
  case buffer {
    <<>> -> data
    _buffer -> <<buffer:bits, data:bits>>
  }
}

pub const idle_timeout = 10_000

pub fn start_idle_timer(
  connection: glisten.Connection(Message),
) -> option.Option(process.Timer) {
  process.send_after(connection.subject, idle_timeout, handler.User(Timeout))
  |> option.Some
}

pub fn cancel_idle_timer(timer: option.Option(process.Timer)) -> Nil {
  case timer {
    option.Some(timer) -> {
      let _cancelled = process.cancel_timer(timer)
      Nil
    }
    option.None -> Nil
  }
}
