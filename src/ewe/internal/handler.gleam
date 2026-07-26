import ewe/internal/connection
import ewe/internal/http1
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/option
import glisten
import logging

/// The connection's protocol, still undecided until the HTTP/2 preface has been
/// ruled in or out.
pub type State {
  Initialised(http1.State)
  Http1(http1.State)
  Http2
}

pub fn on_init(
  handler: fn(request.Request(connection.Connection)) ->
    response.Response(connection.Body),
) {
  fn(connection: glisten.Connection(connection.Message)) -> #(
    State,
    option.Option(process.Selector(connection.Message)),
  ) {
    let state =
      http1.State(
        handler:,
        buffer: <<>>,
        idle_timer: connection.start_idle_timer(connection),
      )

    #(Initialised(state), option.None)
  }
}

pub fn loop(
  state: State,
  message: glisten.Message(connection.Message),
  connection: glisten.Connection(connection.Message),
) -> glisten.Next(State, glisten.Message(connection.Message)) {
  case state, message {
    Initialised(state), glisten.Packet(data) -> {
      connection.cancel_idle_timer(state.idle_timer)
      let buffer = connection.append_buffer(state.buffer, data)

      case sniff_preface(buffer) {
        NeedMoreData ->
          http1.State(
            ..state,
            buffer:,
            idle_timer: connection.start_idle_timer(connection),
          )
          |> Initialised
          |> glisten.continue
        Http2Preface(_remaining) -> glisten.continue(Http2)
        NotHttp2(buffer:) ->
          http1.State(..state, buffer:, idle_timer: option.None)
          |> http1.handle_message(connection)
          |> to_glisten_next
      }
    }
    Http1(state), glisten.Packet(data) ->
      http1.State(..state, buffer: connection.append_buffer(state.buffer, data))
      |> http1.handle_message(connection)
      |> to_glisten_next
    Http2(..), glisten.Packet(_data) -> todo as "HTTP/2 is not implemented yet!"
    _state, glisten.User(connection.Timeout) -> {
      logging.log(logging.Debug, "Connection idled for too long, closing.")
      glisten.stop()
    }
  }
}

fn to_glisten_next(
  next: http1.Next,
) -> glisten.Next(State, glisten.Message(connection.Message)) {
  case next {
    http1.Continue(state) -> glisten.continue(Http1(state))
    http1.Close -> glisten.stop()
    http1.CloseAbnormal(reason:) -> glisten.stop_abnormal(reason)
  }
}

pub type Sniff {
  NeedMoreData
  Http2Preface(remaining: BitArray)
  NotHttp2(buffer: BitArray)
}

const preface = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8>>

pub fn sniff_preface(buffer: BitArray) -> Sniff {
  case buffer {
    <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8, remaining:bits>> ->
      Http2Preface(remaining:)
    _buffer ->
      case is_partial_preface(buffer, preface) {
        True -> NeedMoreData
        False -> NotHttp2(buffer:)
      }
  }
}

fn is_partial_preface(buffer: BitArray, expected: BitArray) -> Bool {
  case buffer, expected {
    <<byte, buffer:bits>>, <<wanted, expected:bits>> if byte == wanted -> {
      is_partial_preface(buffer, expected)
    }
    <<>>, _expected -> True
    _buffer, _expected -> False
  }
}
