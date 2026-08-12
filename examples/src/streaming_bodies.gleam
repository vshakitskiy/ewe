import ewe
import gleam/bit_array
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/result
import logging

const body_limit = 10_485_760

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  let listener_name = process.new_name("listener_name")
  let connection_factory_name = process.new_name("connection_factory_name")

  // A server that streams the request body back as a chunked response.
  // This demonstrates how to handle large uploads.
  //
  let assert Ok(_) =
    ewe.new(listener_name:, connection_factory_name:, handler: handle_request)
    |> ewe.bind(to: "0.0.0.0")
    |> ewe.listening(on: 8080)
    |> ewe.start

  process.sleep_forever()
}

fn handle_request(
  req: request.Request(ewe.Connection),
) -> response.Response(ewe.Body) {
  case request.path_segments(req) {
    // /stream/:max_chunk_bytes controls how many bytes to read at a time.
    ["stream", max_chunk_bytes] ->
      int.parse(max_chunk_bytes)
      |> result.unwrap(16)
      |> handle_stream(req, _)
    _segments ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}

fn handle_stream(
  req: request.Request(ewe.Connection),
  max_chunk_bytes: Int,
) -> response.Response(ewe.Body) {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("application/octet-stream")

  // Stream the response. The body is framed as chunked and every chunk we send 
  // reaches the client right away. The handler runs in the same connection 
  // process and owns the stream until it finishes it.
  response.new(200)
  |> response.set_header("content-type", content_type)
  // Remember, `echo_body(req, _, max_chunk_bytes)` is the same as:
  // fn(writer) { echo_body(req, writer, max_chunk_bytes) }
  |> ewe.stream_response(echo_body(req, _, max_chunk_bytes))
}

// Let's read the request body one chunk in a time and write each one back out,
// acting as an echo. The request body returned by `Chunk` case carries the
// rest of the body so it has to be fed into the next read to achieve correct 
// reading. 
fn echo_body(
  req: request.Request(ewe.Connection),
  writer: ewe.ResponseWriter,
  max_chunk_bytes: Int,
) -> Result(Nil, ewe.SendError) {
  // Simulating processing delay here, like some work being done...
  process.sleep(int.random(250))

  case ewe.read_body_chunk(req, max_chunk_bytes:, limit: body_limit) {
    Ok(ewe.Chunk(data:, request:)) -> {
      logging.log(logging.Info, {
        "Consumed " <> int.to_string(bit_array.byte_size(data)) <> " bytes."
      })

      use writer <- result.try(ewe.send_chunk(writer, data))
      echo_body(request, writer, max_chunk_bytes)
    }
    Ok(ewe.Done(_request)) -> ewe.finish_response(writer)
    Error(_body_error) -> {
      logging.log(logging.Info, "Failed to read the request body.")
      ewe.finish_response(writer)
    }
  }
}
