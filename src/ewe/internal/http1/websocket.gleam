import ewe/internal/connection
import ewe/internal/http1
import ewe/internal/http1/connection as http1_connection
import ewe/internal/websocket
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/option
import gleam/result
import tup/socket
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
  conn: http1_connection.Connection,
) -> Result(Handshake, HandshakeError) {
  use Nil <- result.try(case method {
    http.Get -> Ok(Nil)
    _method -> Error(MethodNotGet)
  })

  case conn.upgrade {
    option.None -> Error(NotAnUpgrade)
    option.Some(http1_connection.OtherUpgrade(..)) -> Error(NotWebsocket)
    option.Some(http1_connection.WebsocketUpgrade(key:, version:, extensions:)) -> {
      use Nil <- result.try(case version {
        option.Some("13") -> Ok(Nil)
        option.Some(_other) | option.None -> Error(UnsupportedVersion)
      })

      use key <- result.map(option.to_result(key, MissingKey))

      Handshake(
        accept: websocks.compute_accept(key),
        compression: websocket.compression(extensions),
      )
    }
  }
}

pub fn run(
  conn: http1_connection.WebsocketConnection,
  on_init: fn(connection.WebsocketConnection, process.Selector(user_message)) ->
    #(user_state, process.Selector(user_message)),
  handler: fn(
    connection.WebsocketConnection,
    user_state,
    websocket.Message(user_message),
  ) -> connection.Next(user_state, user_message),
  on_close: fn(connection.WebsocketConnection, user_state) -> Nil,
) -> connection.Outcome {
  case activate(conn) {
    Ok(Nil) ->
      websocket.run(transport(conn), conn.context, on_init, handler, on_close)
    Error(reason) -> {
      websocks.close_context(conn.context)
      connection.StoppedAbnormal(socket.describe_error(reason))
    }
  }
}

fn transport(
  conn: http1_connection.WebsocketConnection,
) -> websocket.Transport(http1.SocketEvent(user_message), user_message) {
  let send = fn(frame) {
    write(conn, frame) |> result.map_error(socket.describe_error)
  }

  websocket.Transport(
    handle: fn(context) {
      connection.Http1Websocket(
        http1_connection.WebsocketConnection(..conn, context:),
      )
    },
    selector: http1.socket_selector,
    receive: fn(selector) { receive(conn, selector) },
    send:,
    close: send,
  )
}

fn receive(
  conn: http1_connection.WebsocketConnection,
  selector: process.Selector(http1.SocketEvent(user_message)),
) -> websocket.Event(user_message) {
  case process.selector_receive_forever(selector) {
    http1.Packet(data) -> websocket.Data(data, last: False)
    http1.UserMessage(message) -> websocket.User(message)
    http1.Exhausted ->
      case activate(conn) {
        Ok(Nil) -> receive(conn, selector)
        Error(reason) -> websocket.Failed(socket.describe_error(reason))
      }
    http1.Exited(connection.LinkExitedNormally) -> receive(conn, selector)
    http1.Exited(connection.ParentExited) -> websocket.Shutdown
    http1.Closed -> websocket.Gone
    http1.Failed(reason) | http1.Exited(connection.LinkFailed(reason)) ->
      websocket.Failed(reason)
  }
}

pub fn send_text(
  conn: http1_connection.WebsocketConnection,
  text: String,
) -> Result(Nil, socket.SocketError) {
  write(conn, websocket.text_frame(conn.context, text))
}

pub fn send_binary(
  conn: http1_connection.WebsocketConnection,
  data: BitArray,
) -> Result(Nil, socket.SocketError) {
  write(conn, websocket.binary_frame(conn.context, data))
}

pub fn send_close(
  conn: http1_connection.WebsocketConnection,
  reason: websocks.CloseReason,
) -> Result(Nil, socket.SocketError) {
  write(conn, websocket.close_frame(reason))
}

fn write(
  conn: http1_connection.WebsocketConnection,
  frame: BitArray,
) -> Result(Nil, socket.SocketError) {
  bytes_tree.from_bit_array(frame)
  |> socket.send(conn.transport, conn.socket, _)
}

fn activate(
  conn: http1_connection.WebsocketConnection,
) -> Result(Nil, socket.SocketError) {
  http1.activate(conn.transport, conn.socket)
}
