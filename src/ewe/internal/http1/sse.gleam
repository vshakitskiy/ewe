import ewe/glisten/socket
import ewe/glisten/transport
import ewe/internal/connection
import ewe/internal/http1/connection as http1
import ewe/internal/http1/encoder
import ewe/internal/http1/stream
import ewe/internal/rescue
import ewe/internal/sse
import gleam/erlang/process
import gleam/option
import logging

type Handlers(user_state, user_message) {
  Handlers(
    step: fn(connection.SseConnection, user_state, user_message) ->
      connection.Step(user_state, user_message),
    on_close: fn(connection.SseConnection, user_state) -> Nil,
  )
}

pub fn run(
  conn: http1.SseConnection,
  on_init: fn(connection.SseConnection, process.Selector(user_message)) ->
    #(user_state, process.Selector(user_message)),
  step: fn(connection.SseConnection, user_state, user_message) ->
    connection.Step(user_state, user_message),
  on_close: fn(connection.SseConnection, user_state) -> Nil,
) -> connection.Outcome {
  let handlers = Handlers(step:, on_close:)
  let handle = connection.Http1Sse(conn)
  let #(state, messages) = on_init(handle, process.new_selector())

  case activate(conn) {
    Ok(Nil) ->
      loop(conn, handle, handlers, stream.selector(messages), state, Clean)
    Error(reason) -> socket_failed(conn, handle, handlers, state, reason)
  }
}

fn ended(
  conn: http1.SseConnection,
  handle: connection.SseConnection,
  handlers: Handlers(user_state, user_message),
  state: user_state,
  keep_alive: http1.KeepAlive,
  outcome: connection.Outcome,
) -> connection.Outcome {
  rescue.logged("server-sent events close handler", fn() {
    handlers.on_close(handle, state)
  })
  finished(conn, keep_alive)
  outcome
}

fn abandoned(
  conn: http1.SseConnection,
  handle: connection.SseConnection,
  handlers: Handlers(user_state, user_message),
  state: user_state,
  outcome: connection.Outcome,
) -> connection.Outcome {
  ended(conn, handle, handlers, state, http1.CloseAfterResponse, outcome)
}

fn crashed(
  conn: http1.SseConnection,
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
  |> abandoned(conn, handle, handlers, state, _)
}

fn socket_failed(
  conn: http1.SseConnection,
  handle: connection.SseConnection,
  handlers: Handlers(user_state, user_message),
  state: user_state,
  reason: socket.SocketReason,
) -> connection.Outcome {
  socket.reason_to_string(reason)
  |> connection.StoppedAbnormal
  |> abandoned(conn, handle, handlers, state, _)
}

type Reuse {
  Clean
  Spoiled
}

fn loop(
  conn: http1.SseConnection,
  handle: connection.SseConnection,
  handlers: Handlers(user_state, user_message),
  selector: process.Selector(stream.Event(user_message)),
  state: user_state,
  reuse: Reuse,
) -> connection.Outcome {
  case process.selector_receive_forever(selector) {
    stream.Packet(_data) ->
      loop(conn, handle, handlers, selector, state, Spoiled)
    stream.Exhausted ->
      case activate(conn) {
        Ok(Nil) -> loop(conn, handle, handlers, selector, state, reuse)
        Error(reason) -> socket_failed(conn, handle, handlers, state, reason)
      }
    stream.Closed ->
      abandoned(conn, handle, handlers, state, connection.Stopped)
    stream.Failed(reason) ->
      connection.StoppedAbnormal(reason)
      |> abandoned(conn, handle, handlers, state, _)
    stream.UserMessage(message) ->
      case rescue.handler(fn() { handlers.step(handle, state, message) }) {
        Error(details) -> crashed(conn, handle, handlers, state, details)
        Ok(connection.Proceed(user_state: state, messages:)) -> {
          let selector = case messages {
            option.Some(messages) -> stream.selector(messages)
            option.None -> selector
          }

          loop(conn, handle, handlers, selector, state, reuse)
        }
        Ok(connection.Halt(outcome)) ->
          ended(
            conn,
            handle,
            handlers,
            state,
            keep_alive(outcome, reuse),
            outcome,
          )
      }
  }
}

fn keep_alive(outcome: connection.Outcome, reuse: Reuse) -> http1.KeepAlive {
  case outcome, reuse {
    connection.Stopped, Clean -> http1.KeepAlive
    connection.Stopped, Spoiled -> http1.CloseAfterResponse
    connection.StoppedAbnormal(..), _reuse -> http1.CloseAfterResponse
  }
}

fn finished(conn: http1.SseConnection, keep_alive: http1.KeepAlive) -> Nil {
  http1.StreamFinished(keep_alive:)
  |> http1.StreamSignal
  |> process.send(conn.self, _)
}

pub fn send(
  conn: http1.SseConnection,
  event: sse.Event,
) -> Result(Nil, socket.SocketReason) {
  sse.encode(event)
  |> encoder.frame(conn.framing)
  |> transport.send(conn.transport, conn.socket, _)
}

fn activate(conn: http1.SseConnection) -> Result(Nil, socket.SocketReason) {
  stream.activate(conn.transport, conn.socket)
}
