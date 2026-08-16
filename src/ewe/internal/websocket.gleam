import ewe/internal/connection
import gleam/erlang/process
import gleam/option

pub type Step(user_state, user_message) {
  Proceed(
    user_state: user_state,
    messages: option.Option(process.Selector(user_message)),
  )
  Halt(connection.Outcome)
}

pub type Message(user_message) {
  TextFrame(text: String)
  BinaryFrame(data: BitArray)
  UserMessage(message: user_message)
}
