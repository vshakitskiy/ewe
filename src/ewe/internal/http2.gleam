import alpacki
import ewe/internal/clock
import ewe/internal/connection
import ewe/internal/file
import ewe/internal/http2/connection as http2
import ewe/internal/http2/frame
import ewe/internal/http2/stream
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request, Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import glisten
import glisten/socket

@internal
pub type PeerSettings {
  PeerSettings(
    header_table_size: Int,
    initial_window_size: Int,
    max_frame_size: Int,
    max_header_list_size: Option(Int),
  )
}

const default_peer_settings = PeerSettings(
  header_table_size: 4096,
  initial_window_size: 65_535,
  max_frame_size: 16_384,
  max_header_list_size: None,
)

fn apply_settings(
  settings: PeerSettings,
  params: List(frame.Setting),
) -> PeerSettings {
  list.fold(params, settings, apply_setting)
}

fn apply_setting(
  settings: PeerSettings,
  setting: frame.Setting,
) -> PeerSettings {
  case setting {
    frame.HeaderTableSize(value) ->
      PeerSettings(..settings, header_table_size: value)
    frame.InitialWindowSize(value) ->
      PeerSettings(..settings, initial_window_size: value)
    frame.MaxFrameSize(value) -> PeerSettings(..settings, max_frame_size: value)
    frame.MaxHeaderListSize(value) ->
      PeerSettings(..settings, max_header_list_size: Some(value))
    frame.EnablePush(_enabled)
    | frame.MaxConcurrentStreams(_limit)
    | frame.UnknownSetting(_id, _value) -> settings
  }
}

pub type Next {
  Continue(State)
  Close
  CloseAbnormal(reason: String)
}

@internal
pub type HandshakePhase {
  AwaitingSettings
  Connected
}

@internal
pub type HeaderAssembly {
  HeaderAssembly(
    stream_id: Int,
    end_stream: Bool,
    fragment_count: Int,
    block: BitArray,
    trailers: Bool,
  )
}

@internal
pub type StreamStatus {
  Computing(pid: process.Pid)
  Flushing
}

@internal
pub type Pending {
  PendingBytes(BitArray)
  PendingFile(
    descriptor: connection.FileDescriptor,
    offset: Int,
    remaining: Int,
  )
}

@internal
pub type Stream {
  Stream(
    status: StreamStatus,
    send_window: Int,
    pending: Pending,
    pending_end_stream: Bool,
    write_ack: Option(process.Subject(http2.WriteAck)),
    recv_window: Int,
    recv_buffer: bytes_tree.BytesTree,
    request_half_closed: Bool,
    parked_reader: Option(process.Subject(http2.BodyEvent)),
    content_length: Option(Int),
    body_bytes_received: Int,
    trailers: List(#(String, String)),
    method: http.Method,
  )
}

type Pattern

pub opaque type HeaderPatterns {
  HeaderPatterns(
    name: Pattern,
    forbidden: Pattern,
    query: Pattern,
    colon: Pattern,
  )
}

@external(erlang, "http2_ffi", "name_pattern")
fn name_pattern() -> Pattern

@external(erlang, "http2_ffi", "forbidden_header_pattern")
fn forbidden_header_pattern() -> Pattern

@external(erlang, "http2_ffi", "query_pattern")
fn query_pattern() -> Pattern

@external(erlang, "http2_ffi", "colon_pattern")
fn colon_pattern() -> Pattern

@internal
pub fn header_patterns() -> HeaderPatterns {
  HeaderPatterns(
    name: name_pattern(),
    forbidden: forbidden_header_pattern(),
    query: query_pattern(),
    colon: colon_pattern(),
  )
}

@internal
pub type State {
  State(
    buffer: BitArray,
    handshake: HandshakePhase,
    peer_settings: PeerSettings,
    timer: Option(process.Timer),
    hpack_decoder: alpacki.DynamicTable,
    hpack_encoder: alpacki.DynamicTable,
    header_assembly: Option(HeaderAssembly),
    reply_subject: process.Subject(http2.Reply(connection.Body)),
    handler: fn(Request(connection.Connection)) -> Response(connection.Body),
    streams: Dict(Int, Stream),
    stream_pids: Dict(process.Pid, Int),
    conn_send_window: Int,
    conn_recv_window: Int,
    reset_window_start: Int,
    reset_count: Int,
    highest_client_stream_id_seen: Int,
    draining: Bool,
    drain_subject: process.Subject(connection.Message),
    drain_timer: Option(process.Timer),
    options: http2.Options,
    settings_frame: bytes_tree.BytesTree,
    patterns: HeaderPatterns,
    peer: Result(socket.SockName, Nil),
    parent: Result(process.Pid, Nil),
  )
}

const default_send_window = 65_535

const max_window_size = 2_147_483_647

pub const socket_active_batch_size = 32

fn build_settings_frame(options: http2.Options) -> bytes_tree.BytesTree {
  let params = case options.header_table_size {
    4096 -> []
    _size -> [frame.HeaderTableSize(options.header_table_size)]
  }

  let params = case options.initial_window_size {
    65_535 -> params
    _size -> [frame.InitialWindowSize(options.initial_window_size), ..params]
  }

  let params = case options.max_frame_size {
    16_384 -> params
    _size -> [frame.MaxFrameSize(options.max_frame_size), ..params]
  }

  let params = case options.max_concurrent_streams {
    Some(value) -> [frame.MaxConcurrentStreams(value), ..params]
    None -> params
  }

  let params = case options.max_header_list_size {
    Some(value) -> [frame.MaxHeaderListSize(value), ..params]
    None -> params
  }

  frame.Settings(0, False, params)
  |> frame.encode
  |> bytes_tree.from_bit_array
}

pub fn kill_live_workers(state: State) -> Nil {
  use _stream_id, entry <- dict.each(state.streams)

  case entry.status {
    Computing(pid) -> process.send_abnormal_exit(pid, "connection_closed")
    Flushing -> Nil
  }

  case entry.pending {
    PendingFile(descriptor, _offset, _remaining) -> file.close(descriptor)
    PendingBytes(_bytes) -> Nil
  }
}

pub fn init(
  handler: fn(Request(connection.Connection)) -> Response(connection.Body),
  options: http2.Options,
  self: process.Subject(connection.Message),
  reply_subject: process.Subject(http2.Reply(connection.Body)),
  peer: Result(socket.SockName, Nil),
  parent: Result(process.Pid, Nil),
) -> State {
  let table = alpacki.new_dynamic(options.header_table_size)

  let timer =
    process.send_after(
      self,
      options.handshake_timeout_ms,
      connection.Http2Handshake,
    )

  State(
    buffer: <<>>,
    handshake: AwaitingSettings,
    peer_settings: default_peer_settings,
    timer: Some(timer),
    hpack_decoder: table,
    hpack_encoder: table,
    header_assembly: None,
    reply_subject:,
    handler:,
    streams: dict.new(),
    stream_pids: dict.new(),
    conn_send_window: default_send_window,
    conn_recv_window: default_send_window,
    reset_window_start: 0,
    reset_count: 0,
    highest_client_stream_id_seen: 0,
    draining: False,
    drain_subject: self,
    drain_timer: None,
    options:,
    settings_frame: build_settings_frame(options),
    patterns: header_patterns(),
    peer:,
    parent:,
  )
}

pub fn handle_message(
  state: State,
  message: glisten.Message(connection.Message),
  connection: glisten.Connection(connection.Message),
) -> Next {
  case message {
    glisten.Packet(bytes) -> handle_packet(state, bytes, connection)
    glisten.User(connection.Http2Handshake) ->
      handle_handshake_timeout(state, connection)
    glisten.User(connection.Http2Stream(reply)) ->
      handle_stream_reply(state, reply, connection)
    glisten.User(connection.Http2Exit(exit)) ->
      handle_stream_exit(state, exit, connection)
    glisten.User(connection.Http2Drain) -> stop_connection(state)
    glisten.User(connection.Http2StreamClose(pid)) ->
      finish_or_continue(handle_stream_close_timeout(state, pid))
    glisten.User(connection.Timeout) -> Continue(state)
  }
}

fn stop_connection(state: State) -> Next {
  kill_live_workers(state)

  Close
}

fn handle_handshake_timeout(
  state: State,
  connection: glisten.Connection(connection.Message),
) -> Next {
  case state.handshake {
    AwaitingSettings ->
      terminate(state, connection, Some(frame.SettingsTimeout))
    Connected -> Continue(state)
  }
}

fn handle_packet(
  state: State,
  bytes: BitArray,
  connection: glisten.Connection(connection.Message),
) -> Next {
  State(..state, buffer: <<state.buffer:bits, bytes:bits>>)
  |> process_frames(connection)
}

fn process_frames(
  state: State,
  connection: glisten.Connection(connection.Message),
) -> Next {
  case frame.decode(state.buffer, state.options.max_frame_size) {
    Ok(#(frame, remaining)) ->
      case handle_frame(State(..state, buffer: remaining), frame, connection) {
        Proceed(state) -> process_frames(state, connection)
        ProceedWithOutbound(state, out) ->
          case glisten.send(connection, out) {
            Ok(Nil) -> process_frames(state, connection)
            Error(_reason) -> terminate(state, connection, None)
          }
        RejectStream(state, stream_id, code) ->
          reject_stream(connection, state, stream_id, code)
        Terminate(code) -> terminate(state, connection, code)
      }
    Error(frame.Incomplete) -> finish_or_continue(state)
    Error(frame.Violation(code)) -> terminate(state, connection, Some(code))
  }
}

fn reject_stream(
  connection: glisten.Connection(connection.Message),
  state: State,
  stream_id: Int,
  code: frame.ErrorCode,
) -> Next {
  let state = case dict.get(state.streams, stream_id) {
    Error(Nil) -> state
    Ok(entry) -> reset_and_remove_stream(state, stream_id, entry)
  }

  case send_frame(connection, frame.RstStream(stream_id, code)) {
    Ok(Nil) -> process_frames(state, connection)
    Error(_reason) -> terminate(state, connection, None)
  }
}

const stream_close_grace_ms = 5000

fn reset_and_remove_stream(
  state: State,
  stream_id: Int,
  entry: Stream,
) -> State {
  case entry.status {
    Computing(pid) -> {
      process.send_abnormal_exit(pid, "stream_reset")
      process.send_after(
        state.drain_subject,
        stream_close_grace_ms,
        connection.Http2StreamClose(pid),
      )

      Nil
    }
    Flushing -> Nil
  }

  case entry.pending {
    PendingFile(descriptor, _offset, _remaining) -> file.close(descriptor)
    PendingBytes(_bytes) -> Nil
  }

  State(..state, streams: dict.delete(state.streams, stream_id))
}

fn handle_stream_close_timeout(state: State, pid: process.Pid) -> State {
  case dict.get(state.stream_pids, pid) {
    Error(Nil) -> state
    Ok(_stream_id) -> {
      process.kill(pid)
      state
    }
  }
}

@internal
pub type FrameResult {
  Proceed(state: State)
  ProceedWithOutbound(state: State, out: bytes_tree.BytesTree)
  RejectStream(state: State, stream_id: Int, code: frame.ErrorCode)
  Terminate(code: Option(frame.ErrorCode))
}

fn handle_frame(
  state: State,
  frame: frame.Frame,
  connection: glisten.Connection(connection.Message),
) -> FrameResult {
  case state.header_assembly {
    Some(assembly) -> handle_continuation(state, assembly, frame)
    None -> handle_new_frame(state, frame, connection)
  }
}

fn handle_new_frame(
  state: State,
  frame: frame.Frame,
  connection: glisten.Connection(connection.Message),
) -> FrameResult {
  case frame {
    frame.Settings(0, True, _params) -> Proceed(state)
    frame.Settings(0, False, params) ->
      handle_client_settings(state, params, connection)
    frame.Settings(..) -> Terminate(Some(frame.ProtocolError))
    frame.Headers(stream_id, end_stream, end_headers, payload) ->
      handle_headers(state, stream_id, end_stream, end_headers, payload)
    frame.Data(stream_id, end_stream, payload, flow_control_size) ->
      case state.handshake {
        AwaitingSettings -> Terminate(Some(frame.ProtocolError))
        Connected ->
          handle_data(state, stream_id, end_stream, payload, flow_control_size)
      }
    frame.RstStream(stream_id, _error_code) ->
      case state.handshake {
        AwaitingSettings -> Terminate(Some(frame.ProtocolError))
        Connected -> handle_client_reset(state, stream_id)
      }
    frame.WindowUpdate(stream_id, increment) ->
      case state.handshake {
        AwaitingSettings -> Terminate(Some(frame.ProtocolError))
        Connected ->
          handle_window_update(state, stream_id, increment, connection)
      }
    frame.Ping(stream_id, ack, opaque_data) ->
      case state.handshake {
        AwaitingSettings -> Terminate(Some(frame.ProtocolError))
        Connected -> handle_ping(state, stream_id, ack, opaque_data, connection)
      }
    frame.Continuation(..) | frame.PushPromise(..) ->
      Terminate(Some(frame.ProtocolError))
    frame.Priority(..) | frame.Goaway(..) | frame.Unknown(..) ->
      case state.handshake {
        AwaitingSettings -> Terminate(Some(frame.ProtocolError))
        Connected -> Proceed(state)
      }
  }
}

fn handle_ping(
  state: State,
  stream_id: Int,
  ack: Bool,
  opaque_data: BitArray,
  connection: glisten.Connection(connection.Message),
) -> FrameResult {
  case stream_id != 0, ack {
    True, _ack -> Terminate(Some(frame.ProtocolError))
    False, True -> Proceed(state)
    False, False ->
      case send_frame(connection, frame.Ping(0, True, opaque_data)) {
        Ok(Nil) -> Proceed(state)
        Error(_reason) -> Terminate(None)
      }
  }
}

@internal
pub fn handle_client_reset(state: State, stream_id: Int) -> FrameResult {
  let #(state, tripped) = record_reset(state)

  case
    tripped,
    dict.get(state.streams, stream_id),
    stream_id > state.highest_client_stream_id_seen
  {
    True, _stream_lookup, _is_new_stream ->
      Terminate(Some(frame.EnhanceYourCalm))
    False, Error(Nil), True -> Terminate(Some(frame.ProtocolError))
    False, Error(Nil), False -> Proceed(state)
    False, Ok(entry), _is_new_stream ->
      Proceed(reset_and_remove_stream(state, stream_id, entry))
  }
}

fn record_reset(state: State) -> #(State, Bool) {
  let now = monotonic_ms()

  let new_window =
    state.reset_count == 0
    || now - state.reset_window_start > state.options.rapid_reset_window_ms

  let #(reset_window_start, reset_count) = case new_window {
    True -> #(now, 1)
    False -> #(state.reset_window_start, state.reset_count + 1)
  }

  #(
    State(..state, reset_window_start:, reset_count:),
    reset_count > state.options.rapid_reset_threshold,
  )
}

@external(erlang, "http2_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

fn remove_stream(state: State, stream_id: Int, entry: Stream) -> State {
  let stream_pids = case entry.status {
    Computing(pid) -> dict.delete(state.stream_pids, pid)
    Flushing -> state.stream_pids
  }

  State(..state, streams: dict.delete(state.streams, stream_id), stream_pids:)
}

fn clear_stream_pid(state: State, pid: process.Pid) -> State {
  State(..state, stream_pids: dict.delete(state.stream_pids, pid))
}

@internal
pub fn handle_headers(
  state: State,
  stream_id: Int,
  end_stream: Bool,
  end_headers: Bool,
  payload: BitArray,
) -> FrameResult {
  case
    dict.get(state.streams, stream_id),
    is_new_client_stream_id(state, stream_id)
  {
    Ok(entry), _is_new_stream if !entry.request_half_closed ->
      start_header_assembly(
        state,
        stream_id,
        end_stream,
        end_headers,
        payload,
        True,
      )
    Ok(_entry), _is_new_stream ->
      RejectStream(state, stream_id, frame.StreamClosed)
    Error(Nil), True -> {
      State(..state, highest_client_stream_id_seen: stream_id)
      |> start_header_assembly(
        stream_id,
        end_stream,
        end_headers,
        payload,
        False,
      )
    }
    Error(Nil), False -> Terminate(Some(frame.ProtocolError))
  }
}

fn start_header_assembly(
  state: State,
  stream_id: Int,
  end_stream: Bool,
  end_headers: Bool,
  payload: BitArray,
  trailers: Bool,
) -> FrameResult {
  let assembly =
    HeaderAssembly(
      stream_id:,
      end_stream:,
      fragment_count: 1,
      block: payload,
      trailers:,
    )

  let oversized =
    bit_array.byte_size(payload) > state.options.max_header_block_bytes

  case oversized, end_headers, trailers {
    True, _end_headers, _trailers -> Terminate(Some(frame.EnhanceYourCalm))
    False, False, _trailers ->
      Proceed(State(..state, header_assembly: Some(assembly)))
    False, True, True -> complete_trailer_block(state, assembly)
    False, True, False -> complete_header_block(state, assembly)
  }
}

fn is_new_client_stream_id(state: State, stream_id: Int) -> Bool {
  stream_id % 2 == 1 && stream_id > state.highest_client_stream_id_seen
}

@internal
pub fn handle_data(
  state: State,
  stream_id: Int,
  end_stream: Bool,
  payload: BitArray,
  size: Int,
) -> FrameResult {
  case
    stream_id == 0,
    dict.get(state.streams, stream_id),
    stream_id > state.highest_client_stream_id_seen
  {
    True, _lookup, _is_new_stream -> Terminate(Some(frame.ProtocolError))
    False, Error(Nil), True -> Terminate(Some(frame.ProtocolError))
    False, Error(Nil), False -> reject_closed_stream_data(state, size)
    False, Ok(entry), _is_new_stream if entry.request_half_closed ->
      reject_data_after_half_close(state, stream_id, size)
    False, Ok(entry), _is_new_stream ->
      apply_data(state, stream_id, entry, end_stream, payload, size)
  }
}

fn reject_closed_stream_data(state: State, size: Int) -> FrameResult {
  case state.conn_recv_window - size < 0 {
    True -> Terminate(Some(frame.FlowControlError))
    False -> Terminate(Some(frame.StreamClosed))
  }
}

fn reject_data_after_half_close(
  state: State,
  stream_id: Int,
  size: Int,
) -> FrameResult {
  let conn_recv_window = state.conn_recv_window - size

  case conn_recv_window < 0 {
    True -> Terminate(Some(frame.FlowControlError))
    False ->
      State(..state, conn_recv_window:)
      |> RejectStream(stream_id, frame.StreamClosed)
  }
}

fn apply_data(
  state: State,
  stream_id: Int,
  entry: Stream,
  end_stream: Bool,
  payload: BitArray,
  size: Int,
) -> FrameResult {
  let conn_recv_window = state.conn_recv_window - size
  let recv_window = entry.recv_window - size
  let state = State(..state, conn_recv_window:)

  case conn_recv_window < 0, recv_window < 0 {
    True, _recv_window_negative -> Terminate(Some(frame.FlowControlError))
    False, True -> RejectStream(state, stream_id, frame.FlowControlError)
    False, False ->
      case content_length_violation(entry, payload, end_stream) {
        True -> RejectStream(state, stream_id, frame.ProtocolError)
        False -> {
          let body_bytes_received =
            entry.body_bytes_received + bit_array.byte_size(payload)
          let #(state, conn_increment) = conn_recv_credit(state)
          let #(entry, delivered_to_reader) =
            Stream(..entry, recv_window:, body_bytes_received:)
            |> deliver_data(payload, end_stream, [])

          let #(entry, stream_increment) = case delivered_to_reader {
            True -> stream_recv_credit(entry, state.options)
            False -> #(entry, 0)
          }

          let streams = dict.insert(state.streams, stream_id, entry)
          let state = State(..state, streams:)

          let out =
            bytes_tree.new()
            |> append_window_update(stream_id, stream_increment)
            |> append_window_update(0, conn_increment)

          case stream_increment > 0 || conn_increment > 0 {
            False -> Proceed(state)
            True -> ProceedWithOutbound(state, out)
          }
        }
      }
  }
}

fn content_length_violation(
  entry: Stream,
  payload: BitArray,
  end_stream: Bool,
) -> Bool {
  case entry.content_length {
    None -> False
    Some(expected) -> {
      let total = entry.body_bytes_received + bit_array.byte_size(payload)
      total > expected || { end_stream && total != expected }
    }
  }
}

fn deliver_data(
  entry: Stream,
  payload: BitArray,
  end_stream: Bool,
  trailers: List(#(String, String)),
) -> #(Stream, Bool) {
  let request_half_closed = entry.request_half_closed || end_stream
  let entry = Stream(..entry, request_half_closed:)

  case entry.parked_reader, payload, end_stream {
    _reader, <<>>, False -> #(entry, False)
    Some(reply_to), <<>>, True -> {
      process.send(reply_to, http2.DoneEvent(trailers))
      #(Stream(..entry, parked_reader: None), True)
    }
    Some(reply_to), _payload, True -> {
      process.send(reply_to, http2.LastChunkEvent(payload, trailers))
      #(Stream(..entry, parked_reader: None), True)
    }
    Some(reply_to), _payload, False -> {
      process.send(reply_to, http2.ChunkEvent(payload))
      #(Stream(..entry, parked_reader: None), True)
    }
    None, _payload, _end_stream -> {
      let recv_buffer = bytes_tree.append(entry.recv_buffer, payload)
      let trailers = case trailers {
        [] -> entry.trailers
        _received -> trailers
      }

      #(Stream(..entry, recv_buffer:, trailers:), False)
    }
  }
}

@internal
pub fn handle_continuation(
  state: State,
  assembly: HeaderAssembly,
  frame: frame.Frame,
) -> FrameResult {
  case frame {
    frame.Continuation(stream_id, end_headers, payload)
      if stream_id == assembly.stream_id
    ->
      case add_fragment(assembly, payload, state.options), end_headers {
        Error(code), _end_headers -> Terminate(Some(code))
        Ok(updated), False ->
          Proceed(State(..state, header_assembly: Some(updated)))
        Ok(updated), True if updated.trailers ->
          complete_trailer_block(state, updated)
        Ok(updated), True -> complete_header_block(state, updated)
      }
    frame.Continuation(..) -> Terminate(Some(frame.ProtocolError))
    _frame -> Terminate(Some(frame.ProtocolError))
  }
}

@internal
pub fn add_fragment(
  assembly: HeaderAssembly,
  fragment: BitArray,
  options: http2.Options,
) -> Result(HeaderAssembly, frame.ErrorCode) {
  let fragment_count = assembly.fragment_count + 1
  let block = <<assembly.block:bits, fragment:bits>>

  case
    fragment_count > options.max_continuation_frames
    || bit_array.byte_size(block) > options.max_header_block_bytes
  {
    True -> Error(frame.EnhanceYourCalm)
    False -> Ok(HeaderAssembly(..assembly, fragment_count:, block:))
  }
}

fn decode_and_validate_header_block(
  state: State,
  assembly: HeaderAssembly,
) -> Result(#(State, List(#(BitArray, BitArray))), FrameResult) {
  case alpacki.decode_header_block(assembly.block, state.hpack_decoder) {
    Error(_decode_error) -> Error(Terminate(Some(frame.CompressionError)))
    Ok(alpacki.DecodedHeaderBlock(
      headers:,
      decoded_size:,
      dynamic_table:,
      remaining:,
    )) -> {
      let header_list_size_exceeded = case state.options.max_header_list_size {
        None -> False
        Some(limit) -> decoded_size > limit
      }

      case
        remaining != <<>>
        || alpacki.dynamic_max_size(dynamic_table)
        > state.options.header_table_size,
        header_list_size_exceeded
      {
        True, _header_list_size_exceeded ->
          Error(Terminate(Some(frame.CompressionError)))
        False, True -> Error(Terminate(Some(frame.EnhanceYourCalm)))
        False, False -> {
          let next_state =
            State(..state, header_assembly: None, hpack_decoder: dynamic_table)
          Ok(#(next_state, headers))
        }
      }
    }
  }
}

@internal
pub fn complete_header_block(
  state: State,
  assembly: HeaderAssembly,
) -> FrameResult {
  case decode_and_validate_header_block(state, assembly) {
    Error(result) -> result
    Ok(#(next_state, headers)) -> {
      let connection =
        connection.Http2(http2.Connection(
          connection: state.reply_subject,
          stream_id: assembly.stream_id,
          has_body: !assembly.end_stream,
          pending: <<>>,
          pending_trailers: None,
          read: 0,
          body_read_timeout: state.options.body_read_timeout,
          peer: state.peer,
        ))

      case build_request(headers, connection, state.patterns) {
        Error(_error) ->
          RejectStream(next_state, assembly.stream_id, frame.ProtocolError)
        Ok(#(request, content_length)) ->
          case assembly.end_stream, content_length {
            True, Some(expected) if expected != 0 ->
              RejectStream(next_state, assembly.stream_id, frame.ProtocolError)
            _end_stream, _content_length ->
              spawn_stream(
                next_state,
                assembly.stream_id,
                request,
                assembly.end_stream,
                content_length,
              )
          }
      }
    }
  }
}

fn complete_trailer_block(
  state: State,
  assembly: HeaderAssembly,
) -> FrameResult {
  case decode_and_validate_header_block(state, assembly) {
    Error(result) -> result
    Ok(#(next_state, headers)) ->
      case list.any(headers, is_pseudo_header), assembly.end_stream {
        True, _end_stream ->
          RejectStream(next_state, assembly.stream_id, frame.ProtocolError)
        False, False ->
          RejectStream(next_state, assembly.stream_id, frame.ProtocolError)
        False, True ->
          case decode_trailers(state.patterns, headers) {
            Ok(trailers) ->
              Proceed(finish_trailers(next_state, assembly.stream_id, trailers))
            Error(_error) ->
              RejectStream(next_state, assembly.stream_id, frame.ProtocolError)
          }
      }
  }
}

fn is_pseudo_header(header: #(BitArray, BitArray)) -> Bool {
  case header.0 {
    <<58, _rest:bits>> -> True
    _name -> False
  }
}

fn decode_trailers(
  patterns: HeaderPatterns,
  headers: List(#(BitArray, BitArray)),
) -> Result(List(#(String, String)), RequestError) {
  let empty =
    PseudoHeaders(method: None, scheme: None, authority: None, path: None)
    |> HeaderAccumulated(
      regular: dict.new(),
      seen_regular: False,
      content_length: None,
    )

  use acc <- result.try(
    list.try_fold(headers, empty, fn(acc, header) {
      let #(name, value) = header
      add_regular(patterns, acc, name, value)
    }),
  )

  Ok(dict.to_list(acc.regular))
}

fn finish_trailers(
  state: State,
  stream_id: Int,
  trailers: List(#(String, String)),
) -> State {
  case dict.get(state.streams, stream_id) {
    Error(Nil) -> state
    Ok(entry) -> {
      let #(entry, _delivered_to_reader) =
        deliver_data(entry, <<>>, True, trailers)

      State(..state, streams: dict.insert(state.streams, stream_id, entry))
    }
  }
}

fn spawn_stream(
  state: State,
  stream_id: Int,
  request: Request(connection.Connection),
  end_stream: Bool,
  content_length: Option(Int),
) -> FrameResult {
  let concurrent_streams_exceeded = case state.options.max_concurrent_streams {
    None -> False
    Some(limit) -> dict.size(state.streams) >= limit
  }

  case state.draining || concurrent_streams_exceeded {
    True -> RejectStream(state, stream_id, frame.RefusedStream)
    False -> {
      let pid =
        stream.start(state.reply_subject, stream_id, request, state.handler)

      track_stream(
        state,
        stream_id,
        pid,
        end_stream,
        content_length,
        request.method,
      )
      |> Proceed
    }
  }
}

fn track_stream(
  state: State,
  stream_id: Int,
  pid: process.Pid,
  end_stream: Bool,
  content_length: Option(Int),
  method: http.Method,
) -> State {
  let entry =
    Stream(
      status: Computing(pid),
      method:,
      send_window: state.peer_settings.initial_window_size,
      pending: PendingBytes(<<>>),
      pending_end_stream: True,
      write_ack: None,
      recv_window: state.options.initial_window_size,
      recv_buffer: bytes_tree.new(),
      request_half_closed: end_stream,
      parked_reader: None,
      content_length:,
      body_bytes_received: 0,
      trailers: [],
    )

  State(
    ..state,
    streams: dict.insert(state.streams, stream_id, entry),
    stream_pids: dict.insert(state.stream_pids, pid, stream_id),
  )
}

@internal
pub type RequestError {
  InvalidUtf8
  EmptyHeaderName
  UppercaseHeaderName
  MalformedHeaderBytes
  PseudoHeaderAfterRegular
  UnknownPseudoHeader
  MissingPseudoHeader
  DuplicatePseudoHeader
  ConnectionSpecificHeader
  InvalidMethod
  InvalidScheme
  InvalidAuthority
  InvalidPath
  InvalidContentLength
}

type PseudoHeaders {
  PseudoHeaders(
    method: Option(http.Method),
    scheme: Option(http.Scheme),
    authority: Option(String),
    path: Option(String),
  )
}

type HeaderAccumulated {
  HeaderAccumulated(
    pseudo: PseudoHeaders,
    regular: Dict(String, String),
    seen_regular: Bool,
    content_length: Option(Int),
  )
}

@internal
pub fn build_request(
  headers: List(#(BitArray, BitArray)),
  body: body,
  patterns: HeaderPatterns,
) -> Result(#(Request(body), Option(Int)), RequestError) {
  let pseudo =
    PseudoHeaders(method: None, scheme: None, authority: None, path: None)

  let empty =
    HeaderAccumulated(
      regular: dict.new(),
      seen_regular: False,
      content_length: None,
      pseudo:,
    )

  use acc <- result.try(
    list.try_fold(headers, empty, fn(acc, header) {
      add_header(patterns, acc, header)
    }),
  )

  case
    acc.pseudo.method,
    acc.pseudo.scheme,
    acc.pseudo.authority,
    acc.pseudo.path
  {
    Some(method), Some(scheme), Some(authority), Some(path) -> {
      use #(host, port) <- result.try(split_authority(patterns, authority))
      let #(path, query) = case split_once(path, patterns.query) {
        Ok(#(path, query)) -> #(path, Some(query))
        Error(Nil) -> #(path, None)
      }

      Ok(#(
        Request(
          method:,
          headers: dict.to_list(acc.regular),
          body:,
          scheme:,
          host:,
          port:,
          path:,
          query:,
        ),
        acc.content_length,
      ))
    }
    _method, _scheme, _authority, _path -> Error(MissingPseudoHeader)
  }
}

fn add_header(
  patterns: HeaderPatterns,
  acc: HeaderAccumulated,
  header: #(BitArray, BitArray),
) -> Result(HeaderAccumulated, RequestError) {
  let #(name, value) = header

  case name {
    <<>> -> Error(EmptyHeaderName)
    <<":method":utf8>> ->
      case acc.seen_regular, acc.pseudo.method {
        True, _method -> Error(PseudoHeaderAfterRegular)
        False, Some(_method) -> Error(DuplicatePseudoHeader)
        False, None ->
          case parse_method(patterns, value) {
            Ok(method) -> {
              let pseudo = PseudoHeaders(..acc.pseudo, method: Some(method))
              Ok(HeaderAccumulated(..acc, pseudo:))
            }
            Error(error) -> Error(error)
          }
      }
    <<":scheme":utf8>> ->
      case acc.seen_regular, acc.pseudo.scheme {
        True, _scheme -> Error(PseudoHeaderAfterRegular)
        False, Some(_scheme) -> Error(DuplicatePseudoHeader)
        False, None ->
          case parse_scheme(value) {
            Ok(scheme) -> {
              let pseudo = PseudoHeaders(..acc.pseudo, scheme: Some(scheme))
              Ok(HeaderAccumulated(..acc, pseudo:))
            }
            Error(error) -> Error(error)
          }
      }
    <<":authority":utf8>> ->
      case acc.seen_regular, acc.pseudo.authority {
        True, _authority -> Error(PseudoHeaderAfterRegular)
        False, Some(_authority) -> Error(DuplicatePseudoHeader)
        False, None ->
          case validate_header_value(patterns.forbidden, value) {
            Ok(authority) -> {
              let pseudo =
                PseudoHeaders(..acc.pseudo, authority: Some(authority))
              Ok(HeaderAccumulated(..acc, pseudo:))
            }
            Error(error) -> Error(error)
          }
      }
    <<":path":utf8>> ->
      case acc.seen_regular, acc.pseudo.path {
        True, _path -> Error(PseudoHeaderAfterRegular)
        False, Some(_path) -> Error(DuplicatePseudoHeader)
        False, None ->
          case validate_header_value(patterns.forbidden, value) {
            Ok("") -> Error(InvalidPath)
            Ok(path) -> {
              let pseudo = PseudoHeaders(..acc.pseudo, path: Some(path))
              Ok(HeaderAccumulated(..acc, pseudo:))
            }
            Error(error) -> Error(error)
          }
      }
    <<58, _rest:bits>> ->
      case acc.seen_regular {
        True -> Error(PseudoHeaderAfterRegular)
        False -> Error(UnknownPseudoHeader)
      }
    <<"connection":utf8>>
    | <<"keep-alive":utf8>>
    | <<"proxy-connection":utf8>>
    | <<"transfer-encoding":utf8>>
    | <<"upgrade":utf8>> -> Error(ConnectionSpecificHeader)
    <<"content-length":utf8>> -> {
      case acc.content_length {
        Some(_prior) -> Error(InvalidContentLength)
        None -> {
          use value <- result.try(validate_header_value(
            patterns.forbidden,
            value,
          ))

          case int.parse(value) {
            Ok(n) if n >= 0 -> {
              let regular = dict.insert(acc.regular, "content-length", value)

              HeaderAccumulated(
                ..acc,
                regular:,
                seen_regular: True,
                content_length: Some(n),
              )
              |> Ok
            }
            _value -> Error(InvalidContentLength)
          }
        }
      }
    }
    <<"te":utf8>> ->
      case value {
        <<"trailers":utf8>> -> {
          let regular = dict.insert(acc.regular, "te", "trailers")
          Ok(HeaderAccumulated(..acc, regular:))
        }
        _name -> Error(ConnectionSpecificHeader)
      }
    _name -> add_regular(patterns, acc, name, value)
  }
}

fn parse_method(
  patterns: HeaderPatterns,
  value: BitArray,
) -> Result(http.Method, RequestError) {
  case value {
    <<"GET":utf8>> -> Ok(http.Get)
    <<"POST":utf8>> -> Ok(http.Post)
    <<"PUT":utf8>> -> Ok(http.Put)
    <<"DELETE":utf8>> -> Ok(http.Delete)
    <<"HEAD":utf8>> -> Ok(http.Head)
    <<"OPTIONS":utf8>> -> Ok(http.Options)
    <<"PATCH":utf8>> -> Ok(http.Patch)
    <<"CONNECT":utf8>> -> Ok(http.Connect)
    <<"TRACE":utf8>> -> Ok(http.Trace)
    _method -> {
      use method <- result.try(validate_header_value(patterns.forbidden, value))
      http.parse_method(method) |> result.replace_error(InvalidMethod)
    }
  }
}

fn parse_scheme(value: BitArray) -> Result(http.Scheme, RequestError) {
  case value {
    <<"https":utf8>> -> Ok(http.Https)
    <<"http":utf8>> -> Ok(http.Http)
    _scheme -> Error(InvalidScheme)
  }
}

@external(erlang, "http2_ffi", "validate_header_name")
fn validate_header_name(
  pattern: Pattern,
  name: BitArray,
) -> Result(String, RequestError)

@external(erlang, "http2_ffi", "validate_header_value")
fn validate_header_value(
  pattern: Pattern,
  value: BitArray,
) -> Result(String, RequestError)

fn add_regular(
  patterns: HeaderPatterns,
  acc: HeaderAccumulated,
  name: BitArray,
  value: BitArray,
) -> Result(HeaderAccumulated, RequestError) {
  use name <- result.try(validate_header_name(patterns.name, name))
  use value <- result.try(validate_header_value(patterns.forbidden, value))

  let separator = case name {
    "cookie" -> "; "
    _existing -> ", "
  }

  let regular =
    dict_upsert(
      name,
      fn(prior) { prior <> separator <> value },
      value,
      acc.regular,
    )

  Ok(HeaderAccumulated(..acc, regular:, seen_regular: True))
}

@external(erlang, "maps", "update_with")
fn dict_upsert(
  key: String,
  with: fn(String) -> String,
  init: String,
  map: Dict(String, String),
) -> Dict(String, String)

fn split_authority(
  patterns: HeaderPatterns,
  authority: String,
) -> Result(#(String, Option(Int)), RequestError) {
  case split_once(authority, patterns.colon) {
    Ok(#(host, port_str)) ->
      case int.parse(port_str) {
        Ok(port) -> Ok(#(host, Some(port)))
        Error(Nil) -> Error(InvalidAuthority)
      }
    Error(Nil) -> Ok(#(authority, None))
  }
}

@external(erlang, "http2_ffi", "split_once")
fn split_once(
  string: String,
  on pattern: Pattern,
) -> Result(#(String, String), Nil)

fn handle_client_settings(
  state: State,
  params: List(frame.Setting),
  connection: glisten.Connection(connection.Message),
) -> FrameResult {
  case send_frame(connection, frame.settings_ack) {
    Error(_reason) -> Terminate(None)
    Ok(Nil) -> {
      let peer_settings = apply_settings(state.peer_settings, params)

      let delta =
        peer_settings.initial_window_size
        - state.peer_settings.initial_window_size

      let state = adjust_stream_windows(State(..state, peer_settings:), delta)
      let state = case state.handshake {
        AwaitingSettings -> {
          cancel_timer(state.timer)
          State(..state, handshake: Connected, timer: None)
        }
        Connected -> state
      }

      case delta > 0 {
        True -> flush_pending_streams(state, connection)
        False -> Proceed(state)
      }
    }
  }
}

@internal
pub fn adjust_stream_windows(state: State, delta: Int) -> State {
  case delta {
    0 -> state
    _delta -> {
      let streams =
        dict.map_values(state.streams, fn(_stream_id, entry) {
          Stream(..entry, send_window: entry.send_window + delta)
        })

      State(..state, streams:)
    }
  }
}

fn cancel_timer(timer: Option(process.Timer)) -> Nil {
  case timer {
    Some(timer) -> {
      let _cancelled = process.cancel_timer(timer)
      Nil
    }
    None -> Nil
  }
}

fn terminate(
  state: State,
  connection: glisten.Connection(connection.Message),
  code: Option(frame.ErrorCode),
) -> Next {
  case code {
    Some(error_code) -> {
      let _sent =
        send_frame(
          connection,
          frame.Goaway(0, state.highest_client_stream_id_seen, error_code, <<>>),
        )
      Nil
    }
    None -> Nil
  }

  stop_connection(state)
}

fn send_frame(
  connection: glisten.Connection(connection.Message),
  frame: frame.Frame,
) -> Result(Nil, glisten.SocketReason) {
  frame.encode(frame)
  |> bytes_tree.from_bit_array
  |> glisten.send(connection, _)
}

fn begin_drain(
  state: State,
  connection: glisten.Connection(connection.Message),
) -> Next {
  case state.draining {
    True -> Continue(state)
    False -> {
      let timer =
        process.send_after(
          state.drain_subject,
          state.options.drain_timeout_ms,
          connection.Http2Drain,
        )

      let state = State(..state, draining: True, drain_timer: Some(timer))
      let goaway =
        frame.Goaway(
          0,
          state.highest_client_stream_id_seen,
          frame.NoError,
          <<>>,
        )

      case send_frame(connection, goaway) {
        Ok(Nil) -> finish_or_continue(state)
        Error(_reason) -> stop_connection(state)
      }
    }
  }
}

fn finish_or_continue(state: State) -> Next {
  case state.draining && dict.size(state.streams) == 0 {
    True -> {
      cancel_timer(state.drain_timer)
      Close
    }
    False -> Continue(state)
  }
}

fn handle_stream_reply(
  state: State,
  reply: http2.Reply(connection.Body),
  connection: glisten.Connection(connection.Message),
) -> Next {
  case reply {
    http2.Respond(stream_id, response) ->
      case dict.get(state.streams, stream_id) {
        Error(Nil) -> Continue(state)
        Ok(entry) -> respond(state, stream_id, entry, response, connection)
      }
    http2.ReadBody(stream_id, reply_to) ->
      handle_read_body(state, stream_id, reply_to, connection)
    http2.WriteHeaders(stream_id, ack, status, headers, reserved) ->
      handle_write_headers(
        state,
        stream_id,
        ack,
        status,
        headers,
        reserved,
        connection,
      )
    http2.WriteData(stream_id, ack, chunk, end_stream) ->
      handle_write_data(state, stream_id, ack, chunk, end_stream, connection)
  }
}

fn handle_read_body(
  state: State,
  stream_id: Int,
  reply_to: process.Subject(http2.BodyEvent),
  connection: glisten.Connection(connection.Message),
) -> Next {
  case dict.get(state.streams, stream_id) {
    Error(Nil) -> Continue(state)
    Ok(entry) -> {
      let buffered = bytes_tree.to_bit_array(entry.recv_buffer)
      case buffered, entry.request_half_closed {
        <<>>, True -> {
          process.send(reply_to, http2.DoneEvent(entry.trailers))
          Continue(state)
        }
        <<>>, False -> {
          let entry = Stream(..entry, parked_reader: Some(reply_to))
          let streams = dict.insert(state.streams, stream_id, entry)
          Continue(State(..state, streams:))
        }
        _buffered, True -> {
          process.send(reply_to, http2.LastChunkEvent(buffered, entry.trailers))
          let drained_entry = Stream(..entry, recv_buffer: bytes_tree.new())
          let streams = dict.insert(state.streams, stream_id, drained_entry)
          Continue(State(..state, streams:))
        }
        _buffered, False -> {
          process.send(reply_to, http2.ChunkEvent(buffered))
          let drained_entry = Stream(..entry, recv_buffer: bytes_tree.new())
          let #(drained_entry, stream_increment) =
            stream_recv_credit(drained_entry, state.options)

          let streams = dict.insert(state.streams, stream_id, drained_entry)
          let state = State(..state, streams:)

          case stream_increment > 0 {
            False -> Continue(state)
            True -> {
              let out =
                bytes_tree.new()
                |> append_window_update(stream_id, stream_increment)
              case glisten.send(connection, out) {
                Ok(Nil) -> Continue(state)
                Error(_reason) -> terminate(state, connection, None)
              }
            }
          }
        }
      }
    }
  }
}

@internal
pub fn stream_recv_credit(
  entry: Stream,
  options: http2.Options,
) -> #(Stream, Int) {
  case entry.recv_window <= options.recv_window_low_water_mark {
    True -> {
      let increment = options.recv_window_high_water_mark - entry.recv_window

      #(
        Stream(..entry, recv_window: options.recv_window_high_water_mark),
        increment,
      )
    }
    False -> #(entry, 0)
  }
}

@internal
pub fn conn_recv_credit(state: State) -> #(State, Int) {
  case state.conn_recv_window <= state.options.recv_window_low_water_mark {
    True -> {
      let increment =
        state.options.recv_window_high_water_mark - state.conn_recv_window

      #(
        State(
          ..state,
          conn_recv_window: state.options.recv_window_high_water_mark,
        ),
        increment,
      )
    }
    False -> #(state, 0)
  }
}

fn append_window_update(
  acc: bytes_tree.BytesTree,
  stream_id: Int,
  increment: Int,
) -> bytes_tree.BytesTree {
  case increment > 0 {
    True ->
      frame.encode(frame.WindowUpdate(stream_id, increment))
      |> bytes_tree.append(acc, _)
    False -> acc
  }
}

fn build_response_headers(
  headers: List(#(String, String)),
  pattern: Pattern,
) -> List(alpacki.HeaderField) {
  list.fold(headers, [], fn(fields, header) {
    let #(name, value) = header
    case name {
      "connection"
      | "keep-alive"
      | "proxy-connection"
      | "transfer-encoding"
      | "upgrade"
      | "date"
      | "content-length"
      | "" -> fields
      _name ->
        case
          has_forbidden_header_bytes(pattern, name)
          || has_forbidden_header_bytes(pattern, value)
        {
          True -> fields
          False -> [
            alpacki.HeaderField(
              <<name:utf8>>,
              <<value:utf8>>,
              alpacki.WithoutIndexing,
            ),
            ..fields
          ]
        }
    }
  })
}

@external(erlang, "http2_ffi", "has_forbidden_header_bytes")
fn has_forbidden_header_bytes(pattern: Pattern, value: String) -> Bool

fn response_body_size(body: connection.Body) -> Int {
  case body {
    connection.Bytes(tree) -> bytes_tree.byte_size(tree)
    connection.Text(text) -> byte_size(text)
    connection.Empty -> 0
    connection.File(connection.OpenFile(length:, ..))
    | connection.File(connection.PendingFile(length:, ..)) -> length
    connection.Streaming(_metadata)
    | connection.Sse(_metadata)
    | connection.Websocket(_metadata) ->
      panic as "a streamed body is written by its own stream process"
  }
}

@external(erlang, "erlang", "byte_size")
fn byte_size(text: String) -> Int

fn open_pending(
  body: connection.Body,
  file_read_threshold: Int,
) -> Result(Pending, file.FileError) {
  case body {
    connection.Bytes(tree) -> Ok(PendingBytes(bytes_tree.to_bit_array(tree)))
    connection.Text(text) -> Ok(PendingBytes(bit_array.from_string(text)))
    connection.Empty -> Ok(PendingBytes(<<>>))
    connection.File(connection.OpenFile(handle:, offset:, length:)) ->
      Ok(PendingFile(handle, offset, length))
    connection.File(connection.PendingFile(path:, offset:, length:))
      if length <= file_read_threshold
    -> file.read_range(path, offset, length) |> result.map(PendingBytes)
    connection.File(connection.PendingFile(path:, offset:, length:)) ->
      file.open(path) |> result.map(PendingFile(_, offset, length))
    connection.Streaming(_metadata)
    | connection.Sse(_metadata)
    | connection.Websocket(_metadata) ->
      panic as "a streamed body is written by its own stream process"
  }
}

fn respond(
  state: State,
  stream_id: Int,
  entry: Stream,
  response: Response(connection.Body),
  connection: glisten.Connection(connection.Message),
) -> Next {
  case entry.method {
    http.Head ->
      send_response(
        state,
        stream_id,
        entry,
        response.status,
        response.headers,
        head_content_length(response.body),
        PendingBytes(<<>>),
        connection,
      )
    _method ->
      case open_pending(response.body, state.options.file_read_threshold) {
        Ok(pending) ->
          send_response(
            state,
            stream_id,
            entry,
            response.status,
            response.headers,
            Some(response_body_size(response.body)),
            pending,
            connection,
          )
        Error(_error) ->
          send_response(
            state,
            stream_id,
            entry,
            500,
            [],
            Some(0),
            PendingBytes(<<>>),
            connection,
          )
      }
  }
}

fn head_content_length(body: connection.Body) -> Option(Int) {
  case body {
    connection.Streaming(_metadata) | connection.Sse(_metadata) -> None
    connection.Bytes(_tree)
    | connection.Text(_text)
    | connection.Empty
    | connection.File(_file)
    | connection.Websocket(_metadata) -> Some(response_body_size(body))
  }
}

fn send_response(
  state: State,
  stream_id: Int,
  entry: Stream,
  status: Int,
  headers: List(#(String, String)),
  content_length: Option(Int),
  pending: Pending,
  connection: glisten.Connection(connection.Message),
) -> Next {
  let fields = build_response_headers(headers, state.patterns.forbidden)

  let content_length_fields = case status, content_length {
    status, _length if status == 204 || { status >= 100 && status < 200 } -> []
    _status, None -> []
    _status, Some(length) -> [
      alpacki.HeaderField(
        <<"content-length":utf8>>,
        <<int.to_string(length):utf8>>,
        alpacki.WithoutIndexing,
      ),
    ]
  }

  let header_fields = [
    alpacki.HeaderField(
      <<":status":utf8>>,
      <<int.to_string(status):utf8>>,
      alpacki.WithoutIndexing,
    ),
    alpacki.HeaderField(<<"date":utf8>>, clock.get(), alpacki.WithoutIndexing),
    ..list.append(content_length_fields, list.reverse(fields))
  ]

  let #(block, hpack_encoder) =
    alpacki.encode_header_block(header_fields, state.hpack_encoder, True)

  let state = State(..state, hpack_encoder:)

  let has_body = pending_has_bytes(pending)
  let out =
    bytes_tree.new()
    |> append_header_frames(
      stream_id,
      !has_body,
      block,
      state.peer_settings.max_frame_size,
    )

  case has_body {
    False -> {
      let state = State(..state, streams: dict.delete(state.streams, stream_id))
      case glisten.send(connection, out) {
        Ok(Nil) -> finish_or_continue(state)
        Error(_reason) -> terminate(state, connection, None)
      }
    }
    True -> {
      let pending_entry = Stream(..entry, status: Flushing, pending:)

      flush_stream(state, stream_id, pending_entry, out, connection)
      |> resolve_frame_result(state, connection)
    }
  }
}

fn drop_sse_headers(
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  use #(name, _value) <- list.filter(headers)
  name != "content-type" && name != "cache-control"
}

fn sse_fields() -> List(alpacki.HeaderField) {
  [
    alpacki.HeaderField(
      <<"content-type":utf8>>,
      <<"text/event-stream":utf8>>,
      alpacki.WithoutIndexing,
    ),
    alpacki.HeaderField(
      <<"cache-control":utf8>>,
      <<"no-cache":utf8>>,
      alpacki.WithoutIndexing,
    ),
  ]
}

fn handle_write_headers(
  state: State,
  stream_id: Int,
  ack: process.Subject(http2.WriteAck),
  status: Int,
  headers: List(#(String, String)),
  reserved: http2.Reserved,
  connection: glisten.Connection(connection.Message),
) -> Next {
  case dict.get(state.streams, stream_id) {
    Error(Nil) -> Continue(state)
    Ok(_entry) -> {
      let headers = case reserved {
        http2.Nothing -> headers
        http2.SseHeaders -> drop_sse_headers(headers)
      }
      let fields = build_response_headers(headers, state.patterns.forbidden)

      let reserved_fields = case reserved {
        http2.Nothing -> []
        http2.SseHeaders -> sse_fields()
      }

      let header_fields = [
        alpacki.HeaderField(
          <<":status":utf8>>,
          <<int.to_string(status):utf8>>,
          alpacki.WithoutIndexing,
        ),
        alpacki.HeaderField(
          <<"date":utf8>>,
          clock.get(),
          alpacki.WithoutIndexing,
        ),
        ..list.append(reserved_fields, list.reverse(fields))
      ]

      let #(block, hpack_encoder) =
        alpacki.encode_header_block(header_fields, state.hpack_encoder, True)

      let state = State(..state, hpack_encoder:)

      let out =
        bytes_tree.new()
        |> append_header_frames(
          stream_id,
          False,
          block,
          state.peer_settings.max_frame_size,
        )

      case glisten.send(connection, out) {
        Ok(Nil) -> {
          process.send(ack, http2.WriteAck)
          Continue(state)
        }
        Error(_reason) -> terminate(state, connection, None)
      }
    }
  }
}

fn handle_write_data(
  state: State,
  stream_id: Int,
  reply_to: process.Subject(http2.WriteAck),
  chunk: BitArray,
  end_stream: Bool,
  connection: glisten.Connection(connection.Message),
) -> Next {
  case dict.get(state.streams, stream_id) {
    Error(Nil) -> Continue(state)
    Ok(entry) -> {
      let entry =
        Stream(
          ..entry,
          pending: PendingBytes(chunk),
          pending_end_stream: end_stream,
          write_ack: Some(reply_to),
        )

      flush_stream(state, stream_id, entry, bytes_tree.new(), connection)
      |> resolve_frame_result(state, connection)
    }
  }
}

fn resolve_frame_result(
  result: FrameResult,
  state: State,
  connection: glisten.Connection(connection.Message),
) -> Next {
  case result {
    Proceed(state) -> finish_or_continue(state)
    ProceedWithOutbound(state, out) ->
      case glisten.send(connection, out) {
        Ok(Nil) -> finish_or_continue(state)
        Error(_reason) -> terminate(state, connection, None)
      }
    RejectStream(state, stream_id, code) ->
      reject_stream(connection, state, stream_id, code)
    Terminate(code) -> terminate(state, connection, code)
  }
}

@internal
pub fn append_header_frames(
  acc: bytes_tree.BytesTree,
  stream_id: Int,
  end_stream: Bool,
  block: BitArray,
  max_frame_size: Int,
) -> bytes_tree.BytesTree {
  case block {
    <<chunk:bytes-size(max_frame_size), remaining:bits>> if remaining != <<>> ->
      frame.encode(frame.Headers(stream_id, end_stream, False, chunk))
      |> bytes_tree.append(acc, _)
      |> append_continuation_frames(stream_id, remaining, max_frame_size)
    _block ->
      frame.encode(frame.Headers(stream_id, end_stream, True, block))
      |> bytes_tree.append(acc, _)
  }
}

fn append_continuation_frames(
  acc: bytes_tree.BytesTree,
  stream_id: Int,
  block: BitArray,
  max_frame_size: Int,
) -> bytes_tree.BytesTree {
  case block {
    <<chunk:bytes-size(max_frame_size), remaining:bits>> if remaining != <<>> ->
      frame.encode(frame.Continuation(stream_id, False, chunk))
      |> bytes_tree.append(acc, _)
      |> append_continuation_frames(stream_id, remaining, max_frame_size)
    _block ->
      frame.encode(frame.Continuation(stream_id, True, block))
      |> bytes_tree.append(acc, _)
  }
}

@internal
pub type FlushOutcome {
  FlushAccumulated(state: State, out: bytes_tree.BytesTree, wrote: Bool)
  FlushFileChunk(
    state: State,
    out: bytes_tree.BytesTree,
    stream_id: Int,
    entry: Stream,
    chunk_size: Int,
    end_stream: Bool,
  )
}

@internal
pub fn do_flush_stream(
  state: State,
  stream_id: Int,
  entry: Stream,
  out: bytes_tree.BytesTree,
  wrote: Bool,
) -> FlushOutcome {
  case entry.pending {
    PendingBytes(<<>>) -> {
      let out =
        frame.encode(frame.Data(stream_id, entry.pending_end_stream, <<>>, 0))
        |> bytes_tree.append(out, _)

      finish_pending(state, stream_id, entry, out, True)
    }
    PendingFile(descriptor, _offset, 0) -> {
      file.close(descriptor)

      State(..state, streams: dict.delete(state.streams, stream_id))
      |> FlushAccumulated(out, wrote)
    }
    PendingBytes(pending) -> {
      let allowed =
        int.min(state.conn_send_window, entry.send_window)
        |> int.min(state.peer_settings.max_frame_size)

      case allowed <= 0 {
        True -> {
          State(..state, streams: dict.insert(state.streams, stream_id, entry))
          |> FlushAccumulated(out, wrote)
        }
        False ->
          case pending {
            <<chunk:bytes-size(allowed), remaining:bits>> if remaining != <<>> -> {
              let out =
                frame.encode_data_header(stream_id, False, allowed)
                |> bytes_tree.append(out, _)
                |> bytes_tree.append(chunk)

              let entry =
                Stream(
                  ..entry,
                  send_window: entry.send_window - allowed,
                  pending: PendingBytes(remaining),
                )

              let state =
                State(
                  ..state,
                  conn_send_window: state.conn_send_window - allowed,
                )

              do_flush_stream(state, stream_id, entry, out, True)
            }
            _pending -> {
              let sent = bit_array.byte_size(pending)
              let out =
                frame.encode_data_header(
                  stream_id,
                  entry.pending_end_stream,
                  sent,
                )
                |> bytes_tree.append(out, _)
                |> bytes_tree.append(pending)

              let entry =
                Stream(
                  ..entry,
                  send_window: entry.send_window - sent,
                  pending: PendingBytes(<<>>),
                )

              let state =
                State(..state, conn_send_window: state.conn_send_window - sent)

              finish_pending(state, stream_id, entry, out, True)
            }
          }
      }
    }
    PendingFile(_descriptor, _offset, remaining) -> {
      let allowed =
        int.min(state.conn_send_window, entry.send_window)
        |> int.min(state.peer_settings.max_frame_size)

      case allowed <= 0 {
        True -> {
          State(..state, streams: dict.insert(state.streams, stream_id, entry))
          |> FlushAccumulated(out, wrote)
        }
        False -> {
          let chunk_size = int.min(allowed, remaining)
          let end_stream = chunk_size == remaining
          let out =
            frame.encode_data_header(stream_id, end_stream, chunk_size)
            |> bytes_tree.append(out, _)

          FlushFileChunk(state, out, stream_id, entry, chunk_size, end_stream)
        }
      }
    }
  }
}

fn finish_pending(
  state: State,
  stream_id: Int,
  entry: Stream,
  out: bytes_tree.BytesTree,
  wrote: Bool,
) -> FlushOutcome {
  case entry.write_ack {
    Some(reply_to) -> process.send(reply_to, http2.WriteAck)
    None -> Nil
  }

  case entry.pending_end_stream {
    True ->
      State(..state, streams: dict.delete(state.streams, stream_id))
      |> FlushAccumulated(out, wrote)
    False -> {
      let entry = Stream(..entry, write_ack: None)
      State(..state, streams: dict.insert(state.streams, stream_id, entry))
      |> FlushAccumulated(out, wrote)
    }
  }
}

fn send_if_any(
  connection: glisten.Connection(connection.Message),
  state: State,
  out: bytes_tree.BytesTree,
  wrote: Bool,
) -> FrameResult {
  case wrote {
    False -> Proceed(state)
    True ->
      case glisten.send(connection, out) {
        Ok(Nil) -> Proceed(state)
        Error(_reason) -> Terminate(None)
      }
  }
}

fn flush_many(
  state: State,
  streams: List(#(Int, Stream)),
  out: bytes_tree.BytesTree,
  wrote: Bool,
  connection: glisten.Connection(connection.Message),
) -> FrameResult {
  case streams {
    [] -> send_if_any(connection, state, out, wrote)
    [#(stream_id, entry), ..remaining] ->
      case do_flush_stream(state, stream_id, entry, out, wrote) {
        FlushAccumulated(state, out, wrote) ->
          flush_many(state, remaining, out, wrote, connection)
        FlushFileChunk(state, out, stream_id, entry, chunk_size, end_stream) ->
          send_file_chunk(
            state,
            stream_id,
            entry,
            out,
            chunk_size,
            end_stream,
            remaining,
            connection,
          )
      }
  }
}

fn send_file_chunk(
  state: State,
  stream_id: Int,
  entry: Stream,
  out: bytes_tree.BytesTree,
  chunk_size: Int,
  end_stream: Bool,
  rest: List(#(Int, Stream)),
  connection: glisten.Connection(connection.Message),
) -> FrameResult {
  let assert PendingFile(descriptor, offset, remaining) = entry.pending

  case glisten.send(connection, out) {
    Error(_reason) -> {
      file.close(descriptor)
      Terminate(None)
    }
    Ok(Nil) ->
      case
        file.send_chunk(
          connection.transport,
          connection.socket,
          descriptor,
          offset,
          chunk_size,
        )
      {
        Error(_reason) -> {
          file.close(descriptor)
          Terminate(None)
        }
        Ok(Nil) -> {
          let state =
            State(
              ..state,
              conn_send_window: state.conn_send_window - chunk_size,
            )

          case end_stream {
            True -> {
              file.close(descriptor)

              State(..state, streams: dict.delete(state.streams, stream_id))
              |> flush_many(rest, bytes_tree.new(), False, connection)
            }
            False -> {
              let pending =
                PendingFile(
                  descriptor,
                  offset + chunk_size,
                  remaining - chunk_size,
                )
              let entry =
                Stream(
                  ..entry,
                  send_window: entry.send_window - chunk_size,
                  pending:,
                )

              flush_many(
                state,
                [#(stream_id, entry), ..rest],
                bytes_tree.new(),
                False,
                connection,
              )
            }
          }
        }
      }
  }
}

@internal
pub fn flush_stream(
  state: State,
  stream_id: Int,
  entry: Stream,
  out: bytes_tree.BytesTree,
  connection: glisten.Connection(connection.Message),
) -> FrameResult {
  flush_many(state, [#(stream_id, entry)], out, False, connection)
}

fn has_pending(entry: Stream) -> Bool {
  pending_has_bytes(entry.pending)
}

fn pending_has_bytes(pending: Pending) -> Bool {
  case pending {
    PendingBytes(<<>>) -> False
    PendingFile(_descriptor, _offset, 0) -> False
    _pending -> True
  }
}

fn handle_window_update(
  state: State,
  stream_id: Int,
  increment: Int,
  connection: glisten.Connection(connection.Message),
) -> FrameResult {
  case increment > 0, stream_id {
    False, 0 -> Terminate(Some(frame.ProtocolError))
    False, _stream_id -> RejectStream(state, stream_id, frame.ProtocolError)
    True, 0 -> connection_window_update(state, increment, connection)
    True, _stream_id ->
      stream_window_update(state, stream_id, increment, connection)
  }
}

fn connection_window_update(
  state: State,
  increment: Int,
  connection: glisten.Connection(connection.Message),
) -> FrameResult {
  let new_window = state.conn_send_window + increment

  case new_window > max_window_size {
    True -> Terminate(Some(frame.FlowControlError))
    False ->
      flush_pending_streams(
        State(..state, conn_send_window: new_window),
        connection,
      )
  }
}

fn stream_window_update(
  state: State,
  stream_id: Int,
  increment: Int,
  connection: glisten.Connection(connection.Message),
) -> FrameResult {
  case
    dict.get(state.streams, stream_id),
    stream_id > state.highest_client_stream_id_seen
  {
    Error(Nil), True -> Terminate(Some(frame.ProtocolError))
    Error(Nil), False -> Proceed(state)
    Ok(entry), _is_new_stream -> {
      let new_window = entry.send_window + increment

      case new_window > max_window_size {
        True -> RejectStream(state, stream_id, frame.FlowControlError)
        False -> {
          let entry = Stream(..entry, send_window: new_window)

          case entry.status, has_pending(entry) {
            Computing(_pid), False -> {
              let streams = dict.insert(state.streams, stream_id, entry)
              Proceed(State(..state, streams:))
            }
            Computing(_pid), True | Flushing, _has_pending ->
              flush_stream(
                state,
                stream_id,
                entry,
                bytes_tree.new(),
                connection,
              )
          }
        }
      }
    }
  }
}

fn flush_pending_streams(
  state: State,
  connection: glisten.Connection(connection.Message),
) -> FrameResult {
  let pending =
    dict.filter(state.streams, fn(_stream_id, entry) { has_pending(entry) })
    |> dict.to_list

  flush_many(state, pending, bytes_tree.new(), False, connection)
}

fn handle_stream_exit(
  state: State,
  exit: process.ExitMessage,
  connection: glisten.Connection(connection.Message),
) -> Next {
  case state.parent == Ok(exit.pid), exit.reason {
    True, process.Abnormal(reason) ->
      case http2.is_shutdown(reason) {
        True -> begin_drain(state, connection)
        False -> stop_connection(state)
      }
    True, process.Normal | True, process.Killed -> stop_connection(state)
    False, _reason -> handle_child_exit(state, exit.pid, connection)
  }
}

fn handle_child_exit(
  state: State,
  pid: process.Pid,
  connection: glisten.Connection(connection.Message),
) -> Next {
  case dict.get(state.stream_pids, pid) {
    Error(Nil) -> finish_or_continue(state)
    Ok(stream_id) ->
      case dict.get(state.streams, stream_id) {
        Ok(Stream(status: Computing(stream_pid), ..) as entry)
          if stream_pid == pid
        ->
          remove_stream(state, stream_id, entry)
          |> reject_stream(connection, _, stream_id, frame.InternalError)
        _entry -> finish_or_continue(clear_stream_pid(state, pid))
      }
  }
}

@internal
pub fn test_state() -> State {
  let options = http2.default_options()

  State(
    buffer: <<>>,
    handshake: Connected,
    peer_settings: default_peer_settings,
    timer: None,
    hpack_decoder: alpacki.new_dynamic(options.header_table_size),
    hpack_encoder: alpacki.new_dynamic(options.header_table_size),
    header_assembly: None,
    reply_subject: process.new_subject(),
    handler: fn(_request) {
      response.new(200) |> response.set_body(connection.Empty)
    },
    streams: dict.new(),
    conn_send_window: default_send_window,
    conn_recv_window: default_send_window,
    stream_pids: dict.new(),
    reset_window_start: 0,
    reset_count: 0,
    highest_client_stream_id_seen: 0,
    draining: False,
    drain_subject: process.new_subject(),
    drain_timer: None,
    options:,
    settings_frame: build_settings_frame(options),
    patterns: header_patterns(),
    peer: Error(Nil),
    parent: Error(Nil),
  )
}
