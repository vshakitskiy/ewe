import ewe
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/option
import logging

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Debug)

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
  case request.path {
    "/hello" ->
      response.new(200)
      |> response.set_body(ewe.Text("Hello, Joe!"))
    "/echo" ->
      case ewe.read_body(request, 10_000_000) {
        Ok(req) ->
          response.new(200)
          |> response.set_body(ewe.Bytes(bytes_tree.from_bit_array(req.body)))
        Error(_error) -> response.new(400) |> response.set_body(ewe.Empty)
      }
    "/file/small" -> {
      // head -c 100K /dev/urandom > file_100kb.bin
      let assert Ok(file) =
        ewe.file(
          "./dev/priv/file_100kb.bin",
          offset: option.None,
          limit: option.None,
        )

      response.Response(
        status: 200,
        headers: [#("content-type", "application/octet-stream")],
        body: file,
      )
    }
    "/file/big" -> {
      // head -c 1G /dev/urandom > file_1gb.bin
      let assert Ok(file) =
        ewe.file(
          "./dev/priv/file_1gb.bin",
          offset: option.None,
          limit: option.None,
        )

      response.Response(
        status: 200,
        headers: [#("content-type", "application/octet-stream")],
        body: file,
      )
    }
    _ ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}
