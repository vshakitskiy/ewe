import alpacki
import ewe/internal/http as http_
import ewe/internal/http2/frame
import ewe/internal/http2/message.{type ConnectionMessage, type StreamMessage}
import ewe/internal/http2/stream
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/string_tree
import glisten
import glisten/socket
import glisten/socket/options.{ActiveMode, Count}
import glisten/transport
import logging

const socket_active_count = 100

pub type Settings {
  Settings(
    header_table_size: Int,
    enable_push: Bool,
    max_concurrent_streams: option.Option(Int),
    initial_window_size: Int,
    max_frame_size: Int,
    max_header_list_size: option.Option(Int),
  )
}

const default_settings = Settings(
  header_table_size: 4096,
  enable_push: True,
  max_concurrent_streams: option.None,
  initial_window_size: 65_535,
  max_frame_size: 16_384,
  max_header_list_size: option.None,
)

fn server_settings() -> Settings {
  Settings(
    header_table_size: 4096,
    enable_push: False,
    max_concurrent_streams: option.Some(128),
    initial_window_size: 65_535,
    max_frame_size: 16_384,
    max_header_list_size: option.Some(8192),
  )
}

fn decode_settings(settings: List(frame.Setting)) -> Settings {
  list.fold(settings, default_settings, fn(acc, setting) {
    case setting {
      frame.HeaderTableSize(value) -> Settings(..acc, header_table_size: value)
      frame.EnablePush(value) -> Settings(..acc, enable_push: value == 1)
      frame.MaxConcurrentStreams(value) ->
        Settings(..acc, max_concurrent_streams: option.Some(value))
      frame.InitialWindowSize(value) ->
        Settings(..acc, initial_window_size: value)
      frame.MaxFrameSize(value) -> Settings(..acc, max_frame_size: value)
      frame.MaxHeaderListSize(value) ->
        Settings(..acc, max_header_list_size: option.Some(value))
    }
  })
}

fn encode_settings(settings: Settings) -> bytes_tree.BytesTree {
  let payload = case
    settings.header_table_size != default_settings.header_table_size
  {
    True -> [frame.HeaderTableSize(settings.header_table_size)]
    False -> []
  }

  let payload = case
    settings.initial_window_size != default_settings.initial_window_size
  {
    True -> [frame.InitialWindowSize(settings.initial_window_size), ..payload]
    False -> payload
  }

  let payload = case
    settings.max_frame_size != default_settings.max_frame_size
  {
    True -> [frame.MaxFrameSize(settings.max_frame_size), ..payload]
    False -> payload
  }

  let payload = case settings.enable_push {
    True -> payload
    False -> [frame.EnablePush(0), ..payload]
  }

  let payload = case settings.max_concurrent_streams {
    option.Some(value) -> [frame.MaxConcurrentStreams(value), ..payload]
    option.None -> payload
  }

  let payload = case settings.max_header_list_size {
    option.Some(value) -> [frame.MaxHeaderListSize(value), ..payload]
    option.None -> payload
  }

  frame.Settings(payload)
  |> frame.encode
}

pub fn handle_http_upgrade(
  transport: transport.Transport,
  socket: socket.Socket,
  _request: request.Request(http_.Http),
  _settings: String,
) {
  let _ =
    transport.send(
      transport,
      socket,
      bytes_tree.from_bit_array(<<
        "HTTP/1.1 101 Switching Protocols\r\n",
        "Connection: Upgrade\r\n",
        "Upgrade: h2c\r\n\r\n",
      >>),
    )

  // TODO: handle upgrade
  glisten.stop()
}

type State {
  State(
    transport: transport.Transport,
    socket: socket.Socket,
    self: process.Subject(Message),
    connection_recv_window: Int,
    connection_send_window: Int,
    connection_subject: process.Subject(ConnectionMessage),
    mode: Mode,
    buffer: BitArray,
    local_settings: Settings,
    remote_settings: Settings,
    settings_timeout: option.Option(process.Timer),
    hpack_decoder: alpacki.DynamicTable,
    hpack_encoder: alpacki.DynamicTable,
    pending: bytes_tree.BytesTree,
    factory: factory.Supervisor(
      fn() ->
        Result(actor.Started(process.Subject(StreamMessage)), actor.StartError),
      process.Subject(StreamMessage),
    ),
    streams: dict.Dict(Int, Stream),
    last_stream_id: Int,
    handler: fn(request.Request(http_.Connection)) ->
      response.Response(http_.ResponseBody),
  )
}

type Stream {
  Stream(
    id: Int,
    pid: process.Pid,
    subject: process.Subject(StreamMessage),
    send_window: Int,
    pending: option.Option(BitArray),
  )
}

fn append_pending(state: State, pending: frame.Frame) -> State {
  let pending =
    frame.encode(pending)
    |> bytes_tree.append_tree(state.pending, _)

  State(..state, pending:)
}

fn flush_pending(state: State) -> Result(State, Nil) {
  case transport.send(state.transport, state.socket, state.pending) {
    Ok(Nil) -> Ok(State(..state, pending: bytes_tree.new()))
    Error(_) -> Error(Nil)
  }
}

fn append_goaway(state: State, code: frame.ErrorCode, debug: String) -> State {
  <<debug:utf8>>
  |> frame.GoAway(last_stream_id: state.last_stream_id, code:)
  |> append_pending(state, _)
}

fn append_rst_stream(
  state: State,
  stream_id: Int,
  code: frame.ErrorCode,
) -> State {
  frame.RstStream(stream_id, code)
  |> append_pending(state, _)
}

type Mode {
  Init
  Open
  Continuation(stream_id: Int, fragments: BitArray, end_stream: Bool)
  Closed
}

type Message {
  Close
  Passive
  Packet(BitArray)
  SettingsTimeout
  FromStream(ConnectionMessage)
  StreamDown(process.Down)
}

pub type Upgrade {
  Upgrade(req: request.Request(http_.Connection), settings: Settings)
}

pub fn start(
  transport: transport.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  upgrade: option.Option(Upgrade),
  handler: fn(request.Request(http_.Connection)) ->
    response.Response(http_.ResponseBody),
) -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(10_000, fn(self) {
    let _ = transport.controlling_process(transport, socket, process.self())
    let _ =
      transport.set_opts(transport, socket, [
        ActiveMode(Count(socket_active_count)),
      ])

    let local_settings = server_settings()
    let remote_settings =
      option.map(upgrade, fn(upgrade) { upgrade.settings })
      |> option.unwrap(default_settings)

    let connection_subject = process.new_subject()
    let selector =
      create_socket_selector(self)
      |> process.select_map(for: connection_subject, mapping: FromStream)

    let started =
      factory.worker_child(fn(fun) { fun() })
      |> factory.restart_strategy(supervision.Temporary)
      |> factory.start

    case started {
      Ok(actor.Started(data: factory, ..)) -> {
        let processed =
          State(
            transport:,
            socket:,
            self:,
            connection_recv_window: local_settings.initial_window_size,
            connection_send_window: remote_settings.initial_window_size,
            connection_subject:,
            mode: Init,
            buffer:,
            local_settings:,
            remote_settings:,
            settings_timeout: process.send_after(self, 10_000, SettingsTimeout)
              |> option.Some,
            hpack_decoder: alpacki.new_dynamic(local_settings.header_table_size),
            hpack_encoder: alpacki.new_dynamic(
              remote_settings.header_table_size,
            ),
            pending: bytes_tree.new()
              |> bytes_tree.append_tree(encode_settings(local_settings)),
            factory:,
            streams: dict.new(),
            last_stream_id: 0,
            handler:,
          )
          |> process_buffer

        case processed {
          Ok(state) -> {
            case flush_pending(state) {
              Ok(state) ->
                actor.initialised(state)
                |> actor.selecting(selector)
                |> actor.returning(Nil)
                |> Ok
              Error(Nil) -> Error("Failed to start HTTP/2 connection")
            }
          }

          Error(state) -> {
            let _ = flush_pending(state)
            Error("Failed to start HTTP/2 connection")
          }
        }
      }
      Error(_) -> Error("Failed to start HTTP/2 streams factory")
    }
  })
  |> actor.on_message(handle_message)
  |> actor.start()
}

fn create_socket_selector(
  self: process.Subject(Message),
) -> process.Selector(Message) {
  process.new_selector()
  |> process.select(self)
  |> process.select_record(atom.create("tcp"), 2, fn(record) {
    Packet(coerce_tcp_message(record))
  })
  |> process.select_record(atom.create("ssl"), 2, fn(record) {
    Packet(coerce_tcp_message(record))
  })
  |> process.select_record(atom.create("tcp_closed"), 1, fn(_) { Close })
  |> process.select_record(atom.create("ssl_closed"), 1, fn(_) { Close })
  |> process.select_record(atom.create("tcp_passive"), 1, fn(_) { Passive })
  |> process.select_record(atom.create("ssl_passive"), 1, fn(_) { Passive })
  |> process.select_monitors(StreamDown)
}

@external(erlang, "ewe_ffi", "coerce_tcp_message")
fn coerce_tcp_message(record: dynamic.Dynamic) -> BitArray

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Close -> actor.stop()
    Passive -> {
      let _ =
        transport.set_opts(state.transport, state.socket, [
          ActiveMode(Count(socket_active_count)),
        ])

      actor.continue(state)
    }
    Packet(data) -> {
      let processed =
        process_buffer(State(..state, buffer: <<state.buffer:bits, data:bits>>))
      case processed {
        Ok(state) -> {
          case flush_pending(state) {
            Ok(state) -> actor.continue(state)
            Error(Nil) -> actor.stop()
          }
        }
        Error(state) -> {
          let _ = flush_pending(state)
          actor.stop()
        }
      }
    }
    SettingsTimeout -> {
      echo "silly timeout"
      actor.stop()
    }
    FromStream(message) -> handle_stream_message(state, message)
    StreamDown(down) -> {
      case down {
        process.ProcessDown(pid:, ..) -> {
          let streams =
            dict.filter(state.streams, fn(_id, stream) {
              stream.pid != pid || stream.pending != option.None
            })
          actor.continue(State(..state, streams:))
        }
        process.PortDown(..) -> actor.continue(state)
      }
    }
  }
}

fn handle_stream_message(
  state: State,
  message: ConnectionMessage,
) -> actor.Next(State, Message) {
  case message {
    message.WindowUpdate(stream_id:, increment:) -> {
      let state =
        frame.WindowUpdate(stream_id:, increment:)
        |> append_pending(state, _)

      case flush_pending(state) {
        Ok(state) -> actor.continue(state)
        Error(Nil) -> actor.stop()
      }
    }

    message.SendResponse(stream_id:, response:) -> {
      let state = send_response(state, stream_id, response)
      case flush_pending(state) {
        Ok(state) -> actor.continue(state)
        Error(Nil) -> actor.stop()
      }
    }
  }
}

fn process_buffer(state: State) -> Result(State, State) {
  case frame.decode(state.buffer) {
    Ok(#(frame, remaining)) ->
      case process_frame(State(..state, buffer: remaining), frame) {
        Ok(state) -> process_buffer(state)
        error -> error
      }
    Error(frame.Incomplete) -> Ok(state)

    Error(frame.ProtocolViolation(frame.FrameOnControlStream)) -> todo
    Error(frame.ProtocolViolation(frame.StreamDependingOnItself)) -> todo
    Error(frame.ProtocolViolation(frame.FrameOnWrongStream)) -> todo
    Error(frame.ProtocolViolation(frame.InvalidSettingValue)) -> todo
    Error(frame.ProtocolViolation(frame.InitialWindowSizeOverflow)) -> todo
    Error(frame.ProtocolViolation(frame.InvalidWindowUpdateValue)) -> todo

    Error(frame.InvalidPayload(frame.ExceedingPadding)) -> todo
    Error(frame.InvalidPayload(frame.TooShort)) -> todo
    Error(frame.InvalidPayload(frame.BadSize)) -> todo
    Error(frame.InvalidPayload(frame.AckWithPayload)) -> todo
  }
}

fn process_frame(state: State, frame: frame.Frame) -> Result(State, State) {
  case state.mode {
    Init -> process_init(state, frame)
    Open -> process_open(state, frame)
    Continuation(stream_id, fragments, end_stream) ->
      process_continuation(state, frame, stream_id, fragments, end_stream)
    Closed -> Ok(state)
  }
}

fn process_init(state: State, frame: frame.Frame) -> Result(State, State) {
  case frame {
    frame.Settings(settings) -> {
      let remote_settings = decode_settings(settings)
      State(
        ..state,
        remote_settings:,
        hpack_encoder: alpacki.resize_dynamic(
          state.hpack_encoder,
          remote_settings.header_table_size,
        ),
        mode: Open,
        pending: bytes_tree.append_tree(
          state.pending,
          frame.encode(frame.SettingsAck),
        ),
      )
      |> Ok
    }

    _ -> todo
  }
}

fn process_open(state: State, frame: frame.Frame) -> Result(State, State) {
  case frame {
    frame.Settings(settings) -> {
      let remote_settings = decode_settings(settings)
      let pending =
        bytes_tree.append_tree(state.pending, frame.encode(frame.SettingsAck))
      let hpack_encoder =
        alpacki.resize_dynamic(
          state.hpack_encoder,
          remote_settings.header_table_size,
        )

      Ok(State(..state, remote_settings:, pending:, hpack_encoder:))
    }

    frame.SettingsAck -> {
      option.map(state.settings_timeout, process.cancel_timer)
      Ok(State(..state, settings_timeout: option.None))
    }

    frame.Ping(ack: False, data:) ->
      frame.Ping(ack: True, data:)
      |> append_pending(state, _)
      |> Ok

    frame.Headers(stream_id:, end_headers:, end_stream:, field_block:) ->
      process_headers(state, stream_id, end_headers, end_stream, field_block)

    frame.Data(stream_id:, end_stream:, data:) ->
      process_data(state, stream_id, end_stream, data)

    frame.WindowUpdate(stream_id: 0, increment:) -> {
      let connection_send_window = state.connection_send_window + increment
      let state = flush_all_pending(State(..state, connection_send_window:))
      Ok(state)
    }
    frame.WindowUpdate(stream_id:, increment:) -> {
      case dict.get(state.streams, stream_id) {
        Error(Nil) -> Ok(state)
        Ok(stream) -> {
          let stream =
            Stream(..stream, send_window: stream.send_window + increment)
          let streams = dict.insert(state.streams, stream_id, stream)
          let state = flush_stream_pending(State(..state, streams:), stream_id)
          Ok(state)
        }
      }
    }

    frame.RstStream(stream_id:, code:) -> {
      case dict.get(state.streams, stream_id) {
        Ok(stream) -> {
          process.send(stream.subject, message.Reset(code))
          let streams = dict.delete(state.streams, stream_id)
          Ok(State(..state, streams:))
        }
        Error(Nil) -> Ok(state)
      }
    }

    frame.GoAway(last_stream_id:, code:, debug:) -> {
      let _ =
        bit_array.to_string(debug)
        |> result.map(fn(debug) {
          logging.log(logging.Debug, "Received goaway: " <> debug)
        })

      Ok(State(..state, mode: Closed))
    }

    frame.PushPromise(..) ->
      Error(append_goaway(state, frame.ProtocolError, "Received push promise"))

    frame.Ping(ack: True, ..) | frame.Priority(..) | frame.Unknown -> Ok(state)

    frame.Continuation(..) ->
      append_goaway(state, frame.ProtocolError, "Unexpected continuation frame")
      |> Error
  }
}

fn process_headers(
  state: State,
  stream_id: Int,
  end_headers: Bool,
  end_stream: Bool,
  field_block: BitArray,
) -> Result(State, State) {
  case end_headers {
    True -> open_stream(state, stream_id, field_block, end_stream)
    False -> {
      let mode = Continuation(stream_id:, fragments: field_block, end_stream:)
      Ok(State(..state, mode:))
    }
  }
}

fn process_continuation(
  state: State,
  frame: frame.Frame,
  expected_id: Int,
  fragments: BitArray,
  end_stream: Bool,
) -> Result(State, State) {
  case frame {
    frame.Continuation(stream_id:, end_headers:, field_block:)
      if stream_id == expected_id
    -> {
      let fragments = <<fragments:bits, field_block:bits>>
      case end_headers {
        True -> open_stream(state, stream_id, fragments, end_stream)
        False ->
          State(
            ..state,
            mode: Continuation(stream_id:, fragments:, end_stream:),
          )
          |> Ok
      }
    }
    frame.Continuation(..) -> todo
    _ ->
      "received non-continuation frame while reading for field fragments"
      |> append_goaway(state, frame.ProtocolError, _)
      |> Error
  }
}

fn process_data(
  state: State,
  stream_id: Int,
  end_stream: Bool,
  data: BitArray,
) -> Result(State, State) {
  let connection_recv_window =
    state.connection_recv_window - bit_array.byte_size(data)

  case connection_recv_window < 0 {
    True ->
      append_goaway(state, frame.FlowControlError, "Flow control was violated")
      |> Error
    False -> {
      let state = case dict.get(state.streams, stream_id) {
        Ok(stream) -> {
          process.send(stream.subject, message.Data(data, end_stream))
          state
        }
        Error(Nil) -> append_rst_stream(state, stream_id, frame.StreamClosed)
      }

      let threshold =
        connection_recv_window < state.local_settings.initial_window_size / 2
      case threshold {
        True -> {
          let state =
            state.local_settings.initial_window_size - connection_recv_window
            |> frame.WindowUpdate(stream_id: 0)
            |> append_pending(state, _)

          let connection_recv_window = state.local_settings.initial_window_size

          Ok(State(..state, connection_recv_window:))
        }

        False -> Ok(State(..state, connection_recv_window:))
      }
    }
  }
}

fn open_stream(
  state: State,
  stream_id: Int,
  field_block: BitArray,
  end_stream: Bool,
) -> Result(State, State) {
  case alpacki.decode_header_block(field_block, state.hpack_decoder) {
    Ok(#(headers, hpack_decoder)) -> {
      let state = State(..state, hpack_decoder:, last_stream_id: stream_id)

      case build_request(headers) {
        Ok(request) -> {
          let started =
            factory.start_child(state.factory, fn() {
              stream.start(
                stream_id,
                request,
                state.handler,
                end_stream,
                state.connection_subject,
                state.local_settings.initial_window_size,
              )
            })

          case started {
            Ok(actor.Started(pid:, data: subject)) -> {
              process.monitor(pid)
              let stream =
                Stream(
                  id: stream_id,
                  pid:,
                  subject:,
                  send_window: state.remote_settings.initial_window_size,
                  pending: option.None,
                )
              let streams = dict.insert(state.streams, stream_id, stream)
              Ok(State(..state, streams:))
            }
            Error(err) -> {
              logging.log(
                logging.Warning,
                "failed to start stream "
                  <> int.to_string(stream_id)
                  <> ": "
                  <> string.inspect(err),
              )

              frame.RstStream(stream_id:, code: frame.InternalError)
              |> append_pending(state, _)
              |> Ok
            }
          }
        }
        Error(err) -> {
          logging.log(
            logging.Warning,
            "malformed request on stream "
              <> int.to_string(stream_id)
              <> ": "
              <> string.inspect(err),
          )
          frame.RstStream(stream_id:, code: frame.ProtocolError)
          |> append_pending(state, _)
          |> Ok
        }
      }
    }
    Error(err) -> {
      logging.log(
        logging.Warning,
        "HPACK decompression error: " <> string.inspect(err),
      )
      "HPACK decompression failure"
      |> append_goaway(state, frame.CompressionError, _)
      |> Error
    }
  }
}

type RequestError {
  DuplicatePseudoHeader(String)
  PseudoHeaderAfterRegular(String)
  MissingPseudoHeader(String)
  InvalidMethod(String)
  InvalidScheme(String)
  InvalidEncoding
}

type RequestBuilder {
  RequestBuilder(
    method: option.Option(http.Method),
    path: option.Option(String),
    query: option.Option(String),
    scheme: option.Option(http.Scheme),
    host: String,
    port: option.Option(Int),
    headers: List(#(String, String)),
    cookie: option.Option(String),
    seen_regular: Bool,
  )
}

fn build_request(
  headers: List(alpacki.HeaderField),
) -> Result(request.Request(Nil), RequestError) {
  let builder =
    RequestBuilder(
      method: option.None,
      path: option.None,
      query: option.None,
      scheme: option.None,
      host: "",
      port: option.None,
      headers: [],
      cookie: option.None,
      seen_regular: False,
    )

  use builder <- result.try(list.try_fold(headers, builder, parse_header_field))

  use method <- result.try(case builder.method {
    option.Some(method) -> Ok(method)
    option.None -> Error(MissingPseudoHeader(":method"))
  })
  use path <- result.try(case builder.path {
    option.Some(path) -> Ok(path)
    option.None -> Error(MissingPseudoHeader(":path"))
  })
  use scheme <- result.try(case builder.scheme {
    option.Some(scheme) -> Ok(scheme)
    option.None -> Error(MissingPseudoHeader(":scheme"))
  })

  let headers = list.reverse(builder.headers)
  let headers = case builder.cookie {
    option.Some(cookie) -> [#("cookie", cookie), ..headers]
    option.None -> headers
  }

  Ok(request.Request(
    method:,
    path:,
    query: builder.query,
    scheme:,
    host: builder.host,
    port: builder.port,
    headers:,
    body: Nil,
  ))
}

fn parse_header_field(
  builder: RequestBuilder,
  field: alpacki.HeaderField,
) -> Result(RequestBuilder, RequestError) {
  case validate_field_name(field.name), validate_field_value(field.value) {
    Error(Nil), _ | _, Error(Nil) -> Error(InvalidEncoding)
    Ok(":" <> name), Ok(_value) if builder.seen_regular ->
      Error(PseudoHeaderAfterRegular(name))

    Ok(":method"), Ok(value) -> {
      use <- require_no_duplicate(builder.method, "method")
      case http.parse_method(value) {
        Ok(method) -> Ok(RequestBuilder(..builder, method: option.Some(method)))
        Error(Nil) -> Error(InvalidMethod(value))
      }
    }

    Ok(":path"), Ok(value) -> {
      use <- require_no_duplicate(builder.path, "path")
      case string.split_once(value, "?") {
        Ok(#(path, query)) ->
          RequestBuilder(
            ..builder,
            path: option.Some(path),
            query: option.Some(query),
          )
          |> Ok

        Error(Nil) -> Ok(RequestBuilder(..builder, path: option.Some(value)))
      }
    }

    Ok(":scheme"), Ok(value) -> {
      use <- require_no_duplicate(builder.scheme, "scheme")
      case http.scheme_from_string(value) {
        Ok(scheme) -> Ok(RequestBuilder(..builder, scheme: option.Some(scheme)))
        Error(Nil) -> Error(InvalidScheme(value))
      }
    }

    Ok(":authority"), Ok(value) -> {
      use <- require_no_duplicate(string.to_option(builder.host), "authority")
      let #(host, port) = parse_authority(value)
      Ok(RequestBuilder(..builder, host:, port:))
    }

    Ok("cookie"), Ok(value) -> {
      let cookie = case builder.cookie {
        option.Some(existing) -> option.Some(existing <> "; " <> value)
        option.None -> option.Some(value)
      }
      Ok(RequestBuilder(..builder, cookie:, seen_regular: True))
    }

    Ok(name), Ok(value) ->
      RequestBuilder(
        ..builder,
        headers: [#(name, value), ..builder.headers],
        seen_regular: True,
      )
      |> Ok
  }
}

@external(erlang, "ewe_ffi", "h2_validate_field_name")
fn validate_field_name(name: BitArray) -> Result(String, Nil)

@external(erlang, "ewe_ffi", "validate_field_value")
fn validate_field_value(value: BitArray) -> Result(String, Nil)

fn require_no_duplicate(
  existing: option.Option(a),
  name: String,
  next: fn() -> Result(RequestBuilder, RequestError),
) -> Result(RequestBuilder, RequestError) {
  case existing {
    option.Some(_) -> Error(DuplicatePseudoHeader(name))
    option.None -> next()
  }
}

fn parse_authority(authority: String) -> #(String, option.Option(Int)) {
  case string.starts_with(authority, "[") {
    True ->
      case string.split_once(authority, "]:") {
        Ok(#(host, port)) ->
          case int.parse(port) {
            Ok(port) -> #(host <> "]", option.Some(port))
            Error(Nil) -> #(authority, option.None)
          }
        Error(Nil) -> #(authority, option.None)
      }
    False ->
      case string.split_once(authority, ":") {
        Ok(#(host, port)) ->
          case int.parse(port) {
            Ok(port) -> #(host, option.Some(port))
            Error(Nil) -> #(authority, option.None)
          }
        Error(Nil) -> #(authority, option.None)
      }
  }
}

fn send_response(
  state: State,
  stream_id: Int,
  response: response.Response(http_.ResponseBody),
) -> State {
  let body = case response.body {
    http_.TextData(s) -> option.Some(<<s:utf8>>)
    http_.BytesData(tree) -> option.Some(bytes_tree.to_bit_array(tree))
    http_.BitsData(bits) -> option.Some(bits)
    http_.StringTreeData(tree) ->
      option.Some(<<string_tree.to_string(tree):utf8>>)
    http_.Empty -> option.Some(<<>>)
    http_.File(..) | http_.Chunked | http_.Websocket | http_.SSE -> option.None
  }

  case body {
    option.None -> {
      let streams = dict.delete(state.streams, stream_id)
      frame.RstStream(stream_id:, code: frame.InternalError)
      |> append_pending(State(..state, streams:), _)
    }
    option.Some(body) -> {
      let body_size = bit_array.byte_size(body)
      let has_body = body_size > 0

      let response = case
        has_body,
        response.get_header(response, "content-length")
      {
        True, Error(Nil) ->
          response.set_header(
            response,
            "content-length",
            int.to_string(body_size),
          )
        _, _ -> response
      }

      let state = append_response_headers(state, stream_id, response, !has_body)
      case has_body {
        False -> {
          let streams = dict.delete(state.streams, stream_id)
          State(..state, streams:)
        }
        True -> append_response_body(state, stream_id, body)
      }
    }
  }
}

fn append_response_headers(
  state: State,
  stream_id: Int,
  response: response.Response(http_.ResponseBody),
  end_stream: Bool,
) -> State {
  let status_field =
    alpacki.HeaderField(
      name: <<":status":utf8>>,
      value: <<int.to_string(response.status):utf8>>,
      indexing: alpacki.WithIndexing,
    )

  let header_fields =
    list.fold(response.headers, [status_field], fn(acc, pair) {
      let #(name, value) = pair
      case is_forbidden_response_header(name) {
        True -> acc
        False -> {
          let indexing = case is_sensitive_response_header(name) {
            True -> alpacki.NeverIndexed
            False -> alpacki.WithIndexing
          }

          [
            alpacki.HeaderField(
              // TODO: remove string lowercase here!!!
              name: <<string.lowercase(name):utf8>>,
              value: <<value:utf8>>,
              indexing:,
            ),
            ..acc
          ]
        }
      }
    })
    |> list.reverse

  let #(field_block, hpack_encoder) =
    alpacki.encode_header_block(
      header_fields,
      state.hpack_encoder,
      huffman: True,
    )

  let state = State(..state, hpack_encoder:)
  let max_size = state.remote_settings.max_frame_size
  append_header_frames(state, stream_id, field_block, end_stream, max_size)
}

fn append_header_frames(
  state: State,
  stream_id: Int,
  field_block: BitArray,
  end_stream: Bool,
  max_size: Int,
) -> State {
  case field_block {
    <<field_block:bytes-size(max_size)>> ->
      frame.Headers(stream_id:, end_headers: True, end_stream:, field_block:)
      |> append_pending(state, _)
    <<chunk:bytes-size(max_size), remaining:bits>> -> {
      let state =
        frame.Headers(
          stream_id:,
          end_headers: False,
          end_stream:,
          field_block: chunk,
        )
        |> append_pending(state, _)

      append_continuation_frames(state, stream_id, remaining, max_size)
    }
    _ ->
      frame.Headers(stream_id:, end_headers: True, end_stream:, field_block:)
      |> append_pending(state, _)
  }
}

fn append_continuation_frames(
  state: State,
  stream_id: Int,
  field_block: BitArray,
  max_size: Int,
) -> State {
  case field_block {
    <<field_block:bytes-size(max_size)>> ->
      frame.Continuation(stream_id:, end_headers: True, field_block:)
      |> append_pending(state, _)
    <<chunk:bytes-size(max_size), remaining:bits>> -> {
      let state =
        frame.Continuation(stream_id:, end_headers: False, field_block: chunk)
        |> append_pending(state, _)
      append_continuation_frames(state, stream_id, remaining, max_size)
    }
    _ ->
      frame.Continuation(stream_id:, end_headers: True, field_block:)
      |> append_pending(state, _)
  }
}

fn append_response_body(state: State, stream_id: Int, body: BitArray) -> State {
  case dict.get(state.streams, stream_id) {
    Error(Nil) -> state
    Ok(stream) -> {
      let max_frame = state.remote_settings.max_frame_size
      let available = int.min(state.connection_send_window, stream.send_window)
      let body_size = bit_array.byte_size(body)
      let to_send_size = int.min(int.max(available, 0), body_size)

      case to_send_size {
        0 -> {
          let stream = Stream(..stream, pending: option.Some(body))
          let streams = dict.insert(state.streams, stream_id, stream)
          State(..state, streams:)
        }
        _ -> {
          let #(to_send, pending) = case body {
            <<head:bytes-size(to_send_size), remaining:bits>> -> #(
              head,
              remaining,
            )
            _ -> #(body, <<>>)
          }
          let has_pending = bit_array.byte_size(pending) > 0
          let state =
            append_data_frames(
              state,
              stream_id,
              to_send,
              max_frame,
              !has_pending,
            )
          let connection_send_window =
            state.connection_send_window - to_send_size
          let streams = case has_pending {
            False -> dict.delete(state.streams, stream_id)
            True -> {
              let send_window = stream.send_window - to_send_size
              let stream =
                Stream(..stream, send_window:, pending: option.Some(pending))
              dict.insert(state.streams, stream_id, stream)
            }
          }
          State(..state, connection_send_window:, streams:)
        }
      }
    }
  }
}

fn append_data_frames(
  state: State,
  stream_id: Int,
  data: BitArray,
  max_per_frame: Int,
  is_last: Bool,
) -> State {
  case data {
    <<data:bytes-size(max_per_frame)>> ->
      frame.Data(stream_id:, end_stream: is_last, data:)
      |> append_pending(state, _)
    <<chunk:bytes-size(max_per_frame), remaining:bits>> -> {
      let state =
        frame.Data(stream_id:, end_stream: False, data: chunk)
        |> append_pending(state, _)

      append_data_frames(state, stream_id, remaining, max_per_frame, is_last)
    }
    _ ->
      frame.Data(stream_id:, end_stream: is_last, data:)
      |> append_pending(state, _)
  }
}

fn is_forbidden_response_header(name: String) -> Bool {
  case string.lowercase(name) {
    "connection"
    | "keep-alive"
    | "proxy-connection"
    | "transfer-encoding"
    | "upgrade" -> True
    _ -> False
  }
}

fn is_sensitive_response_header(name: String) -> Bool {
  case string.lowercase(name) {
    "authorization" | "set-cookie" -> True
    _ -> False
  }
}

fn flush_stream_pending(state: State, stream_id: Int) -> State {
  case dict.get(state.streams, stream_id) {
    Error(Nil) -> state
    Ok(stream) -> {
      case stream.pending {
        option.None -> state
        option.Some(data) -> {
          let stream = Stream(..stream, pending: option.None)
          let streams = dict.insert(state.streams, stream_id, stream)
          append_response_body(State(..state, streams:), stream_id, data)
        }
      }
    }
  }
}

fn flush_all_pending(state: State) -> State {
  dict.fold(state.streams, state, fn(state, stream_id, stream) {
    case stream.pending {
      option.None -> state
      option.Some(_) -> flush_stream_pending(state, stream_id)
    }
  })
}
