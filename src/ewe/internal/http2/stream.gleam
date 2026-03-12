import ewe/internal/http
import ewe/internal/http2/message.{type ConnectionMessage, type StreamMessage}
import exception
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/otp/actor
import gleam/string
import logging

type State {
  State(
    id: Int,
    connection: process.Subject(ConnectionMessage),
    request: Request(Nil),
    end_stream: Bool,
    window_size: Int,
    buffer: BitArray,
    handler: fn(request.Request(http.Connection)) ->
      response.Response(http.ResponseBody),
  )
}

type Message {
  Run
  Incoming(StreamMessage)
}

pub fn start(
  id: Int,
  request: Request(Nil),
  handler: fn(request.Request(http.Connection)) ->
    response.Response(http.ResponseBody),
  end_stream: Bool,
  connection: process.Subject(ConnectionMessage),
  window_size: Int,
) -> Result(actor.Started(process.Subject(StreamMessage)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self) {
    let subject = process.new_subject()

    process.send(self, Run)

    let selector =
      process.new_selector()
      |> process.select(for: self)
      |> process.select_map(for: subject, mapping: Incoming)

    actor.initialised(State(
      id:,
      connection:,
      request:,
      end_stream:,
      window_size:,
      buffer: <<>>,
      handler:,
    ))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start()
}

fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    Run -> {
      let response = case
        exception.rescue(fn() {
          request.set_body(state.request, http.Http2Connection)
          |> state.handler
        })
      {
        Ok(response) -> response
        Error(error) -> {
          logging.log(
            logging.Error,
            "stream handler crashed: " <> string.inspect(error),
          )
          response.new(500) |> response.set_body(http.Empty)
        }
      }

      actor.send(
        state.connection,
        message.SendResponse(stream_id: state.id, response:),
      )

      actor.stop()
    }
    Incoming(message.Reset(_)) -> actor.stop()
    Incoming(message.Data(..)) -> actor.continue(state)
  }
}
