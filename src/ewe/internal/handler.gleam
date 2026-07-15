import gleam/erlang/process
import gleam/option
import glisten

pub type State {
  Initialised(self: process.Subject(Nil))
  Http1(idle_timer: option.Option(process.Timer), self: process.Subject(Nil))
}

pub fn on_init(_connection: glisten.Connection(Nil)) {
  let self = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(self)

  #(Initialised(self:), option.Some(selector))
}
