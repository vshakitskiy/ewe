import ewe/internal/connection
import ewe/internal/http2/connection as http2
import ewe/internal/rescue
import ewe/internal/websocket
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/option
import gleam/result
import gleam/string
import logging
import websocks

const close_timeout_ms = 5000

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

  let compression = case
    request.get_header(request, "sec-websocket-extensions")
  {
    Ok(header) ->
      case websocks.has_deflate(header) {
        True -> option.Some(websocks.get_compression_extensions(header))
        False -> option.None
      }
    Error(Nil) -> option.None
  }

  Ok(Handshake(compression:))
}

pub fn run(
  conn: http2.WebsocketConnection(connection.Body),
  on_init: fn(connection.WebsocketConnection, process.Selector(user_message)) ->
    #(user_state, process.Selector(user_message)),
  step: fn(
    connection.WebsocketConnection,
    user_state,
    websocket.Message(user_message),
  ) -> connection.Step(user_state, user_message),
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
) -> connection.Outcome {
  let #(state, messages) =
    on_init(connection.Http2Websocket(conn), process.new_selector())

  read(conn)
  loop(conn, merge_stream_selector(conn, messages), state, step, on_close)
}

fn read(conn: http2.WebsocketConnection(connection.Body)) -> Nil {
  process.send(
    conn.writer.connection,
    http2.ReadBody(conn.writer.stream_id, conn.body),
  )
}

fn loop(
  conn: http2.WebsocketConnection(connection.Body),
  selector: process.Selector(Received(user_message)),
  state: user_state,
  step: fn(
    connection.WebsocketConnection,
    user_state,
    websocket.Message(user_message),
  ) -> connection.Step(user_state, user_message),
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
) -> connection.Outcome {
  case process.selector_receive_forever(selector) {
    Interrupted -> stopped(conn, state, on_close)
    Signal(http2.Draining) ->
      close(
        conn,
        websocks.CloseReason(websocks.GoingAway, "server shutting down"),
      )
      |> resolve(conn, state, on_close, _)
    Received(message) ->
      websocket.UserMessage(message)
      |> deliver(conn, selector, state, step, on_close, Await, _)
    Body(http2.DoneEvent(_trailers)) -> stopped(conn, state, on_close)
    Body(http2.ChunkEvent(data)) ->
      websocks.push_data(conn.context, data)
      |> with_context(conn, _)
      |> drain(selector, state, step, on_close, Await)
    Body(http2.LastChunkEvent(data, _trailers)) ->
      websocks.push_data(conn.context, data)
      |> with_context(conn, _)
      |> drain(selector, state, step, on_close, Halt)
  }
}

type Resume {
  Await
  Halt
}

fn drain(
  conn: http2.WebsocketConnection(connection.Body),
  selector: process.Selector(Received(user_message)),
  state: user_state,
  step: fn(
    connection.WebsocketConnection,
    user_state,
    websocket.Message(user_message),
  ) -> connection.Step(user_state, user_message),
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
  resume: Resume,
) -> connection.Outcome {
  case websocks.next_frame(conn.context) {
    Error(_violation) ->
      close(conn, websocks.CloseReason(websocks.ProtocolError, ""))
      |> resolve(conn, state, on_close, _)
    Ok(websocks.MoreData(context:)) -> {
      let conn = with_context(conn, context)

      case resume {
        Halt -> stopped(conn, state, on_close)
        Await -> {
          read(conn)
          loop(conn, selector, state, step, on_close)
        }
      }
    }
    Ok(websocks.Decoded(frame:, context:)) -> {
      let conn = with_context(conn, context)

      case frame {
        websocks.Control(websocks.Ping(payload)) -> {
          push(conn, websocks.encode_pong_frame(payload:, masking: option.None))
          drain(conn, selector, state, step, on_close, resume)
        }
        websocks.Control(websocks.Pong(_payload)) ->
          drain(conn, selector, state, step, on_close, resume)
        websocks.Control(websocks.Close(reason)) ->
          close(conn, reason) |> resolve(conn, state, on_close, _)
        websocks.Text(payload) ->
          websocket.TextFrame(unsafe_to_string(payload))
          |> deliver(conn, selector, state, step, on_close, resume, _)
        websocks.Binary(payload) ->
          websocket.BinaryFrame(payload)
          |> deliver(conn, selector, state, step, on_close, resume, _)
        websocks.Continuation(_payload) ->
          drain(conn, selector, state, step, on_close, resume)
      }
    }
  }
}

fn deliver(
  conn: http2.WebsocketConnection(connection.Body),
  selector: process.Selector(Received(user_message)),
  state: user_state,
  step: fn(
    connection.WebsocketConnection,
    user_state,
    websocket.Message(user_message),
  ) -> connection.Step(user_state, user_message),
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
  resume: Resume,
  message: websocket.Message(user_message),
) -> connection.Outcome {
  let handle = connection.Http2Websocket(conn)

  case rescue.handler(fn() { step(handle, state, message) }) {
    Error(details) -> crashed(conn, state, on_close, details)
    Ok(connection.Halt(outcome)) -> ended(conn, state, on_close, outcome)
    Ok(connection.Proceed(user_state: state, messages:)) -> {
      let selector = case messages {
        option.Some(messages) -> merge_stream_selector(conn, messages)
        option.None -> selector
      }

      drain(conn, selector, state, step, on_close, resume)
    }
  }
}

fn ended(
  conn: http2.WebsocketConnection(connection.Body),
  state: user_state,
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
  outcome: connection.Outcome,
) -> connection.Outcome {
  let handle = connection.Http2Websocket(conn)
  rescue.logged("websocket close handler", fn() { on_close(handle, state) })

  websocks.close_context(conn.context)
  outcome
}

fn stopped(
  conn: http2.WebsocketConnection(connection.Body),
  state: user_state,
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
) -> connection.Outcome {
  ended(conn, state, on_close, connection.Stopped)
}

fn crashed(
  conn: http2.WebsocketConnection(connection.Body),
  state: user_state,
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
  details: String,
) -> connection.Outcome {
  logging.log(
    logging.Error,
    "Caught a crash in the websocket handler: " <> details,
  )

  ended(
    conn,
    state,
    on_close,
    connection.StoppedAbnormal("the handler crashed"),
  )
}

fn resolve(
  conn: http2.WebsocketConnection(connection.Body),
  state: user_state,
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
  sent: Result(Nil, http2.Interrupted),
) -> connection.Outcome {
  case sent {
    Ok(Nil) -> stopped(conn, state, on_close)
    Error(interrupted) ->
      ended(
        conn,
        state,
        on_close,
        connection.StoppedAbnormal(string.inspect(interrupted)),
      )
  }
}

pub fn send_text(
  conn: http2.WebsocketConnection(connection.Body),
  text: String,
) -> Nil {
  websocks.encode_text_frame(
    payload: bit_array_from_string(text),
    context: conn.context,
    masking: option.None,
  )
  |> push(conn, _)
}

pub fn send_binary(
  conn: http2.WebsocketConnection(connection.Body),
  data: BitArray,
) -> Nil {
  websocks.encode_binary_frame(
    payload: data,
    context: conn.context,
    masking: option.None,
  )
  |> push(conn, _)
}

pub fn send_close(
  conn: http2.WebsocketConnection(connection.Body),
  reason: websocks.CloseReason,
) -> Nil {
  websocks.encode_close_frame(reason:, masking: option.None)
  |> push(conn, _)
}

fn push(
  conn: http2.WebsocketConnection(connection.Body),
  frame: BitArray,
) -> Nil {
  process.send(
    conn.writer.connection,
    http2.PushData(conn.writer.stream_id, http2.Chunk(frame, option.None)),
  )
}

fn close(
  conn: http2.WebsocketConnection(connection.Body),
  reason: websocks.CloseReason,
) -> Result(Nil, http2.Interrupted) {
  let frame = websocks.encode_close_frame(reason:, masking: option.None)

  process.send(
    conn.writer.connection,
    http2.PushData(
      conn.writer.stream_id,
      http2.Finish(frame, option.Some(conn.writer.ack)),
    ),
  )

  http2.receive_reply_within(conn.writer.ack_ref, close_timeout_ms)
  |> result.replace(Nil)
}

fn with_context(
  conn: http2.WebsocketConnection(connection.Body),
  context: websocks.Context,
) -> http2.WebsocketConnection(connection.Body) {
  http2.WebsocketConnection(..conn, context:)
}

type Received(user_message) {
  Received(user_message)
  Body(http2.BodyEvent)
  Signal(http2.StreamSignal)
  Interrupted
}

fn merge_stream_selector(
  conn: http2.WebsocketConnection(connection.Body),
  messages: process.Selector(user_message),
) -> process.Selector(Received(user_message)) {
  process.map_selector(messages, Received)
  |> process.select_map(conn.body, Body)
  |> process.select_map(conn.signals, Signal)
  |> process.select_trapped_exits(fn(_exit) { Interrupted })
}

@external(erlang, "ewe_ffi", "identity")
fn unsafe_to_string(payload: BitArray) -> String

@external(erlang, "ewe_ffi", "identity")
fn bit_array_from_string(text: String) -> BitArray
