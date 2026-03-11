import alpacki
import ewe/internal/http as http_
import ewe/internal/http2/frame
import ewe/internal/http2/message.{type ConnectionMessage, type StreamMessage}
import ewe/internal/http2/stream
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import gleam/result
import gleam/string
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

fn default_settings() -> Settings {
  Settings(
    header_table_size: 4096,
    enable_push: True,
    max_concurrent_streams: option.None,
    initial_window_size: 65_535,
    max_frame_size: 16_384,
    max_header_list_size: option.None,
  )
}

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

fn decode_settings(settings: List(#(frame.SettingId, Int))) -> Settings {
  list.fold(settings, default_settings(), fn(acc, setting) {
    case setting.0 {
      frame.HeaderTableSize -> Settings(..acc, header_table_size: setting.1)
      frame.EnablePush ->
        Settings(..acc, enable_push: case setting.1 {
          1 -> True
          _ -> False
        })
      frame.MaxConcurrentStreams ->
        Settings(..acc, max_concurrent_streams: option.Some(setting.1))
      frame.InitialWindowSize -> Settings(..acc, initial_window_size: setting.1)
      frame.MaxFrameSize -> Settings(..acc, max_frame_size: setting.1)
      frame.MaxHeaderListSize ->
        Settings(..acc, max_header_list_size: option.Some(setting.1))
    }
  })
}

fn encode_settings(settings: Settings) -> bytes_tree.BytesTree {
  let payload = [
    #(frame.HeaderTableSize, settings.header_table_size),
    #(frame.EnablePush, case settings.enable_push {
      True -> 1
      False -> 0
    }),
    #(frame.InitialWindowSize, settings.initial_window_size),
    #(frame.MaxFrameSize, settings.max_frame_size),
  ]

  let payload = case settings.max_concurrent_streams {
    option.Some(value) -> [#(frame.MaxConcurrentStreams, value), ..payload]
    option.None -> payload
  }

  let payload = case settings.max_header_list_size {
    option.Some(value) -> [#(frame.MaxHeaderListSize, value), ..payload]
    option.None -> payload
  }

  frame.Settings(payload)
  |> frame.encode
}

pub fn handle_http_upgrade(
  transport: transport.Transport,
  socket: socket.Socket,
  _request: request.Request(http_.Connection),
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
    mode: Mode,
    buffer: BitArray,
    local_settings: Settings,
    remote_settings: Settings,
    hpack_encoder: alpacki.DynamicTable,
    hpack_decoder: alpacki.DynamicTable,
    settings_acked: Bool,
    settings_timeout: option.Option(process.Timer),
    pending: bytes_tree.BytesTree,
    connection_subject: process.Subject(ConnectionMessage),
    streams: dict.Dict(Int, Stream),
    last_stream_id: Int,
    factory: factory.Supervisor(
      fn() ->
        Result(actor.Started(process.Subject(StreamMessage)), actor.StartError),
      process.Subject(StreamMessage),
    ),
  )
}

type Stream {
  Stream(id: Int, subject: process.Subject(StreamMessage))
}

fn append_pending(state: State, pending: bytes_tree.BytesTree) -> State {
  State(..state, pending: bytes_tree.append_tree(state.pending, pending))
}

fn flush_pending(state: State) -> State {
  let _ = transport.send(state.transport, state.socket, state.pending)
  State(..state, pending: bytes_tree.new())
}

type Mode {
  Init
  Open
  Continuation(stream_id: Int, fragments: BitArray, end_stream: Bool)
  Closed
}

type Message {
  Close
  TcpPassive
  Packet(BitArray)
  SettingsTimeout
  FromStream(ConnectionMessage)
}

pub type Upgrade {
  Upgrade(req: request.Request(http_.Connection), settings: Settings)
}

pub fn start(
  transport: transport.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  upgrade: option.Option(Upgrade),
) -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(1000, fn(_subject) {
    let _ = transport.controlling_process(transport, socket, process.self())
    let _ =
      transport.set_opts(transport, socket, [
        ActiveMode(Count(socket_active_count)),
      ])

    let local_settings = server_settings()
    let remote_settings = case upgrade {
      option.Some(upgrade) -> upgrade.settings
      option.None -> default_settings()
    }

    let self = process.new_subject()
    let connection_subject = process.new_subject()
    let settings_timeout =
      process.send_after(self, 10_000, SettingsTimeout)
      |> option.Some
    let pending =
      bytes_tree.new()
      |> bytes_tree.append_tree(encode_settings(local_settings))

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
            mode: Init,
            buffer:,
            local_settings:,
            remote_settings:,
            settings_acked: False,
            settings_timeout:,
            hpack_encoder: alpacki.new_dynamic(
              remote_settings.header_table_size,
            ),
            hpack_decoder: alpacki.new_dynamic(local_settings.header_table_size),
            pending:,
            connection_subject:,
            streams: dict.new(),
            last_stream_id: 0,
            factory:,
          )
          |> process_buffer

        case processed {
          Ok(state) -> {
            flush_pending(state)
            |> actor.initialised
            |> actor.selecting(selector)
            |> actor.returning(Nil)
            |> Ok
          }

          Error(state) -> {
            flush_pending(state)
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
  |> process.select_record(atom.create("tcp_passive"), 1, fn(_) { TcpPassive })
}

@external(erlang, "ewe_ffi", "coerce_tcp_message")
fn coerce_tcp_message(record: dynamic.Dynamic) -> BitArray

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case echo message {
    Close -> actor.stop()
    TcpPassive -> {
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
        Ok(state) -> flush_pending(state) |> actor.continue
        Error(state) -> {
          flush_pending(state)
          actor.stop()
        }
      }
    }
    SettingsTimeout -> {
      echo "silly timeout"
      actor.stop()
    }
    FromStream(message) -> handle_stream_message(state, message)
  }
}

fn handle_stream_message(
  state: State,
  message: ConnectionMessage,
) -> actor.Next(State, Message) {
  todo
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
      Ok(State(..state, settings_acked: True, settings_timeout: option.None))
    }

    frame.Ping(ack: False, data:) ->
      frame.Ping(ack: True, data:)
      |> frame.encode
      |> append_pending(state, _)
      |> Ok
    frame.Ping(ack: True, ..) -> Ok(state)

    frame.Headers(stream_id:, end_headers:, end_stream:, field_block:) ->
      process_headers(state, stream_id, end_headers, end_stream, field_block)

    _ -> todo
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
    False ->
      State(
        ..state,
        mode: Continuation(stream_id:, fragments: field_block, end_stream:),
      )
      |> Ok
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

fn append_goaway(state: State, code: frame.ErrorCode, debug: String) -> State {
  let pending =
    <<debug:utf8>>
    |> frame.GoAway(last_stream_id: state.last_stream_id, code:)
    |> frame.encode
    |> bytes_tree.append_tree(state.pending, _)

  State(..state, pending:)
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
                end_stream,
                state.connection_subject,
                state.local_settings.initial_window_size,
              )
            })

          case started {
            Ok(actor.Started(data: subject, ..)) -> {
              let stream = Stream(id: stream_id, subject:)
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
              |> frame.encode
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
          |> frame.encode
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
) -> Result(request.Request(String), RequestError) {
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

  use builder <- result.try(list.try_fold(headers, builder, parse_header))

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
    body: "",
  ))
}

fn parse_header(
  builder: RequestBuilder,
  field: alpacki.HeaderField,
) -> Result(RequestBuilder, RequestError) {
  case field.name {
    ":" <> _ if builder.seen_regular ->
      Error(PseudoHeaderAfterRegular(field.name))

    ":method" -> {
      use <- require_no_duplicate(builder.method, field.name)
      case http.parse_method(field.value) {
        Ok(method) -> Ok(RequestBuilder(..builder, method: option.Some(method)))
        Error(Nil) -> Error(InvalidMethod(field.value))
      }
    }

    ":path" -> {
      use <- require_no_duplicate(builder.path, field.name)
      case string.split_once(field.value, "?") {
        Ok(#(path, query)) ->
          RequestBuilder(
            ..builder,
            path: option.Some(path),
            query: option.Some(query),
          )
          |> Ok

        Error(Nil) ->
          Ok(RequestBuilder(..builder, path: option.Some(field.value)))
      }
    }

    ":scheme" -> {
      use <- require_no_duplicate(builder.scheme, field.name)
      case http.scheme_from_string(field.value) {
        Ok(scheme) -> Ok(RequestBuilder(..builder, scheme: option.Some(scheme)))
        Error(Nil) -> Error(InvalidScheme(field.value))
      }
    }

    ":authority" -> {
      use <- require_no_duplicate(string.to_option(builder.host), field.name)
      let #(host, port) = parse_authority(field.value)
      Ok(RequestBuilder(..builder, host:, port:))
    }

    "cookie" -> {
      let cookie = case builder.cookie {
        option.Some(existing) -> option.Some(existing <> "; " <> field.value)
        option.None -> option.Some(field.value)
      }
      Ok(RequestBuilder(..builder, cookie:, seen_regular: True))
    }

    _ ->
      RequestBuilder(
        ..builder,
        headers: [#(field.name, field.value), ..builder.headers],
        seen_regular: True,
      )
      |> Ok
  }
}

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
