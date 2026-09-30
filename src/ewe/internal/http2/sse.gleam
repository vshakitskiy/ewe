import ewe/internal/connection
import ewe/internal/http2/connection as http2
import ewe/internal/http2/worker
import ewe/internal/rescue
import ewe/internal/sse
import gleam/bytes_tree
import gleam/erlang/process
import gleam/option
import gleam/result

type Session(user_state, user_message) {
  Session(
    conn: http2.SseConnection,
    handler: fn(connection.SseConnection, user_state, user_message) ->
      connection.Next(user_state, user_message),
    on_close: fn(user_state) -> Nil,
    selector: process.Selector(Event(user_message)),
    state: user_state,
  )
}

pub fn run(
  conn: http2.SseConnection,
  on_init: fn(connection.SseConnection, process.Selector(user_message)) ->
    #(user_state, process.Selector(user_message)),
  handler: fn(connection.SseConnection, user_state, user_message) ->
    connection.Next(user_state, user_message),
  on_close: fn(user_state) -> Nil,
) -> connection.Outcome {
  let #(state, messages) =
    on_init(connection.Http2Sse(conn), process.new_selector())

  loop(Session(
    conn:,
    handler:,
    on_close:,
    selector: selector(conn, messages),
    state:,
  ))
}

type Event(user_message) {
  UserMessage(user_message)
  Signal(http2.StreamSignal)
  Exited(connection.Exit)
}

fn selector(
  conn: http2.SseConnection,
  messages: process.Selector(user_message),
) -> process.Selector(Event(user_message)) {
  process.map_selector(messages, UserMessage)
  |> process.select_map(conn.signals, Signal)
  |> connection.select_exits(Exited)
}

fn loop(session: Session(user_state, user_message)) -> connection.Outcome {
  case process.selector_receive_forever(session.selector) {
    Exited(connection.ParentExited) -> ended(session, connection.Stopped)
    Exited(connection.LinkExitedNormally) -> loop(session)
    Exited(connection.LinkFailed(reason)) ->
      ended(session, connection.StoppedAbnormal(reason))
    Signal(http2.Draining) -> halted(session)
    UserMessage(message) -> {
      let handle = connection.Http2Sse(session.conn)

      case
        rescue.next("server-sent events handler", fn() {
          session.handler(handle, session.state, message)
        })
      {
        connection.Continue(user_state: state, selector: messages) -> {
          let selector =
            option.map(messages, selector(session.conn, _))
            |> option.unwrap(session.selector)

          loop(Session(..session, state:, selector:))
        }
        connection.Stop -> halted(session)
        connection.StopAbnormal(reason) ->
          ended(session, connection.StoppedAbnormal(reason))
      }
    }
  }
}

fn halted(session: Session(user_state, user_message)) -> connection.Outcome {
  let _sent = worker.finish_response(session.conn.writer)
  ended(session, connection.Stopped)
}

fn ended(
  session: Session(user_state, user_message),
  outcome: connection.Outcome,
) -> connection.Outcome {
  rescue.logged("server-sent events close handler", fn() {
    session.on_close(session.state)
  })

  outcome
}

pub fn send(
  conn: http2.SseConnection,
  event: sse.Event,
) -> Result(Nil, http2.Interrupted) {
  sse.encode(event)
  |> bytes_tree.to_bit_array
  |> worker.send_chunk(conn.writer, _)
  |> result.replace(Nil)
}
