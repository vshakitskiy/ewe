import ewe
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Debug)

  let listener_name = process.new_name("listener_name")
  let connection_factory_name = process.new_name("connection_factory_name")

  // Start the server that has TLS enabled with certificates on disk. You can 
  // also provide any in-memory certificates.
  let assert Ok(_) =
    ewe.new(listener_name:, connection_factory_name:, handler: handle_request)
    |> ewe.bind(to: "0.0.0.0")
    |> ewe.listening(on: 8080)
    |> ewe.with_tls(ewe.Disk("priv/localhost.crt", "priv/localhost.key"))
    |> ewe.start

  process.sleep_forever()
}

fn handle_request(
  _request: request.Request(ewe.Connection),
) -> response.Response(ewe.Body) {
  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(ewe.Text("Hello, World!"))
}
