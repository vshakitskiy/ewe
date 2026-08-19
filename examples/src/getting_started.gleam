import ewe
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import logging

pub fn main() {
  // This sets the logger to print Info level logs. I recommend using `logging`
  // package, unless you prefer other tools.
  //
  logging.configure()
  logging.set_level(logging.Info)

  // For the web server setup we need to create process names at the place where 
  // your program starts. These names are required for the acceptor pool working 
  // correctly.
  let listener_name = process.new_name("listener_name")
  let connection_factory_name = process.new_name("connection_factory_name")

  // Start the ewe web server binding to all interfaces.
  //
  let assert Ok(_) =
    ewe.new(listener_name:, connection_factory_name:, handler: handle_request)
    |> ewe.bind(to: "0.0.0.0")
    |> ewe.listening(on: 8080)
    |> ewe.start

  // Put the main process into sleep.
  //
  process.sleep_forever()
}

// This is the HTTP request handler.
//
fn handle_request(
  _request: request.Request(ewe.Connection),
) -> response.Response(ewe.Body) {
  // When sending response with body it is important to include `content-type`
  // header representing what type your body is. You don't need to specify
  // `content-length` as it is calculated automatically by ewe.
  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(ewe.Text("Hello, World!"))
}
