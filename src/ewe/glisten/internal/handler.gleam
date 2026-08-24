import ewe/glisten/socket.{type Socket, type SocketReason}
import ewe/glisten/socket/options.{type ActiveState}
import ewe/glisten/transport.{type Transport}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Selector, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
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

pub type ClientIp =
  Result(socket.SockName, Nil)

pub type LoopState(state, user_message) {
  LoopState(
    client_ip: ClientIp,
    socket: Socket,
    sender: Subject(Message(user_message)),
    transport: Transport,
    state: state,
    active_state: ActiveState,
  )
}

pub type Connection(user_message) {
  Connection(
    client_ip: ClientIp,
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
    Continue(state, _, active_state) ->
      Continue(state, Some(selector), active_state)
    stop -> stop
  }
}

pub fn with_active_state(
  next: Next(user_state, user_message),
  active_state: ActiveState,
) -> Next(user_state, user_message) {
  case next {
    Continue(state, selector, _) ->
      Continue(state, selector, Some(active_state))
    stop -> stop
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
    Ok(Continue(next_state, selector, Some(new_active_state))) ->
      case
        transport.set_opts(state.transport, state.socket, [
          options.ActiveMode(new_active_state),
        ])
      {
        Ok(Nil) ->
          actor.continue(
            LoopState(
              ..state,
              state: next_state,
              active_state: new_active_state,
            ),
          )
          |> apply_selector(state.sender, selector)
        Error(_) -> actor.stop()
      }
    Ok(Continue(next_state, selector, None))
      if packet_consumed && state.active_state == options.Once
    ->
      case
        transport.set_opts(state.transport, state.socket, [
          options.ActiveMode(options.Once),
        ])
      {
        Ok(Nil) ->
          actor.continue(LoopState(..state, state: next_state))
          |> apply_selector(state.sender, selector)
        Error(_) -> actor.stop()
      }
    Ok(Continue(next_state, selector, None)) ->
      actor.continue(LoopState(..state, state: next_state))
      |> apply_selector(state.sender, selector)
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

// The intenral selector that contains socket events mapped to `Internal` plus 
// the connection's own subject.
fn internal_selector(
  sender: Subject(Message(user_message)),
) -> Selector(Message(user_message)) {
  process.new_selector()
  |> process.select_record(atom.create("tcp"), 2, fn(record) {
    ReceiveMessage(socket_data(record))
  })
  |> process.select_record(atom.create("ssl"), 2, fn(record) {
    ReceiveMessage(socket_data(record))
  })
  |> process.select_record(atom.create("ssl_closed"), 1, fn(_nil) { Closed })
  |> process.select_record(atom.create("tcp_closed"), 1, fn(_nil) { Closed })
  |> process.select_record(atom.create("ssl_passive"), 1, fn(_nil) { Passive })
  |> process.select_record(atom.create("tcp_passive"), 1, fn(_nil) { Passive })
  |> process.select_record(atom.create("tcp_error"), 2, fn(record) {
    SocketError(socket_error(record))
  })
  |> process.select_record(atom.create("ssl_error"), 2, fn(record) {
    SocketError(socket_error(record))
  })
  |> process.map_selector(Internal)
  |> process.merge_selector(process.new_selector() |> process.select(sender))
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
    on_close: Option(fn(state) -> Nil),
    transport: Transport,
    active_state: ActiveState,
  )
}

/// Starts an actor for the TCP connection
pub fn start(
  handler: Handler(state, user_message),
) -> Result(actor.Started(Subject(Message(user_message))), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let client_ip =
      transport.peername(handler.transport, handler.socket)
      |> result.replace_error(Nil)
    let connection =
      Connection(
        socket: handler.socket,
        client_ip: client_ip,
        transport: handler.transport,
        sender: subject,
      )
    let #(initial_state, user_selector) = handler.on_init(connection)
    let base_selector = process.new_selector() |> process.select(subject)
    let selector =
      process.new_selector()
      |> process.select_record(atom.create("tcp"), 2, fn(record) {
        ReceiveMessage(socket_data(record))
      })
      |> process.select_record(atom.create("ssl"), 2, fn(record) {
        ReceiveMessage(socket_data(record))
      })
      |> process.select_record(atom.create("ssl_closed"), 1, fn(_nil) { Closed })
      |> process.select_record(atom.create("tcp_closed"), 1, fn(_nil) { Closed })
      |> process.select_record(atom.create("ssl_passive"), 1, fn(_nil) {
        Passive
      })
      |> process.select_record(atom.create("tcp_passive"), 1, fn(_nil) {
        Passive
      })
      |> process.select_record(atom.create("tcp_error"), 2, fn(record) {
        SocketError(socket_error(record))
      })
      |> process.select_record(atom.create("ssl_error"), 2, fn(record) {
        SocketError(socket_error(record))
      })
      |> process.map_selector(Internal)
      |> process.merge_selector(base_selector)
    let selector = case user_selector {
      Some(sel) ->
        sel
        |> process.map_selector(User)
        |> process.merge_selector(selector, _)
      _ -> selector
    }
    LoopState(
      client_ip: client_ip,
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
        client_ip: state.client_ip,
        transport: state.transport,
        sender: state.sender,
      )
    case msg {
      Internal(Closed) | Internal(Close) ->
        case transport.close(state.transport, state.socket) {
          Ok(Nil) -> {
            let _ = case handler.on_close {
              Some(on_close) -> on_close(state.state)
              _ -> Nil
            }
            actor.stop()
          }
          Error(err) -> actor.stop_abnormal(socket.reason_to_string(err))
        }
      Internal(Ready) ->
        case transport.handshake(state.transport, state.socket) {
          Error(_) -> actor.stop_abnormal("Failed to handshake socket")
          Ok(_socket) -> {
            case transport.set_buffer_size(state.transport, state.socket) {
              Ok(_) -> Nil
              Error(_nil) -> {
                logging.log(logging.Warning, "Failed to read `recbuf` size")
              }
            }
            // Note that the active_state must set to Passive at start of
            // Listener/Accept and not changed until the Ready message is
            // received.
            let options = [options.ActiveMode(state.active_state)]
            case transport.set_opts(state.transport, state.socket, options) {
              Ok(_) -> actor.continue(state)
              Error(_) -> actor.stop_abnormal("Failed to set socket active")
            }
          }
        }
      User(msg) -> {
        let msg = Custom(msg)
        let res = rescue(fn() { handler.loop(state.state, msg, connection) })
        apply_next(state, res, False)
      }
      Internal(ReceiveMessage(msg)) -> {
        let msg = Packet(msg)
        let res = rescue(fn() { handler.loop(state.state, msg, connection) })
        apply_next(state, res, True)
      }
      Internal(Passive) -> {
        let options = [
          options.ActiveMode(state.active_state),
        ]
        case transport.set_opts(state.transport, state.socket, options) {
          Ok(_) -> actor.continue(state)
          Error(_) -> actor.stop_abnormal("Failed to set socket active")
        }
      }
      Internal(SocketError(reason)) ->
        actor.stop_abnormal(
          "Received socket error " <> socket.reason_to_string(reason),
        )
    }
  })
  |> actor.start()
}

@external(erlang, "ewe_glisten_ffi", "socket_data")
fn socket_data(record: Dynamic) -> BitArray

@external(erlang, "ewe_glisten_ffi", "socket_data")
fn socket_error(record: Dynamic) -> SocketReason
