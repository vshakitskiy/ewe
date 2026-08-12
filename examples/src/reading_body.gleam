import ewe
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/result
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  let listener_name = process.new_name("listener_name")
  let connection_factory_name = process.new_name("connection_factory_name")

  // An echo server that reads the request body and sends it back.
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
  // Preserve the original content-type from the request to send back.
  let content_type =
    request.get_header(request, "content-type")
    |> result.unwrap("application/octet-stream")

  // Read the entire request body into memory with a 10KB limit. This blocks
  // until the full body is received. For large uploads or streaming data use
  // ewe.read_body_chunk instead.
  case ewe.read_body(request, limit: 10_240) {
    Ok(req) ->
      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_body(ewe.Bytes(bytes_tree.from_bit_array(req.body)))
    Error(ewe.BodyTooLarge) ->
      response.new(413)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.Text("Body too large"))
    Error(ewe.InvalidBody) ->
      response.new(400)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.Text("Invalid request"))
  }
}
