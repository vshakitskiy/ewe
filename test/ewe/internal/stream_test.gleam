import ewe/internal/stream
import gleam/erlang/process
import glisten/socket

pub fn handler_running_to_completion_is_returned_test() {
  assert stream.rescue_dead(fn() { 42 }) == Ok(42)
}

pub fn dead_stream_unwinds_to_the_rescue_test() {
  let handler = fn() {
    stream.dead(socket.Closed)
    panic as "a dead stream must not return to its handler"
  }

  assert stream.rescue_dead(handler) == Error(socket.Closed)
}

pub fn work_after_a_dead_stream_does_not_run_test() {
  let subject = process.new_subject()

  let handler = fn() {
    stream.dead(socket.Closed)
    process.send(subject, "kept working")
  }

  let _dead = stream.rescue_dead(handler)

  assert process.receive(subject, 0) == Error(Nil)
    as "unwinding is what stops a handler producing a body nobody will read"
}

pub fn a_handler_bug_is_not_mistaken_for_a_dead_stream_test() {
  let crashed =
    rescue(fn() { stream.rescue_dead(fn() { panic as "bug in the handler" }) })

  assert crashed == Error(Nil)
    as "swallowing a bug would report it as a client that went away"
}

@external(erlang, "stream_test_ffi", "rescue")
fn rescue(handler: fn() -> a) -> Result(a, Nil)
