import ewe/internal/connection
import ewe/internal/http1/connection as http1
import ewe/internal/http1/encoder
import ewe/internal/sse
import ewe/internal/stream
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
    Error(reason) -> socket_failed(conn, handle, state, on_close, reason)
  }
}

/// Every way a stream ends runs the handler's `on_close`, reports whether the
/// connection survived it, and answers with the outcome.
fn ended(
  conn: http1.SseConnection,
  handle: connection.SseConnection,
  state: user_state,
  on_close: fn(connection.SseConnection, user_state) -> Nil,
  keep_alive: http1.KeepAlive,
  outcome: connection.Outcome,
) -> connection.Outcome {
  let _dead = stream.rescue_dead(fn() { on_close(handle, state) })
  finished(conn, keep_alive)
  outcome
}

/// A stream the client hung up on or one the handler could no longer write to.
fn dropped(
  conn: http1.SseConnection,
  handle: connection.SseConnection,
  state: user_state,
  on_close: fn(connection.SseConnection, user_state) -> Nil,
) -> connection.Outcome {
  ended(
    conn,
    handle,
    state,
    on_close,
    http1.CloseAfterResponse,
    connection.Stopped,
  )
}

/// The socket gave out, which ends the stream whatever it was doing.
fn socket_failed(
  conn: http1.SseConnection,
  handle: connection.SseConnection,
  state: user_state,
  on_close: fn(connection.SseConnection, user_state) -> Nil,
  reason: socket.SocketReason,
) -> connection.Outcome {
  socket.reason_to_string(reason)
  |> connection.StoppedAbnormal
  |> ended(conn, handle, state, on_close, http1.CloseAfterResponse, _)
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
    Exhausted ->
      case activate(conn) {
        Ok(Nil) -> loop(conn, handle, selector, state, reuse, step, on_close)
        Error(reason) -> socket_failed(conn, handle, state, on_close, reason)
      }
    Disconnected -> dropped(conn, handle, state, on_close)
    Failed(reason) ->
      connection.StoppedAbnormal(reason)
      |> ended(conn, handle, state, on_close, http1.CloseAfterResponse, _)
    Message(message) ->
      // A send inside the handler can find the client gone before the socket
      // has told us, so both routes out land on the same teardown.
      case stream.rescue_dead(fn() { step(handle, state, message) }) {
        Error(_reason) -> dropped(conn, handle, state, on_close)
        Ok(sse.Proceed(state)) ->
          loop(conn, handle, selector, state, reuse, step, on_close)
        Ok(sse.Halt(outcome)) ->
          ended(
            conn,
            handle,
            state,
            on_close,
            keep_alive(outcome, reuse),
            outcome,
          )
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

pub fn send(conn: http1.SseConnection, event: sse.Event) -> Nil {
  let bytes = sse.encode(event) |> encoder.frame(conn.framing)

  case transport.send(conn.transport, conn.socket, bytes) {
    Ok(Nil) -> Nil
    Error(reason) -> stream.dead(reason)
  }
}

/// glisten rearms `{active, once}` only once its loop callback returns and an
/// SSE stream does not return until it is over.
fn activate(conn: http1.SseConnection) -> Result(Nil, socket.SocketReason) {
  transport.set_opts(conn.transport, conn.socket, [
    options.ActiveMode(options.Count(http1.active_count)),
  ])
}

/// What woke the stream while it was waiting on the handler's subject.
type Received(user_message) {
  Message(user_message)
  Disconnected
  Failed(reason: String)
  ClientData
  Exhausted
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
  |> process.select_record(atom.create("tcp_passive"), 1, exhausted)
  |> process.select_record(atom.create("ssl_passive"), 1, exhausted)
}

fn exhausted(_record: dynamic.Dynamic) -> Received(user_message) {
  Exhausted
}

fn disconnected(_record: dynamic.Dynamic) -> Received(user_message) {
  Disconnected
}

fn failed(record: dynamic.Dynamic) -> Received(user_message) {
  socket_error_reason(record)
  |> socket.reason_to_string
  |> Failed
}

/// Clients are not expected to send anything once the stream is open.
fn client_data(_record: dynamic.Dynamic) -> Received(user_message) {
  ClientData
}

@external(erlang, "http1_ffi", "socket_error_reason")
fn socket_error_reason(record: dynamic.Dynamic) -> socket.SocketReason
