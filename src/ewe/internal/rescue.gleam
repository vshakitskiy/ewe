@external(erlang, "ewe_ffi", "rescue_handler")
pub fn handler(handler: fn() -> a) -> Result(a, String)
