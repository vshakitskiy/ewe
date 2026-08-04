//// Echo server for the Autobahn test suite. Run `make autobahn_test`.

import ewe
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import logging

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Warning)

  let listener_name = process.new_name("autobahn_listener")
  let connection_factory_name = process.new_name("autobahn_factory")

  let assert Ok(_started) =
    ewe.new(listener_name:, connection_factory_name:, handler: handle_request)
    |> ewe.bind("0.0.0.0")
    |> ewe.listening(on: 8080)
    |> ewe.start

  process.sleep_forever()
}

fn handle_request(
  request: request.Request(ewe.Connection),
) -> response.Response(ewe.Body) {
  ewe.upgrade_websocket(
    request:,
    on_init: fn(_conn, messages) { #(Nil, messages) },
    handler: echo_message,
    on_close: fn(_conn, _state) { Nil },
  )
}

fn echo_message(
  conn: ewe.WebsocketConnection,
  state: Nil,
  message: ewe.WebsocketMessage(Nil),
) -> ewe.WebsocketNext(Nil, Nil) {
  case message {
    ewe.TextFrame(text) -> {
      ewe.send_text_frame(conn, text)
      ewe.websocket_continue(state)
    }
    ewe.BinaryFrame(data) -> {
      ewe.send_binary_frame(conn, data)
      ewe.websocket_continue(state)
    }
    ewe.UserMessage(_message) -> ewe.websocket_continue(state)
  }
}
