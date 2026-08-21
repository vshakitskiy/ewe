import ewe/glisten/internal/handler.{
  type Connection, type Loop, Handler, Internal, Ready,
}
import ewe/glisten/internal/listener
import ewe/glisten/socket.{type ListenSocket, type Socket}
import ewe/glisten/socket/options.{type TcpOption}
import ewe/glisten/transport.{type Transport}
import gleam/erlang/atom
import gleam/erlang/process.{type Selector, type Subject}
import gleam/int
import gleam/option.{type Option, None}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import logging

pub type AcceptorMessage {
  AcceptConnection(ListenSocket)
}

pub type AcceptorError {
  AcceptError(socket.SocketReason)
  HandlerError(actor.StartError)
  ControlError(atom.Atom)
}

pub type AcceptorState(user_message) {
  AcceptorState(
    sender: Subject(AcceptorMessage),
    socket: Option(Socket),
    transport: Transport,
    connection_factory: factory.Supervisor(
      Socket,
      Subject(handler.Message(user_message)),
    ),
  )
}

/// Worker process that handles `accept`ing connections and starts a new process
/// which receives the messages from the socket
pub fn start(
  pool: Pool(data, user_message),
  listener_name: process.Name(listener.Message),
  connection_supervisor: process.Name(
    factory.Message(Socket, Subject(handler.Message(user_message))),
  ),
) -> Result(actor.Started(Subject(AcceptorMessage)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let listener = process.named_subject(listener_name)

    let state = process.call(listener, 750, listener.Info)
    process.send(subject, AcceptConnection(state.listen_socket))

    let connection_factory = factory.get_by_name(connection_supervisor)

    AcceptorState(subject, None, pool.transport, connection_factory)
    |> actor.initialised
    |> actor.returning(subject)
    |> actor.selecting(
      process.new_selector()
      |> process.select(subject),
    )
    |> Ok
  })
  |> actor.on_message(fn(state, msg) {
    let AcceptorState(sender, connection_factory:, ..) = state
    case msg {
      AcceptConnection(listener) -> {
        let res = {
          use sock <- result.try(
            transport.accept(state.transport, listener)
            |> result.map_error(AcceptError),
          )
          case factory.start_child(connection_factory, sock) {
            Ok(start) -> {
              transport.controlling_process(state.transport, sock, start.pid)
              |> result.map_error(ControlError)
              |> result.map(fn(_) { process.send(start.data, Internal(Ready)) })
            }
            Error(reason) -> {
              Error(HandlerError(reason))
            }
          }
        }
        case res {
          Error(reason) -> {
            let msg = case reason {
              AcceptError(reason) ->
                "acceptor failed: " <> socket.reason_to_string(reason)
              HandlerError(actor.InitTimeout) -> "init timed out"
              HandlerError(actor.InitFailed(reason)) ->
                "init failed: " <> reason
              HandlerError(actor.InitExited(process.Normal)) ->
                "init exited normally"
              HandlerError(actor.InitExited(process.Killed)) -> "init killed"
              HandlerError(actor.InitExited(process.Abnormal(..))) ->
                "init exited abnormally"
              ControlError(reason) ->
                "could not control socket: " <> atom.to_string(reason)
            }
            logging.log(
              logging.Error,
              "Failed to accept/start handler: " <> msg,
            )
            actor.stop_abnormal("Failed to accept/start handler")
          }
          _val -> {
            actor.send(sender, AcceptConnection(listener))
            actor.continue(state)
          }
        }
      }
    }
  })
  |> actor.start
}

pub type Pool(data, user_message) {
  Pool(
    handler: Loop(data, user_message),
    pool_count: Int,
    name: process.Name(
      factory.Message(Socket, Subject(handler.Message(user_message))),
    ),
    on_init: fn(Connection(user_message)) ->
      #(data, Option(Selector(user_message))),
    on_close: Option(fn(data) -> Nil),
    connection_shutdown_timeout_ms: Int,
    transport: Transport,
    active_state: options.ActiveState,
  )
}

/// Starts a pool of acceptors of size `pool_count`.
///
/// Runs `loop_fn` on ever message received
pub fn start_pool(
  pool: Pool(data, user_message),
  transport: Transport,
  port: Int,
  options: List(TcpOption),
  listener_name: process.Name(listener.Message),
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(
    supervision.worker(fn() {
      listener.start(port, transport, options, listener_name)
    }),
  )
  |> supervisor.add(
    supervision.supervisor(fn() {
      supervisor.new(supervisor.OneForOne)
      |> int.range(from: 0, to: pool.pool_count, with: _, run: fn(sup, _index) {
        supervisor.add(
          sup,
          supervision.worker(fn() { start(pool, listener_name, pool.name) }),
        )
      })
      |> supervisor.start
    }),
  )
  |> supervisor.add(
    factory.worker_child(fn(socket) {
      handler.start(Handler(
        socket:,
        loop: pool.handler,
        on_init: pool.on_init,
        on_close: pool.on_close,
        transport: pool.transport,
        active_state: pool.active_state,
      ))
    })
    |> factory.timeout(pool.connection_shutdown_timeout_ms)
    |> factory.named(pool.name)
    |> factory.restart_strategy(supervision.Temporary)
    |> factory.supervised,
  )
  |> supervisor.start
}
