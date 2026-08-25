import ewe/internal/connection
import ewe/internal/http2/connection as http2
import ewe/internal/http2/stream
import ewe/internal/rescue
import ewe/internal/sse
import gleam/bytes_tree
import gleam/erlang/process
import gleam/option
import gleam/result
import logging

pub fn run(
  conn: http2.SseConnection(connection.Body),
  on_init: fn(connection.SseConnection, process.Selector(user_message)) ->
    #(user_state, process.Selector(user_message)),
  step: fn(connection.SseConnection, user_state, user_message) ->
    connection.Step(user_state, user_message),
  on_close: fn(connection.SseConnection, user_state) -> Nil,
) -> connection.Outcome {
  let handle = connection.Http2Sse(conn)
  let #(state, messages) = on_init(handle, process.new_selector())

  loop(conn, handle, merge_exit_selector(messages), state, step, on_close)
}

fn loop(
  conn: http2.SseConnection(connection.Body),
  handle: connection.SseConnection,
  selector: process.Selector(Received(user_message)),
  state: user_state,
  step: fn(connection.SseConnection, user_state, user_message) ->
    connection.Step(user_state, user_message),
  on_close: fn(connection.SseConnection, user_state) -> Nil,
) -> connection.Outcome {
  case process.selector_receive_forever(selector) {
    Interrupted -> ended(handle, state, on_close, connection.Stopped)
    Message(message) ->
      case rescue.handler(fn() { step(handle, state, message) }) {
        Error(details) -> crashed(handle, state, on_close, details)
        Ok(connection.Proceed(user_state: state, messages:)) -> {
          let selector = case messages {
            option.Some(messages) -> merge_exit_selector(messages)
            option.None -> selector
          }

          loop(conn, handle, selector, state, step, on_close)
        }
        Ok(connection.Halt(outcome)) -> {
          let outcome = ended(handle, state, on_close, outcome)

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

fn ended(
  handle: connection.SseConnection,
  state: user_state,
  on_close: fn(connection.SseConnection, user_state) -> Nil,
  outcome: connection.Outcome,
) -> connection.Outcome {
  rescue.logged("server-sent events close handler", fn() {
    on_close(handle, state)
  })
  outcome
}

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

type Received(user_message) {
  Message(user_message)
  Interrupted
}

fn merge_exit_selector(
  messages: process.Selector(user_message),
) -> process.Selector(Received(user_message)) {
  process.map_selector(messages, Message)
  |> process.merge_selector(exit_selector())
}

fn exit_selector() -> process.Selector(Received(user_message)) {
  process.new_selector()
  |> process.select_trapped_exits(fn(_exit) { Interrupted })
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
