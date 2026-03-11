import ewe/internal/http2/message.{type ConnectionMessage, type StreamMessage}
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/otp/actor

type State {
  State(
    stream_id: Int,
    stream_subject: process.Subject(StreamMessage),
    connection: process.Subject(ConnectionMessage),
    request: Request(String),
    end_stream: Bool,
    window_size: Int,
    buffer: BitArray,
  )
}

type Message {
  Run
  Incoming(StreamMessage)
}

pub fn start(
  stream_id: Int,
  request: Request(String),
  end_stream: Bool,
  connection: process.Subject(ConnectionMessage),
  window_size: Int,
) -> Result(actor.Started(process.Subject(StreamMessage)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(_) {
    let stream_subject = process.new_subject()
    let self = process.new_subject()

    process.send(self, Run)

    let selector =
      process.new_selector()
      |> process.select(for: self)
      |> process.select_map(for: stream_subject, mapping: Incoming)

    actor.initialised(
      State(
        stream_id:,
        stream_subject:,
        connection:,
        request:,
        end_stream:,
        window_size:,
        buffer: <<>>,
      ),
    )
    |> actor.selecting(selector)
    |> actor.returning(stream_subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start()
}

fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    Run -> todo
    Incoming(message.Reset(_)) -> actor.stop()
    Incoming(message.Data(..)) -> actor.continue(state)
  }
}
