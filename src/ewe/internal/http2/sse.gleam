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

type Handlers(user_state, user_message) {
  Handlers(
    step: fn(connection.SseConnection, user_state, user_message) ->
      connection.Step(user_state, user_message),
    on_close: fn(connection.SseConnection, user_state) -> Nil,
  )
}

pub fn run(
  conn: http2.SseConnection(connection.Body),
  on_init: fn(connection.SseConnection, process.Selector(user_message)) ->
    #(user_state, process.Selector(user_message)),
  step: fn(connection.SseConnection, user_state, user_message) ->
    connection.Step(user_state, user_message),
  on_close: fn(connection.SseConnection, user_state) -> Nil,
) -> connection.Outcome {
  let handlers = Handlers(step:, on_close:)
  let handle = connection.Http2Sse(conn)
  let #(state, messages) = on_init(handle, process.new_selector())

  loop(conn, handle, handlers, exit_selector(messages), state)
}

fn loop(
  conn: http2.SseConnection(connection.Body),
  handle: connection.SseConnection,
  handlers: Handlers(user_state, user_message),
  selector: process.Selector(Received(user_message)),
  state: user_state,
) -> connection.Outcome {
  case process.selector_receive_forever(selector) {
    Interrupted -> ended(handle, handlers, state, connection.Stopped)
    Message(message) ->
      case rescue.handler(fn() { handlers.step(handle, state, message) }) {
        Error(details) -> crashed(handle, handlers, state, details)
        Ok(connection.Proceed(user_state: state, messages:)) -> {
          let selector = case messages {
            option.Some(messages) -> exit_selector(messages)
            option.None -> selector
          }

          loop(conn, handle, handlers, selector, state)
        }
        Ok(connection.Halt(outcome)) ->
          case ended(handle, handlers, state, outcome) {
            connection.Stopped -> {
              let _sent = stream.finish_response(conn.writer)
              connection.Stopped
            }
            connection.StoppedAbnormal(reason) ->
              connection.StoppedAbnormal(reason)
          }
      }
  }
}

fn ended(
  handle: connection.SseConnection,
  handlers: Handlers(user_state, user_message),
  state: user_state,
  outcome: connection.Outcome,
) -> connection.Outcome {
  rescue.logged("server-sent events close handler", fn() {
    handlers.on_close(handle, state)
  })
  outcome
}

fn crashed(
  handle: connection.SseConnection,
  handlers: Handlers(user_state, user_message),
  state: user_state,
  details: String,
) -> connection.Outcome {
  logging.log(
    logging.Error,
    "Caught a crash in the server-sent events handler: " <> details,
  )

  connection.StoppedAbnormal("the handler crashed")
  |> ended(handle, handlers, state, _)
}

type Received(user_message) {
  Message(user_message)
  Interrupted
}

fn exit_selector(
  messages: process.Selector(user_message),
) -> process.Selector(Received(user_message)) {
  process.map_selector(messages, Message)
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
