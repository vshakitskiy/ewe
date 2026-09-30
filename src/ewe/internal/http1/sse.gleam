import ewe/internal/connection
import ewe/internal/http1
import ewe/internal/http1/connection as http1_connection
import ewe/internal/http1/encoder
import ewe/internal/rescue
import ewe/internal/sse
import gleam/erlang/process
import gleam/option
import tup/socket

type Session(user_state, user_message) {
  Session(
    conn: http1_connection.SseConnection,
    handler: fn(connection.SseConnection, user_state, user_message) ->
      connection.Next(user_state, user_message),
    on_close: fn(user_state) -> Nil,
    selector: process.Selector(http1.SocketEvent(user_message)),
    state: user_state,
    reuse: Reuse,
  )
}

type Reuse {
  Clean
  Spoiled
}

pub fn run(
  conn: http1_connection.SseConnection,
  on_init: fn(connection.SseConnection, process.Selector(user_message)) ->
    #(user_state, process.Selector(user_message)),
  handler: fn(connection.SseConnection, user_state, user_message) ->
    connection.Next(user_state, user_message),
  on_close: fn(user_state) -> Nil,
) -> connection.Outcome {
  let #(state, messages) =
    on_init(connection.Http1Sse(conn), process.new_selector())
  let session =
    Session(
      conn:,
      handler:,
      on_close:,
      selector: http1.socket_selector(messages),
      state:,
      reuse: Clean,
    )

  case activate(conn) {
    Ok(Nil) -> loop(session)
    Error(reason) -> socket_failed(session, reason)
  }
}

fn loop(session: Session(user_state, user_message)) -> connection.Outcome {
  case process.selector_receive_forever(session.selector) {
    http1.Packet(_data) -> loop(Session(..session, reuse: Spoiled))
    http1.Exhausted ->
      case activate(session.conn) {
        Ok(Nil) -> loop(session)
        Error(reason) -> socket_failed(session, reason)
      }
    http1.Closed | http1.Exited(connection.ParentExited) ->
      abandoned(session, connection.Stopped)
    http1.Exited(connection.LinkExitedNormally) -> loop(session)
    http1.Failed(reason) | http1.Exited(connection.LinkFailed(reason)) ->
      abandoned(session, connection.StoppedAbnormal(reason))
    http1.UserMessage(message) -> {
      let handle = connection.Http1Sse(session.conn)

      case
        rescue.next("server-sent events handler", fn() {
          session.handler(handle, session.state, message)
        })
      {
        connection.Continue(user_state: state, selector:) -> {
          let selector =
            option.map(selector, http1.socket_selector)
            |> option.unwrap(session.selector)

          loop(Session(..session, state:, selector:))
        }
        connection.Stop ->
          ended(session, connection.Stopped, keep_alive(session.reuse))
        connection.StopAbnormal(reason) ->
          abandoned(session, connection.StoppedAbnormal(reason))
      }
    }
  }
}

fn keep_alive(reuse: Reuse) -> http1_connection.KeepAlive {
  case reuse {
    Clean -> http1_connection.KeepAlive
    Spoiled -> http1_connection.CloseAfterResponse
  }
}

fn socket_failed(
  session: Session(user_state, user_message),
  reason: socket.SocketError,
) -> connection.Outcome {
  socket.describe_error(reason)
  |> connection.StoppedAbnormal
  |> abandoned(session, _)
}

fn abandoned(
  session: Session(user_state, user_message),
  outcome: connection.Outcome,
) -> connection.Outcome {
  ended(session, outcome, http1_connection.CloseAfterResponse)
}

fn ended(
  session: Session(user_state, user_message),
  outcome: connection.Outcome,
  keep_alive: http1_connection.KeepAlive,
) -> connection.Outcome {
  let conn = session.conn
  let _sent = encoder.end_stream(conn.transport, conn.socket, conn.framing)

  http1_connection.StreamFinished(keep_alive:)
  |> http1_connection.StreamSignal
  |> process.send(conn.self, _)

  rescue.logged("server-sent events close handler", fn() {
    session.on_close(session.state)
  })

  outcome
}

pub fn send(
  conn: http1_connection.SseConnection,
  event: sse.Event,
) -> Result(Nil, socket.SocketError) {
  sse.encode(event)
  |> encoder.frame(conn.framing)
  |> socket.send(conn.transport, conn.socket, _)
}

fn activate(
  conn: http1_connection.SseConnection,
) -> Result(Nil, socket.SocketError) {
  http1.activate(conn.transport, conn.socket)
}
