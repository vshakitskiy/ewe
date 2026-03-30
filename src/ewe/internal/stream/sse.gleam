import ewe/internal/encoder
import gleam/bytes_tree
import gleam/erlang/atom
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/string_tree
import glisten/socket.{type Socket}
import glisten/socket/options.{Active, ActiveMode}
import glisten/transport.{type Transport}

/// Sends a response for a Server-Sent Events connection.
///
pub fn send_response(transport: Transport, socket: Socket) -> Result(Nil, Nil) {
  response.new(200)
  |> response.set_header("content-type", "text/event-stream")
  |> response.set_header("cache-control", "no-cache")
  |> response.set_header("connection", "keep-alive")
  |> encoder.encode_response_partially()
  |> transport.send(transport, socket, _)
  |> result.replace_error(Nil)
}

/// Represents a Server-Sent Events connection.
///
pub type SSEConnection {
  SSEConnection(transport: Transport, socket: Socket)
}

/// Represents an instruction on how Server-Sent Events connection should proceed.
///
pub type SSENext(user_state) {
  Continue(user_state)
  NormalStop
  AbnormalStop(reason: String)
}

/// Represents a message that can be sent to or received from the Server-Sent
/// Events connection.
///
pub type SSEMessages(user_message) {
  User(user_message)
  Close
}

/// Starts a new Server-Sent Events connection.
///
pub fn start(
  transport: Transport,
  socket: Socket,
  on_init: fn(Subject(user_message)) -> user_state,
  handler: fn(SSEConnection, user_state, user_message) -> SSENext(user_state),
  on_close: fn(SSEConnection, user_state) -> Nil,
) -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(1000, fn(_self) {
    let _ = transport.set_opts(transport, socket, [ActiveMode(Active)])

    let subject = process.new_subject()
    let state = on_init(subject)
    let selector = create_socket_selector(subject)

    actor.initialised(state)
    |> actor.returning(Nil)
    |> actor.selecting(selector)
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    case message {
      User(message) -> {
        let conn = SSEConnection(transport, socket)
        case handler(conn, state, message) {
          Continue(new_state) -> actor.continue(new_state)
          NormalStop -> {
            on_close(conn, state)
            actor.stop()
          }
          AbnormalStop(reason) -> {
            on_close(conn, state)
            actor.stop_abnormal(reason)
          }
        }
      }
      Close -> {
        on_close(SSEConnection(transport, socket), state)
        actor.stop()
      }
    }
  })
  |> actor.start()
}

/// Creates a selector for the Server-Sent Events connection.
///
fn create_socket_selector(
  user_subject: Subject(user_message),
) -> Selector(SSEMessages(user_message)) {
  process.new_selector()
  |> process.select_map(user_subject, fn(msg) { User(msg) })
  |> process.select_record(atom.create("tcp_closed"), 1, fn(_) { Close })
  |> process.select_record(atom.create("ssl_closed"), 1, fn(_) { Close })
}

/// Represents a Server-Sent Events event.
///
pub type SSEEvent {
  SSEEvent(
    event: Option(String),
    data: String,
    id: Option(String),
    retry: Option(Int),
  )
}

/// Sends an event to the client.
///
pub fn send_event(
  transport: Transport,
  socket: Socket,
  event: SSEEvent,
) -> Result(Nil, socket.SocketReason) {
  let id =
    option.map(event.id, format("id", _))
    |> option.unwrap("")

  let retry =
    option.map(event.retry, int.to_string)
    |> option.map(format("retry", _))
    |> option.unwrap("")

  let data =
    string_tree.from_string(event.data)
    |> string_tree.split("\n")
    |> list.map(string_tree.prepend(_, "data: "))
    |> string_tree.join("\n")

  let event =
    option.map(event.event, format("event", _))
    |> option.unwrap("")

  string_tree.new()
  |> string_tree.append(event)
  |> string_tree.append(id)
  |> string_tree.append(retry)
  |> string_tree.append_tree(data)
  |> string_tree.append("\n\n")
  |> bytes_tree.from_string_tree()
  |> transport.send(transport, socket, _)
}

/// Formats a field and value for a Server-Sent Events event.
///
fn format(field: String, value: String) {
  field <> ": " <> value <> "\n"
}
