import ewe/internal/encoder
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/response.{type Response}
import gleam/otp/actor
import gleam/result
import glisten
import glisten/socket.{type Socket}
import glisten/transport.{type Transport}
import logging

/// Sends a response for a chunked transfer encoding.
///
pub fn send_response(
  resp: Response(a),
  transport: Transport,
  socket: Socket,
) -> Result(Nil, Nil) {
  case response.get_header(resp, "transfer-encoding") {
    Ok("chunked") -> resp
    _ -> response.set_header(resp, "transfer-encoding", "chunked")
  }
  |> encoder.encode_response_partially()
  |> transport.send(transport, socket, _)
  |> result.replace_error(Nil)
}

/// Represents a chunked response connection.
///
pub type ChunkedBody {
  ChunkedBody(transport: Transport, socket: Socket)
}

/// Represents an instruction on how chunked response should proceed.
///
pub type ChunkedNext(user_state) {
  Continue(user_state)
  NormalStop
  AbnormalStop(reason: String)
}

/// Starts a new chunked response connection.
///
pub fn start(
  transport: Transport,
  socket: Socket,
  on_init: fn(Subject(user_message)) -> user_state,
  handler: fn(ChunkedBody, user_state, user_message) -> ChunkedNext(user_state),
  on_close: fn(ChunkedBody, user_state) -> Nil,
) -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(1000, fn(_subject) {
    let subject = process.new_subject()
    let state = on_init(subject)

    let selector =
      process.new_selector()
      |> process.select(subject)

    actor.initialised(state)
    |> actor.returning(subject)
    |> actor.selecting(selector)
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    let conn = ChunkedBody(transport, socket)

    case handler(conn, state, message) {
      Continue(new_state) -> actor.continue(new_state)
      NormalStop -> {
        case send_end(transport, socket) {
          Ok(Nil) -> {
            on_close(conn, state)
            actor.stop()
          }
          Error(socket_reason) -> {
            let message =
              "Failed to send chunked response terminator: "
              <> socket.reason_to_string(socket_reason)

            logging.log(logging.Warning, message)
            on_close(conn, state)
            actor.stop_abnormal(message)
          }
        }
      }
      AbnormalStop(reason) -> {
        logging.log(logging.Warning, "Chunked response stopped: " <> reason)
        on_close(conn, state)
        actor.stop_abnormal(reason)
      }
    }
  })
  |> actor.start()
  |> result.map(after_start(_, transport, socket))
}

/// Maps actor's starting value to Nil.
///
fn after_start(
  started: actor.Started(Subject(user_message)),
  transport: Transport,
  socket: Socket,
) -> actor.Started(Nil) {
  let assert Ok(pid) = process.subject_owner(started.data)
  let _ = transport.controlling_process(transport, socket, pid)

  actor.Started(..started, data: Nil)
}

/// Sends the end marker for chunked transfer encoding.
///
fn send_end(
  transport: Transport,
  socket: Socket,
) -> Result(Nil, glisten.SocketReason) {
  transport.send(transport, socket, bytes_tree.from_bit_array(<<"0\r\n\r\n">>))
}

/// Sends a chunk to the client.
///
pub fn send_chunk(
  transport: Transport,
  socket: Socket,
  chunk: BitArray,
) -> Result(Nil, glisten.SocketReason) {
  bytes_tree.new()
  |> bytes_tree.append_string(to_hex_string(bit_array.byte_size(chunk)))
  |> bytes_tree.append(<<"\r\n">>)
  |> bytes_tree.append(chunk)
  |> bytes_tree.append(<<"\r\n">>)
  |> transport.send(transport, socket, _)
}

/// Converts an integer to a hexadecimal string.
///
fn to_hex_string(integer: Int) -> String {
  integer_to_list(integer, 16)
}

/// Converts an integer to a string in the given base.
///
@external(erlang, "erlang", "integer_to_list")
fn integer_to_list(integer: Int, base: Int) -> String
