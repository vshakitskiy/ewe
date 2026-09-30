import ewe/internal/connection
import ewe/internal/http1
import ewe/internal/http1/connection as http1_connection
import ewe/internal/http2
import ewe/internal/http2/connection as http2_connection
import gleam/bit_array
import gleam/erlang/process
import gleam/option
import logging
import tup
import tup/socket

pub type State {
  Detecting(Detection)
  Http1(http1.State)
  Http2(http2.State)
}

pub type Detection {
  Detection(
    expected: Expected,
    buffer: BitArray,
    idle_timer: option.Option(process.Timer),
    self: process.Subject(connection.Message),
    handler: connection.Handler,
    http1_options: http1_connection.Options,
    http2_options: http2_connection.Options,
  )
}

pub type Expected {
  OnlyHttp2
  Http1OrHttp2
}

pub fn on_init(
  handler: connection.Handler,
  http1_options: http1_connection.Options,
  http2_options: http2_connection.Options,
) {
  fn(connection: tup.Connection, selector: process.Selector(connection.Message)) {
    let self = process.new_subject()
    let idle_timer =
      connection.start_idle_timer(self, http1_options.idle_timeout)
    let detecting = fn(expected) {
      Detecting(Detection(
        expected:,
        buffer: <<>>,
        idle_timer:,
        self:,
        handler:,
        http1_options:,
        http2_options:,
      ))
    }
    let #(transport, socket) = tup.socket(connection)

    let state = case transport, socket.negotiated_protocol(transport, socket) {
      socket.Ssl, Ok(<<"h2":utf8>>) -> detecting(OnlyHttp2)
      socket.Ssl, _protocol ->
        Http1(http1.State(
          handler:,
          self:,
          buffer: <<>>,
          idle_timer:,
          options: http1_options,
        ))
      socket.Tcp, _protocol -> detecting(Http1OrHttp2)
    }

    #(state, process.select(selector, self))
  }
}

pub fn loop(
  connection: tup.Connection,
  state: State,
  message: tup.Message(connection.Message),
) -> tup.Next(State, connection.Message) {
  case state, message {
    Detecting(detection), tup.Incoming(data) ->
      detect(detection, data, connection)
    Http1(state), tup.Incoming(data) ->
      http1.State(..state, buffer: connection.append_buffer(state.buffer, data))
      |> http1.handle_message(connection)
      |> from_http1
    Http2(state), message ->
      http2.handle_message(state, message, connection)
      |> from_http2
    Detecting(..), tup.User(connection.IdleTimeout)
    | Http1(..), tup.User(connection.IdleTimeout)
    -> {
      logging.log(logging.Debug, "Connection idled for too long!")
      tup.stop()
    }
    Detecting(..), tup.User(_message) | Http1(..), tup.User(_message) ->
      tup.continue(state)
  }
}

pub fn on_close(state: State) -> Nil {
  case state {
    Http2(state) -> http2.stop_workers(state)
    Detecting(..) | Http1(..) -> Nil
  }
}

fn detect(
  detection: Detection,
  data: BitArray,
  connection: tup.Connection,
) -> tup.Next(State, connection.Message) {
  let buffer = connection.append_buffer(detection.buffer, data)

  case detection.expected, sniff_preface(buffer) {
    _expected, Http2Preface(remaining:) -> {
      connection.cancel_timer(detection.idle_timer)
      start_http2(connection, detection, remaining)
    }
    _expected, NeedMoreData ->
      tup.continue(Detecting(Detection(..detection, buffer:)))
    Http1OrHttp2, NotHttp2 ->
      http1.State(
        handler: detection.handler,
        self: detection.self,
        buffer:,
        idle_timer: detection.idle_timer,
        options: detection.http1_options,
      )
      |> http1.handle_message(connection)
      |> from_http1
    OnlyHttp2, NotHttp2 | _expected, InvalidHttp2Preface -> {
      logging.log(
        logging.Debug,
        "Closed a connection with an invalid HTTP/2 preface",
      )
      tup.stop()
    }
  }
}

fn start_http2(
  connection: tup.Connection,
  detection: Detection,
  rest: BitArray,
) -> tup.Next(State, connection.Message) {
  process.trap_exits(True)

  let commands = process.new_subject()

  let selector =
    process.new_selector()
    |> process.select(detection.self)
    |> process.select_map(commands, connection.Http2Command)
    |> process.select_trapped_exits(connection.Http2Exit)

  http2.start(
    connection,
    detection.handler,
    detection.http2_options,
    detection.self,
    commands,
    connection.parent_pid(),
    rest,
  )
  |> from_http2
  |> tup.with_selector(selector)
  |> tup.with_active_state(tup.Count(socket_active_batch_size))
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
  }
}

const socket_active_batch_size = 32

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
    _buffer ->
      case bit_array.starts_with(preface, buffer), buffer {
        True, _buffer -> NeedMoreData
        False, <<"PRI * HTTP/2.0\r\n":utf8, _rest:bits>> -> InvalidHttp2Preface
        False, _buffer -> NotHttp2
      }
  }
}
