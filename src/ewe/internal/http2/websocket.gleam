import ewe/internal/connection
import ewe/internal/http2/connection as http2
import ewe/internal/http2/worker
import ewe/internal/websocket
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/option
import gleam/result
import websocks

const close_timeout_ms: Int = 5000

pub type HandshakeError {
  MethodNotConnect
  NotWebsocket
  UnsupportedVersion
}

pub fn handshake_error_to_string(error: HandshakeError) -> String {
  case error {
    MethodNotConnect -> "the handshake must be an extended CONNECT"
    NotWebsocket -> "the :protocol pseudo-header does not name websocket"
    UnsupportedVersion -> "only sec-websocket-version 13 is supported"
  }
}

pub type Handshake {
  Handshake(compression: option.Option(websocks.CompressionExtensions))
}

pub fn handshake(
  request: request.Request(connection.Connection),
  protocol: option.Option(String),
) -> Result(Handshake, HandshakeError) {
  use Nil <- result.try(case request.method {
    http.Connect -> Ok(Nil)
    _method -> Error(MethodNotConnect)
  })

  use Nil <- result.try(case protocol {
    option.Some("websocket") -> Ok(Nil)
    option.Some(_other) | option.None -> Error(NotWebsocket)
  })

  use Nil <- result.try(
    case request.get_header(request, "sec-websocket-version") {
      Ok("13") -> Ok(Nil)
      Ok(_other) | Error(Nil) -> Error(UnsupportedVersion)
    },
  )

  request.get_header(request, "sec-websocket-extensions")
  |> option.from_result
  |> websocket.compression
  |> Handshake
  |> Ok
}

pub fn run(
  conn: http2.WebsocketConnection,
  on_init: fn(connection.WebsocketConnection, process.Selector(user_message)) ->
    #(user_state, process.Selector(user_message)),
  handler: fn(
    connection.WebsocketConnection,
    user_state,
    websocket.Message(user_message),
  ) -> connection.Next(user_state, user_message),
  on_close: fn(user_state) -> Nil,
) -> connection.Outcome {
  read(conn)
  websocket.run(transport(conn), conn.context, on_init, handler, on_close)
}

fn transport(
  conn: http2.WebsocketConnection,
) -> websocket.Transport(Event(user_message), user_message) {
  websocket.Transport(
    handle: fn(context) {
      connection.Http2Websocket(http2.WebsocketConnection(..conn, context:))
    },
    selector: fn(messages) { selector(conn, messages) },
    receive: fn(selector) { receive(conn, selector) },
    send: fn(frame) {
      write(conn, frame) |> result.map_error(http2.interrupted_to_string)
    },
    close: fn(frame) {
      worker.write_within(conn.writer, frame, True, close_timeout_ms)
      |> result.map_error(http2.interrupted_to_string)
    },
  )
}

type Event(user_message) {
  UserMessage(user_message)
  Body(http2.BodyEvent)
  Signal(http2.StreamSignal)
  Exited(connection.Exit)
}

fn selector(
  conn: http2.WebsocketConnection,
  messages: process.Selector(user_message),
) -> process.Selector(Event(user_message)) {
  process.map_selector(messages, UserMessage)
  |> process.select_map(conn.body, Body)
  |> process.select_map(conn.signals, Signal)
  |> connection.select_exits(Exited)
}

fn receive(
  conn: http2.WebsocketConnection,
  selector: process.Selector(Event(user_message)),
) -> websocket.Event(user_message) {
  case process.selector_receive_forever(selector) {
    Body(http2.ChunkEvent(data)) -> {
      read(conn)
      websocket.Data(data, last: False)
    }
    Body(http2.LastChunkEvent(data, _trailers)) ->
      websocket.Data(data, last: True)
    Body(http2.DoneEvent(_trailers)) -> websocket.Data(<<>>, last: True)
    UserMessage(message) -> websocket.User(message)
    Signal(http2.Draining) -> websocket.Shutdown
    Exited(connection.LinkExitedNormally) -> receive(conn, selector)
    Exited(connection.ParentExited) -> websocket.Gone
    Exited(connection.LinkFailed(reason)) -> websocket.Failed(reason)
  }
}

fn read(conn: http2.WebsocketConnection) -> Nil {
  process.send(
    conn.writer.commands,
    http2.ReadBody(conn.writer.stream_id, conn.body),
  )
}

pub fn send_text(
  conn: http2.WebsocketConnection,
  text: String,
) -> Result(Nil, http2.Interrupted) {
  write(conn, websocket.text_frame(conn.context, text))
}

pub fn send_binary(
  conn: http2.WebsocketConnection,
  data: BitArray,
) -> Result(Nil, http2.Interrupted) {
  write(conn, websocket.binary_frame(conn.context, data))
}

pub fn send_close(
  conn: http2.WebsocketConnection,
  reason: websocks.CloseReason,
) -> Result(Nil, http2.Interrupted) {
  write(conn, websocket.close_frame(reason))
}

fn write(
  conn: http2.WebsocketConnection,
  frame: BitArray,
) -> Result(Nil, http2.Interrupted) {
  worker.write(conn.writer, frame, False)
}
