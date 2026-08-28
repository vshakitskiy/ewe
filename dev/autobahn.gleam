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
    |> ewe.with_http2(
      ewe.Http2Options(..ewe.default_http2_options(), websocket: True),
    )
    |> ewe.start

  process.sleep_forever()
}

fn handle_request(
  request: request.Request(ewe.Connection),
) -> response.Response(ewe.Body) {
  ewe.websocket(
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
) -> ewe.Next(Nil, Nil) {
  case message {
    ewe.TextFrame(text) ->
      case ewe.send_text_frame(conn, text) {
        Ok(Nil) -> ewe.continue(state)
        Error(_send) -> ewe.stop()
      }
    ewe.BinaryFrame(data) ->
      case ewe.send_binary_frame(conn, data) {
        Ok(Nil) -> ewe.continue(state)
        Error(_send) -> ewe.stop()
      }
    ewe.UserMessage(_message) -> ewe.continue(state)
  }
}
