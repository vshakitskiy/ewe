import ewe/internal/connection
import ewe/internal/http1/connection as http1
import ewe/internal/stream
import ewe/internal/websocket
import gleam/bytes_tree
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/http
import gleam/option
import gleam/result
import glisten/socket
import glisten/socket/options
import glisten/transport
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

/// What the handshake settled on. The key the client checks the reply against
/// and the compression it asked for.
pub type Handshake {
  Handshake(
    accept: String,
    compression: option.Option(websocks.CompressionExtensions),
  )
}

/// Everything this needs was picked up while the headers were parsed so the
/// request is not walked again here.
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

/// How many socket messages are delivered before the loop rearms.
const active_count = 100

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
    Error(reason) ->
      socket.reason_to_string(reason)
      |> connection.StoppedAbnormal
      |> ended(conn, state, on_close, _)
  }
}

/// Every way a socket ends frees the compression resources the context holds
/// and runs the handler's `on_close`.
fn ended(
  conn: http1.WebsocketConnection,
  state: user_state,
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
  outcome: connection.Outcome,
) -> connection.Outcome {
  websocks.close_context(conn.context)
  on_close(connection.Http1Websocket(conn), state)
  outcome
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
    Closed -> ended(conn, state, on_close, connection.Stopped)
    Failed(reason) ->
      ended(conn, state, on_close, connection.StoppedAbnormal(reason))
    Exhausted ->
      case activate(conn) {
        Ok(Nil) -> loop(conn, selector, state, step, on_close)
        Error(reason) ->
          socket.reason_to_string(reason)
          |> connection.StoppedAbnormal
          |> ended(conn, state, on_close, _)
      }
    Packet(data) ->
      websocks.push_data(conn.context, data)
      |> with_context(conn, _)
      |> drain(selector, state, step, on_close)
    Received(message) ->
      websocket.UserMessage(message)
      |> deliver(conn, selector, state, step, on_close, _)
  }
}

/// One read can carry several frames so the buffer is drained before the loop
/// waits on the socket again.
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
        // Answered here rather than handed on since a peer's keepalive is not
        // the handler's business.
        websocks.Control(websocks.Ping(payload)) ->
          case
            write(conn, websocks.encode_pong_frame(payload:, masking: none))
          {
            Ok(Nil) -> drain(conn, selector, state, step, on_close)
            Error(reason) ->
              socket.reason_to_string(reason)
              |> connection.StoppedAbnormal
              |> ended(conn, state, on_close, _)
          }
        websocks.Control(websocks.Pong(_payload)) ->
          drain(conn, selector, state, step, on_close)
        // The peer started the closing handshake so it is echoed back and the
        // socket is done.
        websocks.Control(websocks.Close(reason)) ->
          close(conn, reason) |> resolve(conn, state, on_close, _)
        websocks.Text(payload) ->
          websocket.TextFrame(unsafe_to_string(payload))
          |> deliver(conn, selector, state, step, on_close, _)
        websocks.Binary(payload) ->
          websocket.BinaryFrame(payload)
          |> deliver(conn, selector, state, step, on_close, _)
        // Fragments are reassembled by the decoder so one never surfaces.
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
  message: websocket.Message(user_message),
) -> connection.Outcome {
  let handle = connection.Http1Websocket(conn)

  case stream.rescue_dead(fn() { step(handle, state, message) }) {
    Error(_reason) -> ended(conn, state, on_close, connection.Stopped)
    Ok(websocket.Proceed(user_state: state, messages:)) -> {
      let selector = case messages {
        option.Some(messages) -> merge_socket_selector(messages)
        option.None -> selector
      }

      drain(conn, selector, state, step, on_close)
    }
    Ok(websocket.Halt(outcome)) -> ended(conn, state, on_close, outcome)
  }
}

/// A close the server sends ends the socket either way, so only whether the
/// frame reached the peer decides how it is reported.
fn resolve(
  conn: http1.WebsocketConnection,
  state: user_state,
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
  sent: Result(Nil, socket.SocketReason),
) -> connection.Outcome {
  case sent {
    Ok(Nil) -> ended(conn, state, on_close, connection.Stopped)
    Error(reason) ->
      socket.reason_to_string(reason)
      |> connection.StoppedAbnormal
      |> ended(conn, state, on_close, _)
  }
}

pub fn send_text(conn: http1.WebsocketConnection, text: String) -> Nil {
  websocks.encode_text_frame(
    payload: bit_array_from_string(text),
    context: conn.context,
    masking: none,
  )
  |> write_or_die(conn, _)
}

pub fn send_binary(conn: http1.WebsocketConnection, data: BitArray) -> Nil {
  websocks.encode_binary_frame(
    payload: data,
    context: conn.context,
    masking: none,
  )
  |> write_or_die(conn, _)
}

pub fn send_close(
  conn: http1.WebsocketConnection,
  reason: websocks.CloseReason,
) -> Nil {
  websocks.encode_close_frame(reason:, masking: none)
  |> write_or_die(conn, _)
}

const none = option.None

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
  write(conn, websocks.encode_close_frame(reason:, masking: none))
}

fn write(
  conn: http1.WebsocketConnection,
  frame: BitArray,
) -> Result(Nil, socket.SocketReason) {
  bytes_tree.from_bit_array(frame)
  |> transport.send(conn.transport, conn.socket, _)
}

fn write_or_die(conn: http1.WebsocketConnection, frame: BitArray) -> Nil {
  case write(conn, frame) {
    Ok(Nil) -> Nil
    Error(reason) -> stream.dead(reason)
  }
}

/// glisten rearms the socket only once its loop callback returns and a socket
/// does not return until it is over, so the frames have to be asked for here.
fn activate(
  conn: http1.WebsocketConnection,
) -> Result(Nil, socket.SocketReason) {
  transport.set_opts(conn.transport, conn.socket, [
    options.ActiveMode(options.Count(active_count)),
  ])
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

@external(erlang, "http1_ffi", "socket_error_reason")
fn socket_error_reason(record: dynamic.Dynamic) -> socket.SocketReason

@external(erlang, "websocket_ffi", "socket_payload")
fn socket_payload(record: dynamic.Dynamic) -> BitArray

@external(erlang, "ewe_ffi", "identity")
fn unsafe_to_string(payload: BitArray) -> String

@external(erlang, "ewe_ffi", "identity")
fn bit_array_from_string(text: String) -> BitArray
