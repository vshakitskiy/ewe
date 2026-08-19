import ewe/internal/http1/connection as http1
import ewe/internal/http2/connection as http2
import gleam/bytes_tree
import gleam/erlang/process
import gleam/option
import glisten
import glisten/internal/handler
import websocks

pub type Connection {
  Http1(http1.Connection)
  Http2(http2.Connection(Body))
}

pub type Body {
  Bytes(bytes_tree.BytesTree)
  Text(String)
  Empty
  File(File)
  Streaming(Streaming)
  Sse(Sse)
  Websocket(Websocket)
}

pub type Sse {
  SseMetadata(handler: fn(SseConnection) -> Outcome)
}

pub type Websocket {
  WebsocketMetadata(
    context: websocks.Context,
    handler: fn(WebsocketConnection) -> Outcome,
  )
}

pub type Streaming {
  StreamingMetadata(handler: fn(ResponseWriter) -> Nil)
}

pub type File {
  OpenFile(handle: FileDescriptor, offset: Int, length: Int)
  PendingFile(path: String, offset: Int, length: Int)
}

pub type FileDescriptor

pub type ResponseWriter {
  Http1Writer(http1.ResponseWriter)
  Http2Writer(http2.ResponseWriter(Body))
}

pub type SseConnection {
  Http1Sse(http1.SseConnection)
  Http2Sse(http2.SseConnection(Body))
}

pub type WebsocketConnection {
  Http1Websocket(http1.WebsocketConnection)
}

pub type Outcome {
  Stopped
  StoppedAbnormal(reason: String)
}

pub type Message {
  Timeout
  Http2Handshake
  Http2Stream(http2.Reply(Body))
  Http2Exit(process.ExitMessage)
  Http2Drain
  Http2StreamClose(pid: process.Pid)
}

pub fn append_buffer(buffer: BitArray, data: BitArray) -> BitArray {
  case buffer {
    <<>> -> data
    _buffer -> <<buffer:bits, data:bits>>
  }
}

pub fn start_idle_timer(
  connection: glisten.Connection(Message),
  timeout: Int,
) -> option.Option(process.Timer) {
  process.send_after(connection.subject, timeout, handler.User(Timeout))
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
