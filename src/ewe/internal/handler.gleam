import ewe/internal/connection
import ewe/internal/http1
import ewe/internal/http1/connection as http1_connection
import ewe/internal/http2
import ewe/internal/http2/connection as http2_connection
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/option
import glisten
import glisten/socket/options
import glisten/transport
import logging

/// The connection's protocol, still undecided until the HTTP/2 preface has been
/// ruled in or out.
pub type State {
  Initialised(http1.State, http2_connection.Config)
  Http1(http1.State)
  Http2(http2.State)
}

pub fn on_init(
  handler: fn(request.Request(connection.Connection)) ->
    response.Response(connection.Body),
  http1_config: http1_connection.Config,
  http2_config: http2_connection.Config,
) {
  fn(connection: glisten.Connection(connection.Message)) -> #(
    State,
    option.Option(process.Selector(connection.Message)),
  ) {
    let state =
      http1.State(
        handler:,
        buffer: <<>>,
        idle_timer: connection.start_idle_timer(
          connection,
          http1_config.idle_timeout,
        ),
        config: http1_config,
      )

    #(Initialised(state, http2_config), option.None)
  }
}

pub fn loop(
  state: State,
  message: glisten.Message(connection.Message),
  connection: glisten.Connection(connection.Message),
) -> glisten.Next(State, glisten.Message(connection.Message)) {
  case state, message {
    Initialised(state, http2_config), glisten.Packet(data) -> {
      connection.cancel_idle_timer(state.idle_timer)
      let buffer = connection.append_buffer(state.buffer, data)

      case sniff_preface(buffer) {
        NeedMoreData ->
          http1.State(
            ..state,
            buffer:,
            idle_timer: connection.start_idle_timer(
              connection,
              state.config.idle_timeout,
            ),
          )
          |> Initialised(http2_config)
          |> glisten.continue
        Http2Preface(remaining:) ->
          start_http2(connection, state.handler, http2_config, remaining)
        NotHttp2(buffer:) ->
          http1.State(..state, buffer:, idle_timer: option.None)
          |> http1.handle_message(connection)
          |> from_http1
      }
    }
    Http1(state), glisten.Packet(data) ->
      http1.State(..state, buffer: connection.append_buffer(state.buffer, data))
      |> http1.handle_message(connection)
      |> from_http1
    Http2(state), message ->
      http2.handle_message(state, message, connection)
      |> from_http2
    Initialised(..), glisten.User(connection.Timeout)
    | Http1(..), glisten.User(connection.Timeout)
    -> {
      logging.log(logging.Debug, "Connection idled for too long, closing.")
      glisten.stop()
    }
    Initialised(..), glisten.User(_message)
    | Http1(..), glisten.User(_message)
    -> glisten.continue(state)
  }
}

/// Takes the connection over for HTTP/2. The client's already waiting on our
/// SETTINGS by now, so that goes out first.
fn start_http2(
  connection: glisten.Connection(connection.Message),
  handler: fn(request.Request(connection.Connection)) ->
    response.Response(connection.Body),
  config: http2_connection.Config,
  remaining: BitArray,
) -> glisten.Next(State, glisten.Message(connection.Message)) {
  process.trap_exits(True)

  let self = process.new_subject()
  let replies = process.new_subject()

  let peer = transport.peername(connection.transport, connection.socket)

  let state = http2.init(handler, config, self, replies, peer)

  let selector =
    process.new_selector()
    |> process.select_map(self, glisten.User)
    |> process.select_map(replies, fn(reply) {
      glisten.User(connection.Http2Stream(reply))
    })
    |> process.select_trapped_exits(fn(exit) {
      glisten.User(connection.Http2Exit(exit))
    })

  case glisten.send(connection, state.settings_frame) {
    Error(_reason) -> glisten.stop()
    Ok(Nil) ->
      http2.handle_message(state, glisten.Packet(remaining), connection)
      |> from_http2
      |> glisten.with_selector(selector)
      |> glisten.set_active_state(options.Count(http2.socket_active_batch_size))
  }
}

fn from_http1(
  next: http1.Next,
) -> glisten.Next(State, glisten.Message(connection.Message)) {
  case next {
    http1.Continue(state) -> glisten.continue(Http1(state))
    http1.Close -> glisten.stop()
    http1.CloseAbnormal(reason:) -> glisten.stop_abnormal(reason)
  }
}

fn from_http2(
  next: http2.Next,
) -> glisten.Next(State, glisten.Message(connection.Message)) {
  case next {
    http2.Continue(state) -> glisten.continue(Http2(state))
    http2.Close -> glisten.stop()
    http2.CloseAbnormal(reason:) -> glisten.stop_abnormal(reason)
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
