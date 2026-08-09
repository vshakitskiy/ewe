import ewe/internal/connection
import ewe/internal/http2/connection as http2
import ewe/internal/http2/stream
import ewe/internal/rescue
import ewe/internal/sse
import gleam/bytes_tree
import gleam/erlang/process
import gleam/erlang/reference
import gleam/result
import logging

/// Runs a Server-Sent Events stream. The response head is already written by
/// the time this is reached so there is nothing to negotiate.
pub fn run(
  conn: http2.SseConnection(connection.Body),
  on_init: fn(process.Subject(user_message)) -> user_state,
  step: fn(connection.SseConnection, user_state, user_message) ->
    sse.Step(user_state),
  on_close: fn(connection.SseConnection, user_state) -> Nil,
) -> connection.Outcome {
  let handle = connection.Http2Sse(conn)
  let tag = reference.new()
  let subject = process.unsafely_create_subject(process.self(), http2.tag(tag))

  loop(conn, handle, tag, on_init(subject), step, on_close)
}

fn loop(
  conn: http2.SseConnection(connection.Body),
  handle: connection.SseConnection,
  tag: reference.Reference,
  state: user_state,
  step: fn(connection.SseConnection, user_state, user_message) ->
    sse.Step(user_state),
  on_close: fn(connection.SseConnection, user_state) -> Nil,
) -> connection.Outcome {
  case http2.receive_reply(tag) {
    // The stream was reset or the connection went.
    Error(_interrupted) -> ended(handle, state, on_close, connection.Stopped)
    Ok(message) ->
      case rescue.handler(fn() { step(handle, state, message) }) {
        Error(details) -> crashed(handle, state, on_close, details)
        Ok(sse.Proceed(state)) -> loop(conn, handle, tag, state, step, on_close)
        Ok(sse.Halt(outcome)) -> {
          let outcome = ended(handle, state, on_close, outcome)

          // A stream the handler ended gets a clean close. An abnormal one
          // resets.
          case outcome {
            connection.Stopped -> {
              let _sent = stream.finish_response(conn.writer)
              Nil
            }
            connection.StoppedAbnormal(_reason) -> Nil
          }

          outcome
        }
      }
  }
}

/// Every ending runs `on_close` and reports the outcome.
fn ended(
  handle: connection.SseConnection,
  state: user_state,
  on_close: fn(connection.SseConnection, user_state) -> Nil,
  outcome: connection.Outcome,
) -> connection.Outcome {
  // A bug in `on_close` is still a bug. It just must not kill the process on
  // the way out of a stream that already ended.
  // TODO: logging here?
  let _crashed = rescue.handler(fn() { on_close(handle, state) })
  outcome
}

/// A crashed handler cannot say what to do next. End the stream for it and
/// reset.
fn crashed(
  handle: connection.SseConnection,
  state: user_state,
  on_close: fn(connection.SseConnection, user_state) -> Nil,
  details: String,
) -> connection.Outcome {
  logging.log(
    logging.Error,
    "Caught a crash in the server-sent events handler: " <> details,
  )

  connection.StoppedAbnormal("the handler crashed")
  |> ended(handle, state, on_close, _)
}

pub fn send(
  conn: http2.SseConnection(connection.Body),
  event: sse.Event,
) -> Result(Nil, http2.Interrupted) {
  sse.encode(event)
  |> bytes_tree.to_bit_array
  |> stream.send_chunk(conn.writer, _)
  |> result.replace(Nil)
}
