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

/// The context is built during the handshake where the negotiated extensions
/// are known and handed to whichever protocol goes on to run the socket.
pub type Websocket {
  WebsocketMetadata(
    context: websocks.Context,
    handler: fn(WebsocketConnection) -> Outcome,
  )
}

pub type Streaming {
  StreamingMetadata(handler: fn(ResponseWriter) -> Nil)
}

/// A raw descriptor belongs to the process that opened it, so whether the
/// handler can carry one depends on the protocol. An HTTP/1 handler runs in the
/// process that writes the socket, an HTTP/2 stream handler does not.
pub type File {
  /// Already open, and closed by whoever writes or drops the response.
  OpenFile(handle: FileDescriptor, offset: Int, length: Int)
  /// Sized but not yet open; the connection process opens it at send time.
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

/// HTTP/2 carries WebSockets over extended CONNECT (RFC 8441), which ewe does
/// not negotiate yet.
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
  /// A stream process that outstayed the grace it was given after a reset.
  Http2StreamClose(pid: process.Pid)
}

/// Concatenating onto an empty buffer would copy the incoming bytes for
/// nothing, which is the common case on a connection with no pipelining.
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
