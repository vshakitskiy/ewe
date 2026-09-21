import ewe/internal/connection
import ewe/internal/http1
import ewe/internal/http1/connection as http1_connection
import ewe/internal/http2
import ewe/internal/http2/connection as http2_connection
import gleam/erlang/process
import gleam/option
import logging
import tup
import tup/socket

pub type State {
  Initialised(http1.State, http2_connection.Options, Negotiated)
  Http1(http1.State)
  Http2(http2.State)
}

pub type Negotiated {
  NegotiatedHttp1
  NegotiatedHttp2
  NotNegotiated
}

fn negotiated(connection: tup.Connection) -> Negotiated {
  let #(transport, socket) = tup.socket(connection)

  case socket.negotiated_protocol(transport, socket) {
    Ok(<<"h2":utf8>>) -> NegotiatedHttp2
    Ok(<<"http/1.1":utf8>>) -> NegotiatedHttp1
    Ok(_protocol) | Error(_reason) -> NotNegotiated
  }
}

pub fn on_init(
  handler: connection.Handler,
  http1_options: http1_connection.Options,
  http2_options: http2_connection.Options,
) {
  fn(connection: tup.Connection, selector: process.Selector(connection.Message)) {
    let self = process.new_subject()

    let state =
      http1.State(
        handler:,
        self:,
        buffer: <<>>,
        idle_timer: connection.start_idle_timer(
          self,
          http1_options.idle_timeout,
        ),
        options: http1_options,
      )

    #(
      Initialised(state, http2_options, negotiated(connection)),
      process.select(selector, self),
    )
  }
}

pub fn loop(
  connection: tup.Connection,
  state: State,
  message: tup.Message(connection.Message),
) -> tup.Next(State, connection.Message) {
  case state, message {
    Initialised(state, http2_options, negotiated), tup.Incoming(data) -> {
      connection.cancel_timer(state.idle_timer)
      let buffer = connection.append_buffer(state.buffer, data)

      case negotiated, sniff_preface(buffer) {
        NegotiatedHttp1, _sniff -> start_http1(state, buffer, connection)
        NegotiatedHttp2, NeedMoreData | NotNegotiated, NeedMoreData ->
          http1.State(
            ..state,
            buffer:,
            idle_timer: connection.start_idle_timer(
              state.self,
              state.options.idle_timeout,
            ),
          )
          |> Initialised(http2_options, negotiated)
          |> tup.continue
        NegotiatedHttp2, Http2Preface(remaining:)
        | NotNegotiated, Http2Preface(remaining:)
        -> start_http2(connection, state.handler, http2_options, remaining)
        NegotiatedHttp2, InvalidHttp2Preface
        | NegotiatedHttp2, NotHttp2
        | NotNegotiated, InvalidHttp2Preface
        -> {
          logging.log(
            logging.Debug,
            "Closed a connection with an invalid HTTP/2 preface",
          )
          tup.stop()
        }
        NotNegotiated, NotHttp2 -> start_http1(state, buffer, connection)
      }
    }
    Http1(state), tup.Incoming(data) ->
      http1.State(..state, buffer: connection.append_buffer(state.buffer, data))
      |> http1.handle_message(connection)
      |> from_http1
    Http2(state), message ->
      http2.handle_message(state, message, connection)
      |> from_http2
    Initialised(..), tup.User(connection.Timeout)
    | Http1(..), tup.User(connection.Timeout)
    -> {
      logging.log(logging.Debug, "Connection idled for too long, closing.")
      tup.stop()
    }
    Initialised(..), tup.User(_message) | Http1(..), tup.User(_message) ->
      tup.continue(state)
  }
}

fn start_http1(
  state: http1.State,
  buffer: BitArray,
  connection: tup.Connection,
) -> tup.Next(State, connection.Message) {
  http1.State(..state, buffer:, idle_timer: option.None)
  |> http1.handle_message(connection)
  |> from_http1
}

fn start_http2(
  connection: tup.Connection,
  handler: connection.Handler,
  options: http2_connection.Options,
  remaining: BitArray,
) -> tup.Next(State, connection.Message) {
  process.trap_exits(True)

  let self = process.new_subject()
  let replies = process.new_subject()

  let parent = connection.parent_pid()

  let state =
    http2.init(handler, options, self, replies, tup.peer(connection), parent)

  let selector =
    process.new_selector()
    |> process.select(self)
    |> process.select_map(replies, connection.Http2Stream)
    |> process.select_trapped_exits(connection.Http2Exit)

  case tup.send(connection, state.settings_frame) {
    Error(_reason) -> tup.stop()
    Ok(Nil) ->
      http2.handle_message(state, tup.Incoming(remaining), connection)
      |> from_http2
      |> tup.with_selector(selector)
      |> tup.with_active_state(tup.Count(http2.socket_active_batch_size))
  }
}

fn from_http1(next: http1.Next) -> tup.Next(State, connection.Message) {
  case next {
    http1.Continue(state) -> tup.continue(Http1(state))
    http1.Close -> tup.stop()
    http1.CloseAbnormal(reason:) -> tup.stop_abnormal(reason)
  }
}

fn from_http2(next: http2.Next) -> tup.Next(State, connection.Message) {
  case next {
    http2.Continue(state) -> tup.continue(Http2(state))
    http2.Close -> tup.stop()
    http2.CloseAbnormal(reason:) -> tup.stop_abnormal(reason)
  }
}

pub type Sniff {
  NeedMoreData
  Http2Preface(remaining: BitArray)
  InvalidHttp2Preface
  NotHttp2
}

const preface = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8>>

pub fn sniff_preface(buffer: BitArray) -> Sniff {
  case buffer {
    <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8, remaining:bits>> ->
      Http2Preface(remaining:)
    <<"PRI * HTTP/2.0\r\n":utf8, _remaining:bits>> ->
      case is_partial_preface(buffer, preface) {
        True -> NeedMoreData
        False -> InvalidHttp2Preface
      }
    _buffer ->
      case is_partial_preface(buffer, preface) {
        True -> NeedMoreData
        False -> NotHttp2
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
