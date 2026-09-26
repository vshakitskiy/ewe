import ewe/internal/connection
import logging

@external(erlang, "ewe_ffi", "rescue_handler")
pub fn run(callback: fn() -> a) -> Result(a, String)

pub fn logged(what: String, callback: fn() -> Nil) -> Nil {
  case run(callback) {
    Ok(Nil) -> Nil
    Error(details) -> log_crash(what, details)
  }
}

pub fn next(
  what: String,
  callback: fn() -> connection.Next(user_state, user_message),
) -> connection.Next(user_state, user_message) {
  case run(callback) {
    Ok(next) -> next
    Error(details) -> {
      log_crash(what, details)
      connection.StopAbnormal("the handler crashed")
    }
  }
}

fn log_crash(what: String, details: String) -> Nil {
  logging.log(
    logging.Error,
    "Caught a crash in the " <> what <> ": " <> details,
  )
}
