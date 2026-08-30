import ewe/glisten/socket
import ewe/glisten/transport
import ewe/internal/connection
import ewe/internal/http1/connection as http1
import ewe/internal/http1/stream
import ewe/internal/rescue
import ewe/internal/websocket
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/option
import gleam/result
import logging
import websocks

pub type HandshakeError {
  MethodNotGet
  NotAnUpgrade
  NotWebsocket
  UnsupportedVersion
  MissingKey
}

pub fn handshake_error_to_string(error: HandshakeError) -> String {
  case error {
    MethodNotGet -> "the handshake must be a GET"
    NotAnUpgrade -> "the connection header does not request an upgrade"
    NotWebsocket -> "the upgrade header does not name websocket"
    UnsupportedVersion -> "only sec-websocket-version 13 is supported"
    MissingKey -> "missing sec-websocket-key header"
  }
}

pub type Handshake {
  Handshake(
    accept: String,
    compression: option.Option(websocks.CompressionExtensions),
  )
}

pub fn handshake(
  method: http.Method,
  conn: http1.Connection,
) -> Result(Handshake, HandshakeError) {
  use Nil <- result.try(case method {
    http.Get -> Ok(Nil)
    _method -> Error(MethodNotGet)
  })

  case conn.upgrade {
    option.None -> Error(NotAnUpgrade)
    option.Some(http1.OtherUpgrade(..)) -> Error(NotWebsocket)
    option.Some(http1.WebsocketUpgrade(key:, version:, extensions:)) -> {
      use Nil <- result.try(case version {
        option.Some("13") -> Ok(Nil)
        option.Some(_other) | option.None -> Error(UnsupportedVersion)
      })

      use key <- result.map(option.to_result(key, MissingKey))

      let compression = case extensions {
        option.Some(header) ->
          case websocks.has_deflate(header) {
            True -> option.Some(websocks.get_compression_extensions(header))
            False -> option.None
          }
        option.None -> option.None
      }

      Handshake(accept: websocks.compute_accept(key), compression:)
    }
  }
}

type Handlers(user_state, user_message) {
  Handlers(
    step: fn(
      connection.WebsocketConnection,
      user_state,
      websocket.Message(user_message),
    ) -> connection.Step(user_state, user_message),
    on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
  )
}

pub fn run(
  conn: http1.WebsocketConnection,
  on_init: fn(connection.WebsocketConnection, process.Selector(user_message)) ->
    #(user_state, process.Selector(user_message)),
  step: fn(
    connection.WebsocketConnection,
    user_state,
    websocket.Message(user_message),
  ) -> connection.Step(user_state, user_message),
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
) -> connection.Outcome {
  let handlers = Handlers(step:, on_close:)
  let #(state, messages) =
    on_init(connection.Http1Websocket(conn), process.new_selector())

  case activate(conn) {
    Ok(Nil) -> loop(conn, handlers, stream.selector(messages), state)
    Error(reason) -> socket_failed(conn, handlers, state, reason)
  }
}

fn ended(
  conn: http1.WebsocketConnection,
  handlers: Handlers(user_state, user_message),
  state: user_state,
  outcome: connection.Outcome,
) -> connection.Outcome {
  let handle = connection.Http1Websocket(conn)
  rescue.logged("websocket close handler", fn() {
    handlers.on_close(handle, state)
  })

  websocks.close_context(conn.context)
  outcome
}

fn stopped(
  conn: http1.WebsocketConnection,
  handlers: Handlers(user_state, user_message),
  state: user_state,
) -> connection.Outcome {
  ended(conn, handlers, state, connection.Stopped)
}

fn crashed(
  conn: http1.WebsocketConnection,
  handlers: Handlers(user_state, user_message),
  state: user_state,
  details: String,
) -> connection.Outcome {
  logging.log(
    logging.Error,
    "Caught a crash in the websocket handler: " <> details,
  )

  ended(
    conn,
    handlers,
    state,
    connection.StoppedAbnormal("the handler crashed"),
  )
}

fn socket_failed(
  conn: http1.WebsocketConnection,
  handlers: Handlers(user_state, user_message),
  state: user_state,
  reason: socket.SocketReason,
) -> connection.Outcome {
  socket.reason_to_string(reason)
  |> connection.StoppedAbnormal
  |> ended(conn, handlers, state, _)
}

type Resume {
  DrainBuffer
  AwaitSocket
}

fn loop(
  conn: http1.WebsocketConnection,
  handlers: Handlers(user_state, user_message),
  selector: process.Selector(stream.Event(user_message)),
  state: user_state,
) -> connection.Outcome {
  case process.selector_receive_forever(selector) {
    stream.Closed -> stopped(conn, handlers, state)
    stream.Failed(reason) ->
      ended(conn, handlers, state, connection.StoppedAbnormal(reason))
    stream.Exhausted ->
      case activate(conn) {
        Ok(Nil) -> loop(conn, handlers, selector, state)
        Error(reason) -> socket_failed(conn, handlers, state, reason)
      }
    stream.Packet(data) ->
      websocks.push_data(conn.context, data)
      |> with_context(conn, _)
      |> drain(handlers, selector, state)
    stream.UserMessage(message) ->
      websocket.UserMessage(message)
      |> deliver(conn, handlers, selector, state, AwaitSocket, _)
  }
}

fn drain(
  conn: http1.WebsocketConnection,
  handlers: Handlers(user_state, user_message),
  selector: process.Selector(stream.Event(user_message)),
  state: user_state,
) -> connection.Outcome {
  case websocks.next_frame(conn.context) {
    Error(violation) ->
      close(conn, websocket.close_reason(violation))
      |> resolve(conn, handlers, state, _)
    Ok(websocks.MoreData(context:)) ->
      with_context(conn, context)
      |> loop(handlers, selector, state)
    Ok(websocks.Decoded(frame:, context:)) -> {
      let conn = with_context(conn, context)

      case frame {
        websocks.Control(websocks.Ping(payload)) ->
          case
            write(
              conn,
              websocks.encode_pong_frame(payload:, masking: option.None),
            )
          {
            Ok(Nil) -> drain(conn, handlers, selector, state)
            Error(reason) -> socket_failed(conn, handlers, state, reason)
          }
        websocks.Control(websocks.Pong(_payload))
        | websocks.Continuation(_payload) ->
          drain(conn, handlers, selector, state)
        websocks.Control(websocks.Close(reason)) ->
          close(conn, reason) |> resolve(conn, handlers, state, _)
        websocks.Text(payload) ->
          websocket.TextFrame(unsafe_to_string(payload))
          |> deliver(conn, handlers, selector, state, DrainBuffer, _)
        websocks.Binary(payload) ->
          websocket.BinaryFrame(payload)
          |> deliver(conn, handlers, selector, state, DrainBuffer, _)
      }
    }
  }
}

fn deliver(
  conn: http1.WebsocketConnection,
  handlers: Handlers(user_state, user_message),
  selector: process.Selector(stream.Event(user_message)),
  state: user_state,
  resume: Resume,
  message: websocket.Message(user_message),
) -> connection.Outcome {
  let handle = connection.Http1Websocket(conn)

  case rescue.handler(fn() { handlers.step(handle, state, message) }) {
    Error(details) -> crashed(conn, handlers, state, details)
    Ok(connection.Halt(outcome)) -> ended(conn, handlers, state, outcome)
    Ok(connection.Proceed(user_state: state, messages:)) -> {
      let selector = case messages {
        option.Some(messages) -> stream.selector(messages)
        option.None -> selector
      }

      case resume {
        DrainBuffer -> drain(conn, handlers, selector, state)
        AwaitSocket -> loop(conn, handlers, selector, state)
      }
    }
  }
}

fn resolve(
  conn: http1.WebsocketConnection,
  handlers: Handlers(user_state, user_message),
  state: user_state,
  sent: Result(Nil, socket.SocketReason),
) -> connection.Outcome {
  case sent {
    Ok(Nil) -> stopped(conn, handlers, state)
    Error(reason) -> socket_failed(conn, handlers, state, reason)
  }
}

pub fn send_text(
  conn: http1.WebsocketConnection,
  text: String,
) -> Result(Nil, socket.SocketReason) {
  websocks.encode_text_frame(
    payload: bit_array_from_string(text),
    context: conn.context,
    masking: option.None,
  )
  |> write(conn, _)
}

pub fn send_binary(
  conn: http1.WebsocketConnection,
  data: BitArray,
) -> Result(Nil, socket.SocketReason) {
  websocks.encode_binary_frame(
    payload: data,
    context: conn.context,
    masking: option.None,
  )
  |> write(conn, _)
}

pub fn send_close(
  conn: http1.WebsocketConnection,
  reason: websocks.CloseReason,
) -> Result(Nil, socket.SocketReason) {
  close(conn, reason)
}

fn with_context(
  conn: http1.WebsocketConnection,
  context: websocks.Context,
) -> http1.WebsocketConnection {
  http1.WebsocketConnection(..conn, context:)
}

fn close(
  conn: http1.WebsocketConnection,
  reason: websocks.CloseReason,
) -> Result(Nil, socket.SocketReason) {
  write(conn, websocks.encode_close_frame(reason:, masking: option.None))
}

fn write(
  conn: http1.WebsocketConnection,
  frame: BitArray,
) -> Result(Nil, socket.SocketReason) {
  bytes_tree.from_bit_array(frame)
  |> transport.send(conn.transport, conn.socket, _)
}

fn activate(
  conn: http1.WebsocketConnection,
) -> Result(Nil, socket.SocketReason) {
  stream.activate(conn.transport, conn.socket)
}

@external(erlang, "ewe_ffi", "identity")
fn unsafe_to_string(payload: BitArray) -> String

@external(erlang, "ewe_ffi", "identity")
fn bit_array_from_string(text: String) -> BitArray
