import ewe/glisten/socket
import ewe/glisten/socket/options
import ewe/glisten/transport
import ewe/internal/connection
import ewe/internal/http1/connection as http1
import ewe/internal/rescue
import ewe/internal/websocket
import gleam/bytes_tree
import gleam/dynamic
import gleam/erlang/atom
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

pub fn run(
  conn: http1.WebsocketConnection,
  on_init: fn(connection.WebsocketConnection, process.Selector(user_message)) ->
    #(user_state, process.Selector(user_message)),
  step: fn(
    connection.WebsocketConnection,
    user_state,
    websocket.Message(user_message),
  ) -> websocket.Step(user_state, user_message),
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
) -> connection.Outcome {
  let #(state, messages) =
    on_init(connection.Http1Websocket(conn), process.new_selector())

  case activate(conn) {
    Ok(Nil) ->
      loop(conn, merge_socket_selector(messages), state, step, on_close)
    Error(reason) -> socket_failed(conn, state, on_close, reason)
  }
}

fn ended(
  conn: http1.WebsocketConnection,
  state: user_state,
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
  outcome: connection.Outcome,
) -> connection.Outcome {
  let handle = connection.Http1Websocket(conn)
  rescue.logged("websocket close handler", fn() { on_close(handle, state) })

  websocks.close_context(conn.context)
  outcome
}

fn stopped(
  conn: http1.WebsocketConnection,
  state: user_state,
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
) -> connection.Outcome {
  ended(conn, state, on_close, connection.Stopped)
}

fn crashed(
  conn: http1.WebsocketConnection,
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

fn socket_failed(
  conn: http1.WebsocketConnection,
  state: user_state,
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
  reason: socket.SocketReason,
) -> connection.Outcome {
  socket.reason_to_string(reason)
  |> connection.StoppedAbnormal
  |> ended(conn, state, on_close, _)
}

type Resume {
  DrainBuffer
  AwaitSocket
}

fn loop(
  conn: http1.WebsocketConnection,
  selector: process.Selector(Received(user_message)),
  state: user_state,
  step: fn(
    connection.WebsocketConnection,
    user_state,
    websocket.Message(user_message),
  ) -> websocket.Step(user_state, user_message),
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
) -> connection.Outcome {
  case process.selector_receive_forever(selector) {
    Closed -> stopped(conn, state, on_close)
    Failed(reason) ->
      ended(conn, state, on_close, connection.StoppedAbnormal(reason))
    Exhausted ->
      case activate(conn) {
        Ok(Nil) -> loop(conn, selector, state, step, on_close)
        Error(reason) -> socket_failed(conn, state, on_close, reason)
      }
    Packet(data) ->
      websocks.push_data(conn.context, data)
      |> with_context(conn, _)
      |> drain(selector, state, step, on_close)
    Received(message) ->
      websocket.UserMessage(message)
      |> deliver(conn, selector, state, step, on_close, AwaitSocket, _)
  }
}

fn drain(
  conn: http1.WebsocketConnection,
  selector: process.Selector(Received(user_message)),
  state: user_state,
  step: fn(
    connection.WebsocketConnection,
    user_state,
    websocket.Message(user_message),
  ) -> websocket.Step(user_state, user_message),
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
) -> connection.Outcome {
  case websocks.next_frame(conn.context) {
    Error(_violation) ->
      close(conn, websocks.CloseReason(websocks.ProtocolError, ""))
      |> resolve(conn, state, on_close, _)
    Ok(websocks.MoreData(context:)) ->
      with_context(conn, context)
      |> loop(selector, state, step, on_close)
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
            Ok(Nil) -> drain(conn, selector, state, step, on_close)
            Error(reason) -> socket_failed(conn, state, on_close, reason)
          }
        websocks.Control(websocks.Pong(_payload)) ->
          drain(conn, selector, state, step, on_close)
        websocks.Control(websocks.Close(reason)) ->
          close(conn, reason) |> resolve(conn, state, on_close, _)
        websocks.Text(payload) ->
          websocket.TextFrame(unsafe_to_string(payload))
          |> deliver(conn, selector, state, step, on_close, DrainBuffer, _)
        websocks.Binary(payload) ->
          websocket.BinaryFrame(payload)
          |> deliver(conn, selector, state, step, on_close, DrainBuffer, _)
        websocks.Continuation(_payload) ->
          drain(conn, selector, state, step, on_close)
      }
    }
  }
}

fn deliver(
  conn: http1.WebsocketConnection,
  selector: process.Selector(Received(user_message)),
  state: user_state,
  step: fn(
    connection.WebsocketConnection,
    user_state,
    websocket.Message(user_message),
  ) -> websocket.Step(user_state, user_message),
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
  resume: Resume,
  message: websocket.Message(user_message),
) -> connection.Outcome {
  let handle = connection.Http1Websocket(conn)

  case rescue.handler(fn() { step(handle, state, message) }) {
    Error(details) -> crashed(conn, state, on_close, details)
    Ok(websocket.Proceed(user_state: state, messages:)) -> {
      let selector = case messages {
        option.Some(messages) -> merge_socket_selector(messages)
        option.None -> selector
      }

      case resume {
        DrainBuffer -> drain(conn, selector, state, step, on_close)
        AwaitSocket -> loop(conn, selector, state, step, on_close)
      }
    }
    Ok(websocket.Halt(outcome)) -> ended(conn, state, on_close, outcome)
  }
}

fn resolve(
  conn: http1.WebsocketConnection,
  state: user_state,
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
  sent: Result(Nil, socket.SocketReason),
) -> connection.Outcome {
  case sent {
    Ok(Nil) -> stopped(conn, state, on_close)
    Error(reason) -> socket_failed(conn, state, on_close, reason)
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
  websocks.encode_close_frame(reason:, masking: option.None)
  |> write(conn, _)
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
  transport.set_opts(conn.transport, conn.socket, [
    options.ActiveMode(options.Count(http1.active_count)),
  ])
  |> result.replace_error(socket.Closed)
}

type Received(user_message) {
  Received(user_message)
  Packet(BitArray)
  Closed
  Failed(reason: String)
  Exhausted
}

fn merge_socket_selector(
  messages: process.Selector(user_message),
) -> process.Selector(Received(user_message)) {
  process.map_selector(messages, Received)
  |> process.merge_selector(socket_selector())
}

fn socket_selector() -> process.Selector(Received(user_message)) {
  process.new_selector()
  |> process.select_record(atom.create("tcp"), 2, packet)
  |> process.select_record(atom.create("ssl"), 2, packet)
  |> process.select_record(atom.create("tcp_closed"), 1, closed)
  |> process.select_record(atom.create("ssl_closed"), 1, closed)
  |> process.select_record(atom.create("tcp_error"), 2, failed)
  |> process.select_record(atom.create("ssl_error"), 2, failed)
  |> process.select_record(atom.create("tcp_passive"), 1, exhausted)
  |> process.select_record(atom.create("ssl_passive"), 1, exhausted)
}

fn packet(record: dynamic.Dynamic) -> Received(user_message) {
  Packet(socket_payload(record))
}

fn closed(_record: dynamic.Dynamic) -> Received(user_message) {
  Closed
}

fn failed(record: dynamic.Dynamic) -> Received(user_message) {
  socket_error_reason(record)
  |> socket.reason_to_string
  |> Failed
}

fn exhausted(_record: dynamic.Dynamic) -> Received(user_message) {
  Exhausted
}

@external(erlang, "ewe_http1_ffi", "socket_error_reason")
fn socket_error_reason(record: dynamic.Dynamic) -> socket.SocketReason

@external(erlang, "ewe_websocket_ffi", "socket_payload")
fn socket_payload(record: dynamic.Dynamic) -> BitArray

@external(erlang, "ewe_ffi", "identity")
fn unsafe_to_string(payload: BitArray) -> String

@external(erlang, "ewe_ffi", "identity")
fn bit_array_from_string(text: String) -> BitArray
