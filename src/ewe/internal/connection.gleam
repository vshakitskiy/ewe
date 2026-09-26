import ewe/internal/http1/connection as http1
import ewe/internal/http2/connection as http2
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/option
import gleam/string
import websocks

pub type Connection {
  Http1(http1.Connection)
  Http2(http2.Connection)
}

pub type Handler {
  Handler(
    respond: fn(request.Request(Connection)) -> response.Response(Body),
    on_crash: response.Response(Body),
  )
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
  Http2Writer(http2.ResponseWriter)
}

pub type SseConnection {
  Http1Sse(http1.SseConnection)
  Http2Sse(http2.SseConnection)
}

pub type WebsocketConnection {
  Http1Websocket(http1.WebsocketConnection)
  Http2Websocket(http2.WebsocketConnection)
}

pub type Outcome {
  Stopped
  StoppedAbnormal(reason: String)
}

pub type Next(user_state, user_message) {
  Continue(
    user_state: user_state,
    selector: option.Option(process.Selector(user_message)),
  )
  Stop
  StopAbnormal(reason: String)
}

pub type Message {
  IdleTimeout
  Http2HandshakeTimeout
  Http2IdleTimeout
  Http2Command(http2.Command)
  Http2Respond(stream_id: Int, response: response.Response(Body))
  Http2Exit(process.ExitMessage)
  Http2DrainTimeout
  Http2Resume
  Http2KillWorker(pid: process.Pid)
}

pub type Exit {
  ParentExited
  LinkExitedNormally
  LinkFailed(reason: String)
}

pub fn select_exits(
  selector: process.Selector(a),
  map: fn(Exit) -> a,
) -> process.Selector(a) {
  let parent = parent_pid()

  process.select_trapped_exits(selector, fn(exit) {
    map(classify_exit(exit, parent))
  })
}

fn classify_exit(
  exit: process.ExitMessage,
  parent: Result(process.Pid, Nil),
) -> Exit {
  case parent == Ok(exit.pid), exit.reason {
    True, _reason -> ParentExited
    False, process.Normal -> LinkExitedNormally
    False, process.Killed -> LinkFailed("a linked process was killed")
    False, process.Abnormal(reason) ->
      LinkFailed("a linked process exited: " <> string.inspect(reason))
  }
}

@external(erlang, "ewe_ffi", "parent_pid")
pub fn parent_pid() -> Result(process.Pid, Nil)

pub fn append_buffer(buffer: BitArray, data: BitArray) -> BitArray {
  case buffer {
    <<>> -> data
    _buffer -> <<buffer:bits, data:bits>>
  }
}

pub fn start_idle_timer(
  self: process.Subject(Message),
  timeout: Int,
) -> option.Option(process.Timer) {
  process.send_after(self, timeout, IdleTimeout)
  |> option.Some
}

pub fn cancel_timer(timer: option.Option(process.Timer)) -> Nil {
  case timer {
    option.Some(timer) -> {
      let _cancelled = process.cancel_timer(timer)
      Nil
    }
    option.None -> Nil
  }
}
