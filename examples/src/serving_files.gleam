import ewe.{type Response}
import gleam/erlang/process
import gleam/http/response
import gleam/option.{None}
import gleam/string
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  // Start a simple file server that serves files from the "public" directory.
  //
  let assert Ok(_) =
    ewe.new(fn(req) { serve_file(req.path) })
    |> ewe.bind("0.0.0.0")
    |> ewe.listening(port: 8080)
    |> ewe.start

  process.sleep_forever()
}

fn serve_file(path: String) -> Response {
  // Resolve the URL path against the `public` directory and confirm the result 
  // stays inside it.
  //
  let dir = absname("public")
  let relative = string.drop_start(path, 1)
  let resolved = absname_join(dir, relative)

  case string.starts_with(resolved, dir <> "/") {
    True -> {
      // Load file from disk using ewe.file(). This efficiently streams the file
      // content without loading it entirely into memory.
      //
      case ewe.file(resolved, offset: None, limit: None) {
        Ok(file) -> {
          // Using "application/octet-stream" is safe for any file type, but you
          // may want to specify content-type based on file extension in 
          // production.
          //
          response.new(200)
          |> response.set_header("content-type", "application/octet-stream")
          |> response.set_body(file)
        }
        Error(_) -> not_found()
      }
    }
    False -> not_found()
  }
}

fn not_found() -> Response {
  response.new(404)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(ewe.TextData("File not found"))
}

@external(erlang, "filename", "absname")
fn absname(path: String) -> String

@external(erlang, "filename", "absname_join")
fn absname_join(dir: String, file: String) -> String
