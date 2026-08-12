import ewe
import gleam/bytes_tree
import gleam/crypto
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/result
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  let listener_name = process.new_name("listener_name")
  let connection_factory_name = process.new_name("connection_factory_name")

  // A server demonstrating different response body types and path routing.
  //
  let assert Ok(_) =
    ewe.new(listener_name:, connection_factory_name:, handler: handle_request)
    |> ewe.bind(to: "0.0.0.0")
    |> ewe.listening(on: 8080)
    |> ewe.start

  process.sleep_forever()
}

fn handle_request(
  request: request.Request(ewe.Connection),
) -> response.Response(ewe.Body) {
  // Pattern match on path segments for cleaner routing.
  // Example: "/hello/alice" becomes ["hello", "alice"]
  case request.path_segments(request) {
    ["hello", name] -> {
      // Here, we will use Text for text responses.
      response.new(200)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.Text("Hello, " <> name <> "!"))
    }
    ["bytes", amount] -> {
      // Use Bytes for binary responses. We generate random bytes to
      // demonstrate sending binary data.
      let body =
        int.parse(amount)
        |> result.unwrap(0)
        |> crypto.strong_random_bytes
        |> bytes_tree.from_bit_array
        |> ewe.Bytes

      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(body)
    }
    _segments ->
      // Use Empty for responses with no body (like 404, 204, etc).
      // You don't need to set content-type for empty bodies.
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}
