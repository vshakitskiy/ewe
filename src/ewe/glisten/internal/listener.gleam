import ewe/glisten/socket.{type ListenSocket}
import ewe/glisten/socket/options.{type TcpOption}
import ewe/glisten/transport.{type Transport}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import logging

pub type Message {
  Info(caller: Subject(State))
}

pub type State {
  State(listen_socket: ListenSocket, sock_name: socket.SockName)
}

pub fn start(
  port: Int,
  transport: Transport,
  options: List(TcpOption),
  name: process.Name(Message),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    transport.listen(transport, port, options)
    |> result.try(fn(socket) {
      transport.sockname(transport, socket)
      |> result.map(fn(sock_name) { State(listen_socket: socket, sock_name:) })
    })
    |> result.map(fn(state) {
      state
      |> actor.initialised
      |> actor.selecting(
        process.new_selector()
        |> process.select(subject),
      )
      |> actor.returning(subject)
    })
    |> result.map_error(fn(err) {
      let error_string =
        "Failed to start socket listener: " <> socket.reason_to_string(err)
      logging.log(logging.Error, error_string)
      error_string
    })
  })
  |> actor.on_message(fn(state, msg) {
    case msg {
      Info(caller) -> {
        process.send(caller, state)
        actor.continue(state)
      }
    }
  })
  |> actor.named(name)
  |> actor.start
}
