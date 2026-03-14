import ewe.{type Request, type Response}
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/result

pub fn main() {
  let assert Ok(_) =
    ewe.new(handle_request)
    |> ewe.listening(port: 8080)
    |> ewe.start

  process.sleep_forever()
}

fn handle_request(req: Request) -> Response {
  case req.method, request.path_segments(req) {
    http.Get, [] ->
      response.new(200)
      |> response.set_body(ewe.Empty)
    http.Get, ["user", id] ->
      response.new(200) |> response.set_body(ewe.TextData(id))
    http.Post, ["user"] -> {
      case ewe.read_body(req, 40_000_000) {
        Ok(req) -> {
          let content_type =
            req
            |> request.get_header("content-type")
            |> result.unwrap("application/octet-stream")

          response.new(200)
          |> response.set_body(ewe.BitsData(req.body))
          |> response.prepend_header("content-type", content_type)
        }
        Error(_) ->
          response.new(413)
          |> response.set_body(ewe.Empty)
      }
    }
    _, _ ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}
