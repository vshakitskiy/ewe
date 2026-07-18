import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option
import gleam/string
import logging
import mist

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Debug)

  let assert Ok(_started) =
    mist.new(handle_request)
    |> mist.port(3002)
    |> mist.start

  process.sleep_forever()
}

fn handle_request(
  request: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case request.path {
    "/hello" ->
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Hello, Joe!")))
    "/whoami" ->
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.from_string(
        "method=" <> method_to_string(request.method),
      )))
    "/echo" ->
      case mist.read_body(request, 10_000_000) {
        Ok(req) ->
          response.new(200)
          |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(req.body)))
        Error(_error) ->
          response.new(400) |> response.set_body(mist.Bytes(bytes_tree.new()))
      }
    "/file/small" -> {
      // head -c 100K /dev/urandom > file_100kb.bin
      let assert Ok(file) =
        mist.send_file(
          "./dev/priv/file_100kb.bin",
          offset: 0,
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
        mist.send_file("./dev/priv/file_1gb.bin", offset: 0, limit: option.None)

      response.Response(
        status: 200,
        headers: [#("content-type", "application/octet-stream")],
        body: file,
      )
    }
    _ ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn method_to_string(method: http.Method) -> String {
  case method {
    http.Other(name) -> "Other(" <> name <> ")"
    _other -> string.inspect(method)
  }
}
