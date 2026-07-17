import ewe
import gleam/erlang/process
import gleam/http/request
import gleam/http/response

pub fn main() -> Nil {
  let listener_name = process.new_name("listener_name")
  let connection_factory_name = process.new_name("connection_factory_name")

  let assert Ok(_started) =
    ewe.new(listener_name:, connection_factory_name:, handler: handle_request)
    |> ewe.start

  process.sleep_forever()
}

fn handle_request(
  request: request.Request(ewe.Connection),
) -> response.Response(ewe.Body) {
  echo request

  response.new(200)
  |> response.set_body(ewe.Text("Hello, Joe!"))
}
