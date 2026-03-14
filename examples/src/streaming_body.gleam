import ewe.{type Request, type Response}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/result
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  // A server that streams the request body back as chunked response.
  // This demonstrates how to handle large uploads.
  //
  let assert Ok(_) =
    ewe.new(handler)
    |> ewe.bind("0.0.0.0")
    |> ewe.listening(port: 8080)
    |> ewe.start()

  process.sleep_forever()
}

fn handler(req: Request) -> Response {
  // Route: /stream/{chunk_size} - controls how many bytes to read at a time.
  //
  case request.path_segments(req) {
    ["stream", chunk_size] ->
      int.parse(chunk_size)
      |> result.unwrap(16)
      |> handle_stream(req, _)
    _ ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}

pub type Message {
  Chunk(BitArray)
  Done
  BodyError(ewe.BodyError)
}

fn handle_stream(req: Request, chunk_size: Int) -> Response {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("application/octet-stream")

  // Get a consumer function for streaming the request body. This allows
  // reading data incrementally.
  //
  case ewe.stream_body(req) {
    Ok(consumer) -> {
      // For example purporses, let's set up a chunked response. The response is
      // sent in chunks as we consume the request body.
      //
      ewe.chunked_body(
        req,
        response.new(200) |> response.set_header("content-type", content_type),
        // Spawn a separate process to consume the body and send chunks.
        // This prevents blocking the handler while reading data.
        //
        on_init: fn(subject) {
          let _pid =
            fn() { stream_resource(consumer, subject, chunk_size) }
            |> process.spawn
        },
        handler: fn(chunked_body, state, message) {
          case message {
            Chunk(data) ->
              case ewe.send_chunk(chunked_body, data) {
                Ok(Nil) -> ewe.chunked_continue(state)
                Error(_) -> ewe.chunked_stop_abnormal("Failed to send chunk")
              }
            Done -> ewe.chunked_stop()
            BodyError(_body_error) ->
              ewe.chunked_stop_abnormal("failed to read body")
          }
        },
        on_close: fn(_conn, _state) {
          logging.log(logging.Info, "Stream closed")
        },
      )
    }
    Error(_) ->
      response.new(400)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Invalid request"))
  }
}

// Recursively consume chunks from the request body and send them to the
// chunked response handler via the subject.
//
fn stream_resource(
  consumer: ewe.Consumer,
  subject: Subject(Message),
  chunk_size: Int,
) -> Nil {
  // Simulating processing delay here...
  //
  process.sleep(int.random(250))
  // Call the consumer with the chunk size. It returns the next chunk of data
  // and a new consumer for the remaining body.
  //
  case consumer(chunk_size) {
    Ok(ewe.Consumed(data, next)) -> {
      logging.log(logging.Info, {
        "Consumed " <> int.to_string(bit_array.byte_size(data)) <> " bytes."
      })

      process.send(subject, Chunk(data))
      // Recursively process the next chunk.
      //
      stream_resource(next, subject, chunk_size)
    }
    Ok(ewe.Done) -> {
      process.send(subject, Done)
    }
    Error(body_error) -> {
      process.send(subject, BodyError(body_error))
    }
  }
}
