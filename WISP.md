# Using ewe with Wisp

At the time of writing ewe is not an official adapter option for [wisp](https://hexdocs.pm/wisp/). 
Until a future wisp release supports ewe officially you can copy the module 
below into your project as `src/wisp/wisp_ewe.gleam`.

It needs `wisp` and `exception` alongside ewe:

```sh
gleam add wisp exception
```

```gleam
import ewe
import exception
import gleam/http/request
import gleam/http/response
import gleam/option
import gleam/string
import wisp
import wisp/internal

const max_body_size = 8_000_000

/// Convert a Wisp request handler into a function that can be run with the Ewe
/// web server.
///
/// # Examples
///
/// ```gleam
/// pub fn main() {
///   let secret_key_base = "..."
///   let listener_name = process.new_name("ewe_listener")
///   let connection_factory_name = process.new_name("ewe_connection_factory")
///
///   let assert Ok(_) =
///     handle_request
///     |> wisp_ewe.handler(secret_key_base)
///     |> ewe.new(listener_name:, connection_factory_name:, handler: _)
///     |> ewe.listening(on: 8000)
///     |> ewe.start
///
///   process.sleep_forever()
/// }
/// ```
///
/// The secret key base is used for signing and encryption. To be able to
/// verify and decrypt messages you will need to use the same key each time
/// your program is run. Keep this value secret! Malicious people with this
/// value will likely be able to hack your application.
///
pub fn handler(
  handler: fn(wisp.Request) -> wisp.Response,
  secret_key_base: String,
) -> fn(request.Request(ewe.Connection)) -> response.Response(ewe.Body) {
  fn(req: request.Request(ewe.Connection)) {
    let connection = req.body
    let wisp_req =
      internal.make_connection(ewe_body_reader(req), secret_key_base)
      |> request.set_body(req, _)

    use <- exception.defer(fn() {
      let assert Ok(_) = wisp.delete_temporary_files(wisp_req)
    })

    handler(wisp_req)
    |> ewe_response(connection)
  }
}

fn ewe_body_reader(req: request.Request(ewe.Connection)) -> internal.Reader {
  fn(size) {
    case ewe.read_body_chunk(req, max_chunk_bytes: size, limit: max_body_size) {
      Ok(ewe.Chunk(data:, request:)) ->
        Ok(internal.Chunk(data, ewe_body_reader(request)))
      Ok(ewe.Done(..)) -> Ok(internal.ReadingFinished)
      Error(_) -> Error(Nil)
    }
  }
}

fn ewe_response(
  resp: response.Response(wisp.Body),
  connection: ewe.Connection,
) -> response.Response(ewe.Body) {
  case resp.body {
    wisp.Text(text) -> response.set_body(resp, ewe.Text(text))
    wisp.Bytes(bytes) -> response.set_body(resp, ewe.Bytes(bytes))
    wisp.File(path:, offset:, limit:) ->
      ewe_send_file(resp, connection, path, offset, limit)
  }
}

fn ewe_send_file(
  resp: response.Response(wisp.Body),
  connection: ewe.Connection,
  path: String,
  offset: Int,
  limit: option.Option(Int),
) -> response.Response(ewe.Body) {
  case ewe.file(connection, path, offset: option.Some(offset), limit:) {
    Ok(file) -> response.set_body(resp, file)
    Error(error) -> {
      string.inspect(error)
      |> wisp.log_error

      response.new(500) |> response.set_body(ewe.Empty)
    }
  }
}
```
