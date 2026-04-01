import exception
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process.{type Selector}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import glisten/socket.{type Socket, type SocketReason}
import glisten/socket/options.{ActiveMode, Count}
import glisten/transport.{type Transport}
import logging
import websocks

/// Represents a WebSocket connection.
///
pub type WebsocketConnection {
  WebsocketConnection(
    transport: Transport,
    socket: Socket,
    context: websocks.Context,
  )
}

/// Messages that can be sent to or received from the WebSocket.
///
pub type WebsocketMessage(user_message) {
  Frame(websocks.Frame)
  UserMessage(user_message)
}

/// Control flow for WebSocket message handling.
///
pub type WebsocketNext(user_state, user_message) {
  Continue(user_state: user_state, selector: Option(Selector(user_message)))
  NormalStop
  AbnormalStop(reason: String)
}

// Internal state maintained by the WebSocket actor.
//
type WebsocketState(user_state) {
  WebsocketState(user_state: user_state, context: websocks.Context)
}

// Type alias for actor next steps.
//
type ActorNext(user_state, user_message) =
  actor.Next(WebsocketState(user_state), InternalMessage(user_message))

// Internal messages used by the WebSocket actor.
//
type InternalMessage(user_message) {
  Packet(BitArray)
  Close
  TcpPassive
  User(user_message)
  Invalid
}

// Function called when the WebSocket connection is initialized.
//
type OnInit(user_state, user_message) =
  fn(WebsocketConnection, Selector(user_message)) ->
    #(user_state, Selector(user_message))

// Function called to handle incoming WebSocket messages.
//
type Handler(user_state, user_message) =
  fn(WebsocketConnection, user_state, WebsocketMessage(user_message)) ->
    WebsocketNext(user_state, user_message)

// Function called when the WebSocket connection is closed.
//
type OnClose(user_state) =
  fn(WebsocketConnection, user_state) -> Nil

// Error message for malformed messages.
//
const malformed = "Received malformed message"

// Error message for crashed WebSocket handler.
//
const crashed = "Crash in websocket handler"

// Error message for failed PONG frame.
//
const failed_pong = "Failed to send PONG frame"

// Error message for sending WebSocket message from non-owning process.
//
const non_owning_process = "Sending WebSocket message from non-owning process"

// Active count for socket.
//
const socket_active_count = 100

/// Starts a new WebSocket connection.
///
pub fn start(
  transport: Transport,
  socket: Socket,
  on_init: OnInit(user_state, user_message),
  handler: Handler(user_state, user_message),
  on_close: OnClose(user_state),
  extensions: List(String),
  permessage_deflate: Bool,
) -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(1000, fn(_self) {
    let _ =
      transport.set_opts(transport, socket, [
        ActiveMode(Count(socket_active_count)),
      ])

    let compression = case permessage_deflate {
      True -> Some(websocks.get_compression_extensions(extensions))
      False -> None
    }

    let context = websocks.create_context(compression, websocks.Server)

    let #(user_state, user_selector) =
      WebsocketConnection(transport, socket, context)
      |> on_init(process.new_selector())

    let selector =
      process.map_selector(user_selector, User)
      |> process.merge_selector(create_socket_selector())

    WebsocketState(user_state:, context:)
    |> actor.initialised()
    |> actor.selecting(selector)
    |> actor.returning(Nil)
    |> Ok
  })
  |> actor.on_message(fn(state, msg) {
    case msg {
      Packet(data) ->
        handle_valid_packet(transport, socket, state, data, handler, on_close)
      User(user_message) ->
        handle_user_message(
          transport,
          socket,
          state,
          user_message,
          handler,
          on_close,
        )
      Close -> {
        let conn = WebsocketConnection(transport, socket, state.context)
        handle_close(on_close, state, conn, None)
      }
      Invalid -> {
        let conn = WebsocketConnection(transport, socket, state.context)
        handle_close(on_close, state, conn, Some(malformed))
      }
      TcpPassive -> {
        let _ =
          transport.set_opts(transport, socket, [
            ActiveMode(Count(socket_active_count)),
          ])
        actor.continue(state)
      }
    }
  })
  |> actor.start()
  // |> result.map(after_start(_, transport, socket))
}

// Creates selector for glisten socket events.
//
fn create_socket_selector() -> Selector(InternalMessage(user_message)) {
  process.new_selector()
  |> process.select_record(atom.create("tcp"), 2, fn(record) {
    Packet(coerce_tcp_message(record))
  })
  |> process.select_record(atom.create("ssl"), 2, fn(record) {
    Packet(coerce_tcp_message(record))
  })
  |> process.select_record(atom.create("tcp_closed"), 1, fn(_) { Close })
  |> process.select_record(atom.create("ssl_closed"), 1, fn(_) { Close })
  |> process.select_record(atom.create("tcp_passive"), 1, fn(_) { TcpPassive })
}

@external(erlang, "ewe_ffi", "coerce_tcp_message")
fn coerce_tcp_message(record: dynamic.Dynamic) -> BitArray

// Handles incoming packet data, decoding frames and processing them.
//
fn handle_valid_packet(
  transport: Transport,
  socket: Socket,
  state: WebsocketState(user_state),
  data: BitArray,
  handler: Handler(user_state, user_message),
  on_close: OnClose(user_state),
) -> ActorNext(user_state, user_message) {
  let conn = WebsocketConnection(transport, socket, state.context)
  let processed =
    websocks.process_incoming_frames(
      data,
      state.context,
      ResolveState(
        socket:,
        transport:,
        handler:,
        next: Continue(state.user_state, None),
      ),
      handle_frame,
    )

  case processed {
    Ok(#(resolved_state, context)) -> {
      case resolved_state.next {
        Continue(user_state, selector) -> {
          let next = actor.continue(WebsocketState(user_state:, context:))

          case selector {
            Some(selector) -> actor.with_selector(next, selector)
            None -> next
          }
        }
        NormalStop -> handle_close(on_close, state, conn, None)
        AbnormalStop(reason) ->
          handle_close(on_close, state, conn, Some(reason))
      }
    }
    Error(_violation) -> handle_close(on_close, state, conn, Some(malformed))
  }
}

// Represents the state of the WebSocket connection when resolving frames.
//
type ResolveState(user_state, user_message) {
  ResolveState(
    socket: Socket,
    transport: Transport,
    handler: Handler(user_state, user_message),
    next: WebsocketNext(user_state, InternalMessage(user_message)),
  )
}

/// Processes a list of frames sequentially.
///
fn handle_frame(
  state: ResolveState(user_state, user_message),
  context: websocks.Context,
  frame: websocks.Frame,
) -> websocks.ResolveNext(ResolveState(user_state, user_message)) {
  case frame {
    websocks.Control(websocks.Ping(payload)) -> {
      case bit_array.byte_size(payload) {
        size if size > 125 ->
          websocks.Stop(
            ResolveState(
              ..state,
              next: AbnormalStop(
                "control frames are only allowed to have payload up to and including 125 octets",
              ),
            ),
          )
        _ -> {
          let sent =
            transport.send(
              state.transport,
              state.socket,
              websocks.encode_pong_frame(payload, None)
                |> bytes_tree.from_bit_array(),
            )

          case sent {
            Ok(Nil) -> websocks.Continue(state)
            Error(_) ->
              websocks.Stop(
                ResolveState(..state, next: AbnormalStop(failed_pong)),
              )
          }
        }
      }
    }

    websocks.Control(websocks.Close(reason)) -> {
      let _ =
        transport.send(
          state.transport,
          state.socket,
          websocks.encode_close_frame(reason, None)
            |> bytes_tree.from_bit_array(),
        )

      websocks.Stop(ResolveState(..state, next: NormalStop))
    }

    frame -> {
      let assert Continue(user_state, selector) = state.next

      let conn = WebsocketConnection(state.transport, state.socket, context)

      let call =
        exception.rescue(fn() { state.handler(conn, user_state, Frame(frame)) })

      case call {
        Ok(Continue(user_state, new_selector)) -> {
          let next_selector =
            option.map(new_selector, process.map_selector(_, User))
            |> option.or(selector)
            |> option.map(process.merge_selector(create_socket_selector(), _))

          websocks.Continue(
            ResolveState(..state, next: Continue(user_state, next_selector)),
          )
        }
        Ok(NormalStop) -> websocks.Stop(ResolveState(..state, next: NormalStop))
        Ok(AbnormalStop(reason)) ->
          websocks.Stop(ResolveState(..state, next: AbnormalStop(reason)))
        Error(_) ->
          websocks.Stop(ResolveState(..state, next: AbnormalStop(crashed)))
      }
    }
  }
}

// Handles user messages sent to the WebSocket.
//
fn handle_user_message(
  transport: Transport,
  socket: Socket,
  state: WebsocketState(user_state),
  user_message: user_message,
  handler: Handler(user_state, user_message),
  on_close: OnClose(user_state),
) -> ActorNext(user_state, user_message) {
  let conn = WebsocketConnection(transport, socket, state.context)
  let call =
    exception.rescue(fn() {
      handler(conn, state.user_state, UserMessage(user_message))
    })

  case call {
    Ok(Continue(new_user_state, new_selector)) -> {
      let next_selector =
        option.map(new_selector, process.map_selector(_, User))
        |> option.map(process.merge_selector(create_socket_selector(), _))

      let next =
        actor.continue(WebsocketState(..state, user_state: new_user_state))

      case next_selector {
        Some(selector) -> actor.with_selector(next, selector)
        None -> next
      }
    }
    Ok(NormalStop) -> handle_close(on_close, state, conn, None)
    Ok(AbnormalStop(reason)) ->
      handle_close(on_close, state, conn, Some(reason))
    Error(_) -> handle_close(on_close, state, conn, Some(crashed))
  }
}

// Handles WebSocket connection closure.
//
fn handle_close(
  on_close: OnClose(user_state),
  state: WebsocketState(user_state),
  conn: WebsocketConnection,
  abnormal_reason: Option(String),
) -> actor.Next(WebsocketState(user_state), InternalMessage(user_message)) {
  websocks.close_context(state.context)
  on_close(conn, state.user_state)

  case abnormal_reason {
    Some(reason) -> {
      let level = case reason == crashed {
        True -> logging.Error
        False -> logging.Warning
      }
      logging.log(level, "WebSocket closed: " <> reason)
      actor.stop_abnormal(reason)
    }
    None -> actor.stop()
  }
}

/// Sends a frame to the WebSocket.
///
pub fn send_frame(
  encoder: fn(BitArray, websocks.Context, Option(BitArray)) -> BitArray,
  transport: Transport,
  socket: Socket,
  context: websocks.Context,
  payload: BitArray,
) -> Result(Nil, SocketReason) {
  let frame =
    exception.rescue(fn() {
      encoder(payload, context, option.None)
      |> bytes_tree.from_bit_array()
      |> transport.send(transport, socket, _)
    })

  case frame {
    Ok(frame) -> frame
    Error(_socket_reason) -> {
      logging.log(
        logging.Error,
        "Frame should be sent from the WebSocket connection, but was sent from different process.",
      )
      panic as non_owning_process
    }
  }
}

/// Sends a close frame to the WebSocket.
///
pub fn send_close_frame(
  transport: Transport,
  socket: Socket,
  code: websocks.CloseReason,
) -> WebsocketNext(user_state, user_message) {
  let frame =
    exception.rescue(fn() {
      websocks.encode_close_frame(code, None)
      |> bytes_tree.from_bit_array()
      |> transport.send(transport, socket, _)
    })

  case frame {
    Ok(Ok(Nil)) -> NormalStop
    Ok(Error(reason)) ->
      AbnormalStop(
        "Socket error occured while trying to send close frame: "
        <> socket.reason_to_string(reason),
      )
    Error(_reason) -> {
      logging.log(
        logging.Error,
        "Frame should be sent from the WebSocket connection, but was sent from different process.",
      )

      panic as non_owning_process
    }
  }
}
