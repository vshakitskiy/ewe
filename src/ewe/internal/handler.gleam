import ewe/internal/connection
import ewe/internal/http1
import gleam/bit_array
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/option
import glisten
import glisten/internal/handler
import logging

/// The state of a connection for its entire lifetime. It starts at 
/// `Initialised`, is classified into `Http1` or `Http2` and then stays in that 
/// variant until the connection closes.
pub type State {
  /// Accumulates bytes in `buffer` until `sniff_preface` can tell HTTP/1.x 
  /// apart from an HTTP/2 prior-knowledge preface.
  Initialised(
    handler: fn(request.Request(connection.Connection)) ->
      response.Response(connection.Body),
    buffer: BitArray,
    idle_timer: option.Option(process.Timer),
  )
  Http1(http1.State)
  /// No HTTP/2 connection handling exists yet!
  Http2
}

pub const idle_timeout = 10_000

pub fn on_init(
  handler: fn(request.Request(connection.Connection)) ->
    response.Response(connection.Body),
) {
  fn(connection: glisten.Connection(connection.Message)) -> #(
    State,
    option.Option(process.Selector(connection.Message)),
  ) {
    let timer =
      process.send_after(
        connection.subject,
        idle_timeout,
        handler.User(connection.Timeout),
      )

    #(
      Initialised(handler:, buffer: <<>>, idle_timer: option.Some(timer)),
      option.None,
    )
  }
}

pub fn loop(
  state: State,
  message: glisten.Message(connection.Message),
  connection: glisten.Connection(connection.Message),
) -> glisten.Next(State, glisten.Message(connection.Message)) {
  case message {
    glisten.User(connection.Timeout) -> {
      logging.log(logging.Debug, "Connection idled for too long, closing.")
      glisten.stop()
    }
    glisten.Packet(data) ->
      case state {
        Initialised(handler:, buffer:, idle_timer:) -> {
          case idle_timer {
            option.Some(timer) -> process.cancel_timer(timer)
            option.None -> process.TimerNotFound
          }

          let buffer = <<buffer:bits, data:bits>>
          case sniff_preface(buffer) {
            NeedMoreData -> {
              let timer =
                process.send_after(
                  connection.subject,
                  idle_timeout,
                  handler.User(connection.Timeout),
                )

              Initialised(handler:, buffer:, idle_timer: option.Some(timer))
              |> glisten.continue
            }
            Http2Preface(_remaining) -> glisten.continue(Http2)
            NotHttp2(buffer:) -> {
              let next =
                http1.State(handler:, buffer:, idle_timer: option.None)
                |> http1.handle_message(connection)

              case next {
                http1.Continue(state) -> glisten.continue(Http1(state))
                http1.Close -> glisten.stop()
              }
            }
          }
        }
        Http1(state) -> {
          let next =
            http1.State(..state, buffer: <<state.buffer:bits, data:bits>>)
            |> http1.handle_message(connection)

          case next {
            http1.Continue(state) -> glisten.continue(Http1(state))
            http1.Close -> glisten.stop()
          }
        }
        Http2(..) -> todo as "HTTP/2 connection handling not implemented yet"
      }
  }
}

pub type Sniff {
  /// Not enough bytes yet to decide.
  NeedMoreData
  /// The 24-byte preface matched fully. `remaining` is whatever followed it, 
  /// i.e. the client's initial SETTINGS frame.
  Http2Preface(remaining: BitArray)
  /// Diverged from the preface.
  NotHttp2(buffer: BitArray)
}

const preface = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8>>

/// Distinguishes an HTTP/2 prior-knowledge preface (RFC 9113 §3.4) from
/// everything else. Checked once per connection.
pub fn sniff_preface(buffer: BitArray) -> Sniff {
  case buffer {
    <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8, remaining:bits>> ->
      Http2Preface(remaining:)
    _buffer ->
      case bit_array.starts_with(preface, buffer) {
        True -> NeedMoreData
        False -> NotHttp2(buffer:)
      }
  }
}
