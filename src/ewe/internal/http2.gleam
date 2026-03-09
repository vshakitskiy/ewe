import alpacki
import ewe/internal/http as http_
import ewe/internal/http2/frame
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
import gleam/result
import gleam/string
import glisten
import glisten/socket
import glisten/socket/options.{ActiveMode, Count}
import glisten/transport

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
    factory_name: process.Name(
      factory.Message(fn() -> Result(actor.Started(Nil), actor.StartError), Nil),
    ),
    streams: dict.Dict(Int, Stream),
  )
}

type Stream {
  Stream(id: Int, window_size: Int)
}

fn append_pending(state: State, pending: bytes_tree.BytesTree) {
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
}

pub type Upgrade {
  Upgrade(req: request.Request(http_.Connection), settings: Settings)
}

pub fn start(
  transport: transport.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  factory_name: process.Name(_),
  upgrade: option.Option(Upgrade),
) -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let local_settings = server_settings()
    let remote_settings = case upgrade {
      option.Some(upgrade) -> upgrade.settings
      option.None -> default_settings()
    }

    let self = process.new_subject()
    let settings_timeout =
      process.send_after(self, 10_000, SettingsTimeout)
      |> option.Some
    let pending =
      bytes_tree.new()
      |> bytes_tree.append_tree(encode_settings(local_settings))

    let selector = create_socket_selector()

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
        hpack_encoder: alpacki.new_dynamic(local_settings.header_table_size),
        hpack_decoder: alpacki.new_dynamic(remote_settings.header_table_size),
        pending:,
        factory_name:,
        streams: dict.new(),
      )
      |> process_buffer

    case processed {
      Ok(state) -> {
        flush_pending(state)
        |> actor.initialised
        |> actor.selecting(selector)
        |> actor.returning(subject)
        |> Ok
      }

      Error(#(state, code)) -> {
        send_goaway(state, code)
        Error("Failed to start a HTTP/2 connection")
      }
    }
  })
  |> actor.on_message(handle_message)
  |> actor.start()
  |> result.map(after_start(_, transport, socket))
}

fn create_socket_selector() -> process.Selector(Message) {
  process.new_selector()
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
  case message {
    Close -> actor.stop()
    TcpPassive -> {
      let _ =
        transport.set_opts(state.transport, state.socket, [
          ActiveMode(Count(socket_active_count)),
        ])

      actor.continue(state)
    }
    Packet(data) -> {
      case
        process_buffer(State(..state, buffer: <<state.buffer:bits, data:bits>>))
      {
        Ok(state) -> flush_pending(state) |> actor.continue
        Error(#(state, code)) -> {
          send_goaway(state, code)
          actor.stop()
        }
      }
    }
    SettingsTimeout -> todo
  }
}

fn send_goaway(state: State, code: frame.ErrorCode) -> Nil {
  let _ =
    frame.GoAway(0, code, <<>>)
    |> frame.encode
    |> bytes_tree.append_tree(state.pending, _)
    |> transport.send(state.transport, state.socket, _)
  Nil
}

fn process_buffer(state: State) -> Result(State, #(State, frame.ErrorCode)) {
  case echo frame.decode(state.buffer) {
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

fn process_frame(
  state: State,
  frame: frame.Frame,
) -> Result(State, #(State, frame.ErrorCode)) {
  case state.mode {
    Init -> process_init(state, frame)
    Open -> process_open(state, frame)
    Continuation(stream_id, fragments, end_stream) ->
      process_continuation(state, frame, stream_id, fragments, end_stream)
    Closed -> Ok(state)
  }
}

fn process_init(
  state: State,
  frame: frame.Frame,
) -> Result(State, #(State, frame.ErrorCode)) {
  case frame {
    frame.Settings(settings) -> {
      Ok(
        State(
          ..state,
          remote_settings: decode_settings(settings),
          mode: Open,
          pending: bytes_tree.append_tree(
            state.pending,
            frame.encode(frame.SettingsAck),
          ),
        ),
      )
    }

    _ -> todo
  }
}

fn process_open(
  state: State,
  frame: frame.Frame,
) -> Result(State, #(State, frame.ErrorCode)) {
  case frame {
    frame.Settings(settings) -> {
      let pending =
        bytes_tree.append_tree(state.pending, frame.encode(frame.SettingsAck))
      Ok(State(..state, remote_settings: decode_settings(settings), pending:))
    }
    frame.SettingsAck -> {
      option.map(state.settings_timeout, fn(timeout) {
        process.cancel_timer(timeout)
      })
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
) -> Result(State, #(State, frame.ErrorCode)) {
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
) -> Result(State, #(State, frame.ErrorCode)) {
  case frame {
    frame.Continuation(stream_id:, end_headers:, field_block:)
      if stream_id == expected_id
    -> {
      let fragments = <<fragments:bits, field_block:bits>>
      case end_headers {
        True -> open_stream(state, stream_id, field_block, end_stream)
        False ->
          State(
            ..state,
            mode: Continuation(stream_id:, fragments:, end_stream:),
          )
          |> Ok
      }
    }
    frame.Continuation(..) -> todo
    _ -> Error(#(state, frame.ProtocolError))
  }
}

fn open_stream(
  state: State,
  stream_id: Int,
  field_block: BitArray,
  end_stream: Bool,
) {
  case alpacki.decode_header_block(field_block, state.hpack_decoder) {
    Ok(#(headers, hpack_decoder)) -> {
      let state = State(..state, hpack_decoder:)
      echo build_request(headers)

      Ok(state)
      // case build_request(headers) {
      //   Ok(req) -> todo
      //   Error(error) -> todo as "malformed request"
      // }
    }
    Error(error) -> todo as "compression error"
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
      scheme: option.None,
      host: "",
      port: option.None,
      headers: [],
      cookie: option.None,
      seen_regular: False,
    )

  use builder <- result.try(list.try_fold(headers, builder, parse_header))

  use method <- result.try(case builder.method {
    option.Some(m) -> Ok(m)
    option.None -> Error(MissingPseudoHeader(":method"))
  })
  use path <- result.try(case builder.path {
    option.Some(p) -> Ok(p)
    option.None -> Error(MissingPseudoHeader(":path"))
  })
  use scheme <- result.try(case builder.scheme {
    option.Some(s) -> Ok(s)
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
    scheme:,
    host: builder.host,
    port: builder.port,
    headers:,
    body: "",
    query: option.None,
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
      Ok(RequestBuilder(..builder, path: option.Some(field.value)))
    }

    ":scheme" -> {
      use <- require_no_duplicate(builder.scheme, field.name)
      case http.scheme_from_string(field.value) {
        Ok(scheme) -> Ok(RequestBuilder(..builder, scheme: option.Some(scheme)))
        Error(Nil) -> Error(InvalidScheme(field.value))
      }
    }

    ":authority" -> {
      use <- require_no_duplicate(
        option.Some(builder.host) |> option.then(string.to_option),
        field.name,
      )
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
      Ok(
        RequestBuilder(
          ..builder,
          headers: [#(field.name, field.value), ..builder.headers],
          seen_regular: True,
        ),
      )
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

fn after_start(
  started: actor.Started(a),
  transport: transport.Transport,
  socket: socket.Socket,
) -> actor.Started(Nil) {
  let _ = transport.controlling_process(transport, socket, started.pid)

  let _ =
    transport.set_opts(transport, socket, [
      ActiveMode(Count(socket_active_count)),
    ])

  actor.Started(..started, data: Nil)
}
