import glisten/socket

/// Ends the handler writing this stream, because there is no longer anywhere
/// for it to write to. Never returns.
///
/// A handler is straight line code that ewe has handed control to, so unwinding
/// is the only way to stop it doing work for a client that has gone. It also
/// keeps the one thing a handler could do about a failed write out of its way,
/// since stopping is the only sane answer.
@external(erlang, "stream_ffi", "dead")
pub fn dead(reason: socket.SocketReason) -> a

/// Runs `handler`, catching only the end that `dead` raises. Anything else a
/// handler raises is a bug and is left to crash.
@external(erlang, "stream_ffi", "rescue_dead")
pub fn rescue_dead(handler: fn() -> a) -> Result(a, socket.SocketReason)
