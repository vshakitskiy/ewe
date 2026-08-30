import ewe/glisten/socket.{type Socket, type SocketReason}
import ewe/glisten/socket/options.{type ActiveState}
import ewe/glisten/transport.{type Transport}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Selector, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import logging

@external(erlang, "ewe_glisten_ffi", "rescue")
fn rescue(func: fn() -> anything) -> Result(anything, Dynamic)

/// All message types that the handler will receive, or that you can
/// send to the handler process
pub type InternalMessage {
  Close
  Ready
  ReceiveMessage(BitArray)
  Closed
  Passive
  SocketError(SocketReason)
}

pub type Message(user_message) {
  Internal(InternalMessage)
  User(user_message)
}

pub type LoopMessage(user_message) {
  Packet(BitArray)
  Custom(user_message)
}

pub type LoopState(state, user_message) {
  LoopState(
    socket: Socket,
    sender: Subject(Message(user_message)),
    transport: Transport,
    state: state,
    active_state: ActiveState,
  )
}

pub type Connection(user_message) {
  Connection(
    socket: Socket,
    transport: Transport,
    sender: Subject(Message(user_message)),
  )
}

pub type Next(user_state, user_message) {
  Continue(
    state: user_state,
    selector: Option(Selector(user_message)),
    active_state: Option(ActiveState),
  )
  NormalStop
  AbnormalStop(reason: String)
}

pub fn continue(state: user_state) -> Next(user_state, user_message) {
  Continue(state, None, None)
}

pub fn with_selector(
  next: Next(user_state, user_message),
  selector: Selector(user_message),
) -> Next(user_state, user_message) {
  case next {
    Continue(state, _selector, active_state) ->
      Continue(state, Some(selector), active_state)
    NormalStop -> NormalStop
    AbnormalStop(reason) -> AbnormalStop(reason)
  }
}

pub fn with_active_state(
  next: Next(user_state, user_message),
  active_state: ActiveState,
) -> Next(user_state, user_message) {
  case next {
    Continue(state, selector, _active_state) ->
      Continue(state, selector, Some(active_state))
    NormalStop -> NormalStop
    AbnormalStop(reason) -> AbnormalStop(reason)
  }
}

pub fn stop() -> Next(user_state, user_message) {
  NormalStop
}

pub fn stop_abnormal(reason: String) -> Next(user_state, user_message) {
  AbnormalStop(reason)
}

fn apply_next(
  state: LoopState(state, user_message),
  res: Result(Next(state, LoopMessage(user_message)), Dynamic),
  packet_consumed: Bool,
) -> actor.Next(LoopState(state, user_message), Message(user_message)) {
  case res {
    Ok(Continue(next_state, selector, active_state)) -> {
      let state = LoopState(..state, state: next_state)

      case to_arm(state.active_state, active_state, packet_consumed) {
        None -> actor.continue(state) |> apply_selector(state.sender, selector)
        Some(active_state) ->
          case
            transport.set_opts(state.transport, state.socket, [
              options.ActiveMode(active_state),
            ])
          {
            Ok(Nil) ->
              actor.continue(LoopState(..state, active_state:))
              |> apply_selector(state.sender, selector)
            Error(_reason) -> actor.stop()
          }
      }
    }
    Ok(NormalStop) -> actor.stop()
    Ok(AbnormalStop(reason)) -> actor.stop_abnormal(reason)
    Error(reason) -> {
      logging.log(
        logging.Error,
        "Caught error in user handler: " <> string.inspect(reason),
      )
      actor.continue(state)
    }
  }
}

// A socket left in `Once` goes passive again after every packet, so it has to
// be re-armed once one has been consumed.
fn to_arm(
  current: ActiveState,
  requested: Option(ActiveState),
  packet_consumed: Bool,
) -> Option(ActiveState) {
  case requested, current, packet_consumed {
    Some(requested), _current, _packet_consumed -> Some(requested)
    None, options.Once, True -> Some(options.Once)
    None, _current, _packet_consumed -> None
  }
}

// Applies a selector returned from `Continue`.
fn apply_selector(
  next: actor.Next(LoopState(state, user_message), Message(user_message)),
  sender: Subject(Message(user_message)),
  selector: Option(Selector(LoopMessage(user_message))),
) -> actor.Next(LoopState(state, user_message), Message(user_message)) {
  case selector {
    None -> next
    Some(selector) -> {
      let mapped =
        process.map_selector(selector, fn(loop_message) {
          case loop_message {
            Custom(message) -> User(message)
            Packet(bits) -> Internal(ReceiveMessage(bits))
          }
        })

      actor.with_selector(
        next,
        internal_selector(sender) |> process.merge_selector(mapped),
      )
    }
  }
}

// The internal selector that contains socket events mapped to `Internal` plus
// the connection's own subject.
fn internal_selector(
  sender: Subject(Message(user_message)),
) -> Selector(Message(user_message)) {
  process.new_selector()
  |> process.select_record(atom.create("tcp"), 2, data)
  |> process.select_record(atom.create("ssl"), 2, data)
  |> process.select_record(atom.create("tcp_closed"), 1, closed)
  |> process.select_record(atom.create("ssl_closed"), 1, closed)
  |> process.select_record(atom.create("tcp_passive"), 1, passive)
  |> process.select_record(atom.create("ssl_passive"), 1, passive)
  |> process.select_record(atom.create("tcp_error"), 2, error)
  |> process.select_record(atom.create("ssl_error"), 2, error)
  |> process.map_selector(Internal)
  |> process.merge_selector(process.new_selector() |> process.select(sender))
}

fn data(record: dynamic.Dynamic) -> InternalMessage {
  ReceiveMessage(socket_data(record))
}

fn closed(_record: dynamic.Dynamic) -> InternalMessage {
  Closed
}

fn passive(_record: dynamic.Dynamic) -> InternalMessage {
  Passive
}

fn error(record: dynamic.Dynamic) -> InternalMessage {
  socket_error(record)
  |> SocketError
}

pub type Loop(state, user_message) =
  fn(state, LoopMessage(user_message), Connection(user_message)) ->
    Next(state, LoopMessage(user_message))

pub type Handler(state, user_message) {
  Handler(
    socket: Socket,
    loop: Loop(state, user_message),
    on_init: fn(Connection(user_message)) ->
      #(state, Option(Selector(user_message))),
    transport: Transport,
    active_state: ActiveState,
  )
}

/// Starts an actor for the TCP connection
pub fn start(
  handler: Handler(state, user_message),
) -> Result(actor.Started(Subject(Message(user_message))), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let connection =
      Connection(
        socket: handler.socket,
        transport: handler.transport,
        sender: subject,
      )
    let #(initial_state, user_selector) = handler.on_init(connection)

    let selector = case user_selector {
      Some(user_selector) ->
        process.map_selector(user_selector, User)
        |> process.merge_selector(internal_selector(subject), _)
      None -> internal_selector(subject)
    }

    LoopState(
      socket: handler.socket,
      sender: subject,
      transport: handler.transport,
      state: initial_state,
      active_state: handler.active_state,
    )
    |> actor.initialised()
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(fn(state, msg) {
    let connection =
      Connection(
        socket: state.socket,
        transport: state.transport,
        sender: state.sender,
      )
    case msg {
      Internal(Closed) | Internal(Close) ->
        case transport.close(state.transport, state.socket) {
          Ok(Nil) -> actor.stop()
          Error(reason) -> actor.stop_abnormal(socket.reason_to_string(reason))
        }
      Internal(Ready) ->
        case transport.handshake(state.transport, state.socket) {
          Error(Nil) -> actor.stop_abnormal("Failed to handshake socket")
          Ok(_socket) -> {
            case transport.set_buffer_size(state.transport, state.socket) {
              Ok(Nil) -> Nil
              Error(Nil) ->
                logging.log(logging.Warning, "Failed to read `recbuf` size")
            }
            // Note that the active_state must set to Passive at start of
            // Listener/Accept and not changed until the Ready message is
            // received.
            arm_socket(state)
          }
        }
      User(message) -> {
        let next =
          rescue(fn() { handler.loop(state.state, Custom(message), connection) })
        apply_next(state, next, False)
      }
      Internal(ReceiveMessage(packet)) -> {
        let next =
          rescue(fn() { handler.loop(state.state, Packet(packet), connection) })
        apply_next(state, next, True)
      }
      Internal(Passive) -> arm_socket(state)
      Internal(SocketError(reason)) ->
        actor.stop_abnormal(
          "Received socket error " <> socket.reason_to_string(reason),
        )
    }
  })
  |> actor.start()
}

fn arm_socket(
  state: LoopState(state, user_message),
) -> actor.Next(LoopState(state, user_message), Message(user_message)) {
  case
    transport.set_opts(state.transport, state.socket, [
      options.ActiveMode(state.active_state),
    ])
  {
    Ok(Nil) -> actor.continue(state)
    Error(_reason) -> actor.stop_abnormal("Failed to set socket active")
  }
}

@external(erlang, "ewe_glisten_ffi", "socket_data")
fn socket_data(record: Dynamic) -> BitArray

@external(erlang, "ewe_glisten_ffi", "socket_data")
fn socket_error(record: Dynamic) -> SocketReason
