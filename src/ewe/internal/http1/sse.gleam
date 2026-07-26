import ewe/internal/connection
import ewe/internal/http1/connection as http1
import ewe/internal/http1/encoder
import ewe/internal/sse
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import glisten/socket
import glisten/socket/options
import glisten/transport

/// Runs a Server-Sent Events stream, reporting through `conn.self` whether the
/// connection can carry another request afterwards.
pub fn run(
  conn: http1.SseConnection,
  on_init: fn(process.Subject(user_message)) -> user_state,
  step: fn(connection.SseConnection, user_state, user_message) ->
    sse.Step(user_state),
  on_close: fn(connection.SseConnection, user_state) -> Nil,
) -> connection.Outcome {
  let handle = connection.Http1Sse(conn)
  let subject = process.new_subject()
  let state = on_init(subject)

  case activate(conn) {
    Ok(Nil) ->
      loop(conn, handle, selector(subject), state, Clean, step, on_close)
    Error(reason) -> {
      on_close(handle, state)
      finished(conn, http1.CloseAfterResponse)
      connection.StoppedAbnormal(socket.reason_to_string(reason))
    }
  }
}

/// Whether anything happened during the stream that rules out handing the
/// connection back for another request.
type Reuse {
  Clean
  Spoiled
}

fn loop(
  conn: http1.SseConnection,
  handle: connection.SseConnection,
  selector: process.Selector(Received(user_message)),
  state: user_state,
  reuse: Reuse,
  step: fn(connection.SseConnection, user_state, user_message) ->
    sse.Step(user_state),
  on_close: fn(connection.SseConnection, user_state) -> Nil,
) -> connection.Outcome {
  case process.selector_receive_forever(selector) {
    // Whatever the client sent has been taken off the socket and cannot be put
    // back, so the connection is no longer safe to reuse.
    ClientData -> loop(conn, handle, selector, state, Spoiled, step, on_close)
    Disconnected -> {
      on_close(handle, state)
      finished(conn, http1.CloseAfterResponse)
      connection.Stopped
    }
    Failed(reason) -> {
      on_close(handle, state)
      finished(conn, http1.CloseAfterResponse)
      connection.StoppedAbnormal(reason)
    }
    Message(message) ->
      case step(handle, state, message) {
        sse.Proceed(state) ->
          loop(conn, handle, selector, state, reuse, step, on_close)
        sse.Halt(outcome) -> {
          on_close(handle, state)
          finished(conn, keep_alive(outcome, reuse))
          outcome
        }
      }
  }
}

/// Only a stream the handler ended itself, on a connection nothing else has
/// touched, leaves the socket sitting exactly at the end of the response.
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

/// glisten re arms `{active, once}` only once its loop callback returns, and an
/// SSE stream does not return until it is over. Without switching to full
/// active mode the socket goes quiet for the whole stream, `tcp_closed`
/// included, and a client hanging up would never be noticed.
fn activate(conn: http1.SseConnection) -> Result(Nil, socket.SocketReason) {
  transport.set_opts(conn.transport, conn.socket, [
    options.ActiveMode(options.Active),
  ])
}

/// What woke the stream while it was waiting on the handler's subject.
type Received(user_message) {
  Message(user_message)
  Disconnected
  Failed(reason: String)
  ClientData
}

/// glisten handles socket messages in its own loop, which is blocked for the
/// duration of the stream, so the stream has to match them itself.
fn selector(
  subject: process.Subject(user_message),
) -> process.Selector(Received(user_message)) {
  process.new_selector()
  |> process.select_map(subject, Message)
  |> process.select_record(atom.create("tcp_closed"), 1, disconnected)
  |> process.select_record(atom.create("ssl_closed"), 1, disconnected)
  |> process.select_record(atom.create("tcp_error"), 2, failed)
  |> process.select_record(atom.create("ssl_error"), 2, failed)
  |> process.select_record(atom.create("tcp"), 2, client_data)
  |> process.select_record(atom.create("ssl"), 2, client_data)
}

fn disconnected(_record: dynamic.Dynamic) -> Received(user_message) {
  Disconnected
}

fn failed(record: dynamic.Dynamic) -> Received(user_message) {
  socket_error_reason(record)
  |> socket.reason_to_string
  |> Failed
}

/// Clients are not expected to send anything once the stream is open. Matching
/// it anyway keeps a chatty one from growing the mailbox without bound, at the
/// cost of giving up on reusing the connection.
fn client_data(_record: dynamic.Dynamic) -> Received(user_message) {
  ClientData
}

@external(erlang, "http1_ffi", "socket_error_reason")
fn socket_error_reason(record: dynamic.Dynamic) -> socket.SocketReason
