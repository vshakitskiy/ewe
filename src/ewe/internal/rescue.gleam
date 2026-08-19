import logging

@external(erlang, "ewe_ffi", "rescue_handler")
pub fn handler(handler: fn() -> a) -> Result(a, String)

pub fn logged(what: String, callback: fn() -> Nil) -> Nil {
  case handler(callback) {
    Ok(Nil) -> Nil
    Error(details) ->
      logging.log(
        logging.Error,
        "Caught a crash in the " <> what <> ": " <> details,
      )
  }
}
