import ewe
import gleam/bool
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None}
import gleam/string
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  let listener_name = process.new_name("listener_name")
  let connection_factory_name = process.new_name("connection_factory_name")

  // Start a simple file server that serves files from the "public" directory.
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
  // Resolve the URL path against the `public` directory and confirm the result
  // stays inside it.
  let dir = absname("public")
  let relative = string.drop_start(request.path, 1)
  let segments = string.split(relative, "/")

  use <- bool.guard(
    when: list.any(segments, fn(segment) { segment == ".." }),
    return: not_found(),
  )

  let resolved = absname_join(dir, relative)
  case string.starts_with(resolved, dir <> "/") {
    True -> {
      // Load the file from disk with ewe.file(). This function will provide the 
      // most optimized way of serving the file in ewe.
      case ewe.file(request.body, resolved, offset: None, limit: None) {
        Ok(file) -> {
          // Using "application/octet-stream" is safe for any file type but you
          // may want to specify content-type based on file extension in
          // production.
          response.new(200)
          |> response.set_header("content-type", "application/octet-stream")
          |> response.set_body(file)
        }
        Error(_error) -> not_found()
      }
    }
    False -> not_found()
  }
}

fn not_found() -> response.Response(ewe.Body) {
  response.new(404)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(ewe.Text("File not found"))
}

@external(erlang, "filename", "absname")
fn absname(path: String) -> String

@external(erlang, "filename", "absname_join")
fn absname_join(dir: String, file: String) -> String
