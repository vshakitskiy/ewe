import alpacki
import ewe/internal/clock
import ewe/internal/connection.{type Body}
import ewe/internal/file
import ewe/internal/http2/connection as http2
import ewe/internal/http2/frame.{type ErrorCode}
import ewe/internal/http2/outbox.{type Outbox}
import ewe/internal/http2/parser
import ewe/internal/http2/worker
import ewe/internal/queue.{type Queue}
import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import logging
import tup
import tup/socket

pub type Next {
  Continue(State)
  Close
}

pub opaque type State {
  State(
    phase: Phase,
    lifecycle: Lifecycle,
    buffer: BitArray,
    output: List(Segment),
    output_size: Int,
    options: http2.Options,
    settings_acknowledged: Bool,
    local_initial_window: Int,
    peer_initial_window: Int,
    peer_max_frame_size: Int,
    decoder: alpacki.DynamicTable,
    decoder_limit: Int,
    encoder: alpacki.DynamicTable,
    streams: Dict(Int, Stream),
    workers: Dict(Pid, Int),
    ready: Queue(Int),
    resuming: Bool,
    reset_streams: List(Int),
    last_stream_id: Int,
    send_window: Int,
    recv_window: Int,
    resets: ResetBudget,
    last_activity: Int,
    self: Subject(connection.Message),
    commands: Subject(http2.Command),
    handler: connection.Handler,
    peer: tup.Endpoint,
    scheme: http.Scheme,
    parent: Result(Pid, Nil),
  )
}

type Phase {
  AwaitingSettings
  AwaitingFrame
  AwaitingContinuation(FieldBlock)
}

type FieldBlock {
  FieldBlock(
    stream_id: Int,
    purpose: Purpose,
    end_stream: Bool,
    dependency: Option(Int),
    fragments: BitArray,
    continuations: Int,
  )
}

type Purpose {
  OpensRequest
  Trailers
  ClosedStream
}

type Segment {
  Frames(BytesTree)
  SendFile(descriptor: connection.FileDescriptor, offset: Int, length: Int)
  CloseFile(connection.FileDescriptor)
}

type Lifecycle {
  Serving
  Announcing
  Closing(last_stream_id: Int)
}

type Stream {
  Stream(
    head_request: Bool,
    outbound: Outbound,
    inbound: Inbound,
    tunnel: Bool,
    worker: Option(Pid),
    send_window: Int,
    recv_window: Int,
    scheduled: Bool,
    held_ack: Option(Subject(http2.WriteAck)),
    signals: Option(Subject(http2.StreamSignal)),
    files: List(connection.FileDescriptor),
    unread: BytesTree,
    unread_size: Int,
    reader: Option(Subject(http2.BodyEvent)),
    trailers: List(#(String, String)),
    content_length: Option(Int),
    received_size: Int,
  )
}

type Outbound {
  AwaitingResponse
  Responding(Outbox)
  Responded
}

type Inbound {
  Receiving
  Received
  Consumed
}

type ResetBudget {
  ResetBudget(window_start: Int, count: Int)
}

type Halt {
  Fail(state: State, error: ErrorCode)
  Quit(state: State)
}

const max_stream_id = 2_147_483_647

const remembered_resets = 100

const worker_grace_ms = 5000

const transmit_quantum = 1_048_576

const cork_limit = 262_144

const shutdown_ping = <<"shutdown":utf8>>

pub fn start(
  connection: tup.Connection,
  handler: connection.Handler,
  options: http2.Options,
  self: Subject(connection.Message),
  commands: Subject(http2.Command),
  parent: Result(Pid, Nil),
  rest: BitArray,
) -> Next {
  let scheme = case tup.socket(connection).0 {
    socket.Tcp -> http.Http
    socket.Ssl -> http.Https
  }

  let now = monotonic_ms()
  let state =
    State(
      phase: AwaitingSettings,
      lifecycle: Serving,
      buffer: <<>>,
      output: [],
      output_size: 0,
      options:,
      settings_acknowledged: False,
      local_initial_window: frame.default_window_size,
      peer_initial_window: frame.default_window_size,
      peer_max_frame_size: frame.min_frame_size,
      decoder: alpacki.new_dynamic(frame.default_header_table_size),
      decoder_limit: frame.default_header_table_size,
      encoder: alpacki.new_dynamic(frame.default_header_table_size),
      streams: dict.new(),
      workers: dict.new(),
      ready: queue.new(),
      resuming: False,
      reset_streams: [],
      last_stream_id: 0,
      send_window: frame.default_window_size,
      recv_window: frame.default_window_size,
      resets: ResetBudget(window_start: now, count: 0),
      last_activity: now,
      self:,
      commands:,
      handler:,
      peer: tup.peer(connection),
      scheme:,
      parent:,
    )

  process.send_after(
    self,
    options.handshake_timeout_ms,
    connection.Http2HandshakeTimeout,
  )
  process.send_after(self, options.idle_timeout_ms, connection.Http2IdleTimeout)

  state
  |> emit(frame.encode(frame.Settings(ack: False, settings: settings(options))))
  |> open_connection_window
  |> receive(rest)
  |> conclude(connection)
}

fn settings(options: http2.Options) -> List(frame.Setting) {
  [
    frame.HeaderTableSize(options.header_table_size),
    frame.InitialWindowSize(options.initial_window_size),
    frame.MaxFrameSize(options.max_frame_size),
    frame.EnableConnectProtocol(options.websocket),
    ..option.values([
      option.map(options.max_concurrent_streams, frame.MaxConcurrentStreams),
      option.map(options.max_header_list_size, frame.MaxHeaderListSize),
    ])
  ]
}

fn open_connection_window(state: State) -> State {
  let increment = connection_window(state.options) - state.recv_window

  case increment > 0 {
    True ->
      State(..state, recv_window: state.recv_window + increment)
      |> emit(frame.encode(frame.WindowUpdate(0, increment)))
    False -> state
  }
}

pub fn handle_message(
  state: State,
  message: tup.Message(connection.Message),
  connection: tup.Connection,
) -> Next {
  case message {
    tup.Incoming(bytes) -> receive(state, bytes)
    tup.User(connection.Http2Command(command)) ->
      Ok(handle_command(state, command))
    tup.User(connection.Http2Respond(stream_id:, response:)) ->
      Ok(receive_response(state, stream_id, response))
    tup.User(connection.Http2Exit(exit)) -> handle_exit(state, exit)
    tup.User(connection.Http2HandshakeTimeout) -> handshake_timeout(state)
    tup.User(connection.Http2Resume) -> Ok(State(..state, resuming: False))
    tup.User(connection.Http2KillWorker(pid)) -> Ok(kill_worker(state, pid))
    tup.User(connection.Http2IdleTimeout) -> idle_timeout(state)
    tup.User(connection.IdleTimeout) -> Ok(state)
    tup.User(connection.Http2DrainTimeout) -> Error(Quit(state))
  }
  |> conclude(connection)
}

fn conclude(result: Result(State, Halt), connection: tup.Connection) -> Next {
  case result {
    Ok(state) -> {
      let state = transmit(state, transmit_quantum)
      let finished = case state.lifecycle {
        Closing(..) -> dict.is_empty(state.streams)
        Serving | Announcing -> False
      }

      case !finished && hold_output(state) {
        True -> Continue(resume_later(state))
        False ->
          case write(state, connection) {
            Ok(state) if !finished -> Continue(state)
            Ok(state) -> stop(state)
            Error(Nil) -> stop(state)
          }
      }
    }
    Error(Fail(state:, error:)) -> {
      let last_stream_id = case state.lifecycle {
        Closing(last_stream_id:) -> last_stream_id
        Serving | Announcing -> state.last_stream_id
      }
      let state =
        emit(
          state,
          frame.encode(frame.Goaway(last_stream_id:, error:, debug: <<>>)),
        )
      let _written = write(state, connection)
      stop(state)
    }
    Error(Quit(state:)) -> stop(state)
  }
}

fn receive(state: State, bytes: BitArray) -> Result(State, Halt) {
  State(
    ..state,
    buffer: connection.append_buffer(state.buffer, bytes),
    last_activity: monotonic_ms(),
  )
  |> process_frames
}

fn process_frames(state: State) -> Result(State, Halt) {
  case frame.decode(state.buffer, state.options.max_frame_size) {
    frame.Decoded(frame:, rest:) ->
      case handle_frame(State(..state, buffer: rest), frame) {
        Ok(state) -> process_frames(state)
        Error(halt) -> Error(halt)
      }
    frame.StreamError(stream_id:, error:, rest:) ->
      case stream_error(State(..state, buffer: rest), stream_id, error) {
        Ok(state) -> process_frames(state)
        Error(halt) -> Error(halt)
      }
    frame.ConnectionError(error) -> Error(Fail(state, error))
    frame.NeedMoreData -> Ok(state)
  }
}

fn handle_frame(state: State, received: frame.Frame) -> Result(State, Halt) {
  case state.phase, received {
    AwaitingSettings, frame.Settings(ack: False, settings:) ->
      apply_settings(State(..state, phase: AwaitingFrame), settings)
    AwaitingSettings, _frame -> Error(Fail(state, frame.ProtocolError))
    AwaitingContinuation(block),
      frame.Continuation(stream_id:, end_headers:, fragment:)
      if stream_id == block.stream_id
    -> continue_field_block(state, block, end_headers, fragment)
    AwaitingContinuation(_block), _frame ->
      Error(Fail(state, frame.ProtocolError))
    AwaitingFrame, frame.Data(stream_id:, end_stream:, data:, size:) ->
      receive_data(state, stream_id, end_stream, data, size)
    AwaitingFrame,
      frame.Headers(
        stream_id:,
        end_stream:,
        end_headers:,
        dependency:,
        fragment:,
      )
    ->
      begin_field_block(
        state,
        stream_id,
        end_stream,
        end_headers,
        dependency,
        fragment,
      )
    AwaitingFrame, frame.Priority(stream_id:, dependency:) ->
      receive_priority(state, stream_id, dependency)
    AwaitingFrame, frame.RstStream(stream_id:, error: _error) ->
      receive_reset(state, stream_id)
    AwaitingFrame, frame.Settings(ack: False, settings:) ->
      apply_settings(state, settings)
    AwaitingFrame, frame.Settings(ack: True, settings: _settings) ->
      Ok(receive_settings_ack(state))
    AwaitingFrame, frame.PushPromise(..) ->
      Error(Fail(state, frame.ProtocolError))
    AwaitingFrame, frame.Ping(ack: False, data:) ->
      Ok(emit(state, frame.encode(frame.Ping(ack: True, data:))))
    AwaitingFrame, frame.Ping(ack: True, data:) ->
      Ok(receive_ping_ack(state, data))
    AwaitingFrame, frame.Goaway(last_stream_id: _last, error:, debug: _debug) ->
      receive_goaway(state, error)
    AwaitingFrame, frame.WindowUpdate(stream_id:, increment:) ->
      receive_window_update(state, stream_id, increment)
    AwaitingFrame, frame.Continuation(..) ->
      Error(Fail(state, frame.ProtocolError))
    AwaitingFrame, frame.Unknown(..) -> Ok(state)
  }
}

type Lookup {
  Open(Stream)
  Idle
  Closed
}

fn lookup(state: State, stream_id: Int) -> Lookup {
  case dict.get(state.streams, stream_id) {
    Ok(stream) -> Open(stream)
    Error(Nil) ->
      case stream_id % 2 == 1 && stream_id <= state.last_stream_id {
        True -> Closed
        False -> Idle
      }
  }
}

fn receive_data(
  state: State,
  stream_id: Int,
  end_stream: Bool,
  data: BitArray,
  size: Int,
) -> Result(State, Halt) {
  case lookup(state, stream_id) {
    Idle -> Error(Fail(state, frame.ProtocolError))
    Open(stream) -> {
      use state <- result.try(consume_connection_window(state, size))
      receive_stream_data(state, stream_id, stream, end_stream, data, size)
    }
    Closed -> {
      use state <- result.try(consume_connection_window(state, size))
      closed_stream_data(state, stream_id)
    }
  }
}

fn consume_connection_window(state: State, size: Int) -> Result(State, Halt) {
  case size > state.recv_window {
    True -> Error(Fail(state, frame.FlowControlError))
    False -> {
      let recv_window = state.recv_window - size
      let target = connection_window(state.options)

      case recv_window <= target / 2 {
        False -> Ok(State(..state, recv_window:))
        True ->
          State(..state, recv_window: target)
          |> emit(frame.encode(frame.WindowUpdate(0, target - recv_window)))
          |> Ok
      }
    }
  }
}

fn connection_window(options: http2.Options) -> Int {
  case options.max_concurrent_streams {
    Some(limit) ->
      int.min(
        limit * options.recv_window_high_water_mark,
        frame.max_window_size,
      )
    None -> frame.max_window_size
  }
}

fn receive_stream_data(
  state: State,
  stream_id: Int,
  stream: Stream,
  end_stream: Bool,
  data: BitArray,
  size: Int,
) -> Result(State, Halt) {
  let received_size = stream.received_size + bit_array.byte_size(data)

  case stream.inbound {
    Received | Consumed -> stream_error(state, stream_id, frame.StreamClosed)
    Receiving if size > stream.recv_window ->
      stream_error(state, stream_id, frame.FlowControlError)
    Receiving ->
      case
        content_length_mismatch(
          stream.content_length,
          received_size,
          end_stream,
        )
      {
        True -> stream_error(state, stream_id, frame.ProtocolError)
        False ->
          Stream(
            ..stream,
            inbound: case end_stream {
              True -> Received
              False -> Receiving
            },
            recv_window: stream.recv_window - size,
            unread: bytes_tree.append(stream.unread, data),
            unread_size: stream.unread_size + bit_array.byte_size(data),
            received_size:,
          )
          |> feed_reader(state, stream_id, _)
          |> Ok
      }
  }
}

fn content_length_mismatch(
  content_length: Option(Int),
  received: Int,
  complete: Bool,
) -> Bool {
  case content_length {
    None -> False
    Some(expected) -> received > expected || complete && received != expected
  }
}

fn feed_reader(state: State, stream_id: Int, stream: Stream) -> State {
  let stream = case stream.reader, body_event(stream) {
    Some(reader), Some(#(event, inbound)) -> {
      process.send(reader, event)
      Stream(
        ..stream,
        inbound:,
        reader: None,
        unread: bytes_tree.new(),
        unread_size: 0,
      )
    }
    Some(_reader), None | None, _event -> stream
  }

  let #(state, stream) = refill_stream_window(state, stream_id, stream)
  settle(state, stream_id, stream)
}

fn body_event(stream: Stream) -> Option(#(http2.BodyEvent, Inbound)) {
  case stream.unread_size, stream.inbound {
    0, Receiving -> None
    _size, Receiving ->
      Some(#(
        http2.ChunkEvent(bytes_tree.to_bit_array(stream.unread)),
        Receiving,
      ))
    0, Received | _size, Consumed ->
      Some(#(http2.DoneEvent(stream.trailers), Consumed))
    _size, Received ->
      Some(#(
        http2.LastChunkEvent(
          bytes_tree.to_bit_array(stream.unread),
          stream.trailers,
        ),
        Consumed,
      ))
  }
}

fn refill_stream_window(
  state: State,
  stream_id: Int,
  stream: Stream,
) -> #(State, Stream) {
  let target = state.options.recv_window_high_water_mark - stream.unread_size
  let increment = target - stream.recv_window
  let at_low_water =
    stream.recv_window <= state.options.recv_window_low_water_mark

  case stream.inbound == Receiving && at_low_water && increment > 0 {
    True -> #(
      emit(state, frame.encode(frame.WindowUpdate(stream_id, increment))),
      Stream(..stream, recv_window: target),
    )
    False -> #(state, stream)
  }
}

fn begin_field_block(
  state: State,
  stream_id: Int,
  end_stream: Bool,
  end_headers: Bool,
  dependency: Option(Int),
  fragment: BitArray,
) -> Result(State, Halt) {
  let purpose = case lookup(state, stream_id) {
    Idle if stream_id % 2 == 1 -> Ok(OpensRequest)
    Idle -> Error(Fail(state, frame.ProtocolError))
    Open(_stream) -> Ok(Trailers)
    Closed -> Ok(ClosedStream)
  }
  use purpose <- result.try(purpose)

  let last_stream_id = case purpose {
    OpensRequest -> stream_id
    Trailers | ClosedStream -> state.last_stream_id
  }

  let block =
    FieldBlock(
      stream_id:,
      purpose:,
      end_stream:,
      dependency:,
      fragments: <<>>,
      continuations: 0,
    )

  extend_field_block(
    State(..state, last_stream_id:),
    block,
    end_headers,
    fragment,
  )
}

fn continue_field_block(
  state: State,
  block: FieldBlock,
  end_headers: Bool,
  fragment: BitArray,
) -> Result(State, Halt) {
  let block = FieldBlock(..block, continuations: block.continuations + 1)
  extend_field_block(
    State(..state, phase: AwaitingFrame),
    block,
    end_headers,
    fragment,
  )
}

fn extend_field_block(
  state: State,
  block: FieldBlock,
  end_headers: Bool,
  fragment: BitArray,
) -> Result(State, Halt) {
  let block =
    FieldBlock(..block, fragments: <<block.fragments:bits, fragment:bits>>)

  case
    bit_array.byte_size(block.fragments) > state.options.max_header_block_bytes
    || block.continuations > state.options.max_continuation_frames
  {
    True -> Error(Fail(state, frame.EnhanceYourCalm))
    False ->
      case end_headers {
        False -> Ok(State(..state, phase: AwaitingContinuation(block)))
        True -> complete_field_block(state, block)
      }
  }
}

fn complete_field_block(
  state: State,
  block: FieldBlock,
) -> Result(State, Halt) {
  use #(state, fields, size) <- result.try(decode_field_block(
    state,
    block.fragments,
  ))

  let oversized = case state.options.max_header_list_size {
    Some(limit) -> size > limit
    None -> False
  }

  case block.purpose, block.dependency {
    ClosedStream, _dependency -> closed_stream_headers(state, block.stream_id)
    OpensRequest, Some(dependency) if dependency == block.stream_id ->
      stream_error(state, block.stream_id, frame.ProtocolError)
    OpensRequest, _dependency -> open_stream(state, block, fields, oversized)
    Trailers, _dependency if oversized ->
      stream_error(state, block.stream_id, frame.ProtocolError)
    Trailers, _dependency -> receive_trailers(state, block, fields)
  }
}

fn decode_field_block(
  state: State,
  block: BitArray,
) -> Result(#(State, List(#(BitArray, BitArray)), Int), Halt) {
  case alpacki.decode_header_block(block, state.decoder) {
    Ok(alpacki.DecodedHeaderBlock(
      headers:,
      decoded_size:,
      dynamic_table:,
      remaining: <<>>,
    )) ->
      case alpacki.dynamic_max_size(dynamic_table) > state.decoder_limit {
        True -> Error(Fail(state, frame.CompressionError))
        False ->
          Ok(#(State(..state, decoder: dynamic_table), headers, decoded_size))
      }
    Ok(alpacki.DecodedHeaderBlock(..)) | Error(_error) ->
      Error(Fail(state, frame.CompressionError))
  }
}

fn open_stream(
  state: State,
  block: FieldBlock,
  fields: List(#(BitArray, BitArray)),
  oversized: Bool,
) -> Result(State, Halt) {
  let stream_id = block.stream_id
  let refused = case state.lifecycle, state.options.max_concurrent_streams {
    Closing(last_stream_id:), _limit -> stream_id > last_stream_id
    _lifecycle, Some(limit) ->
      dict.size(state.streams) >= limit || dict.size(state.workers) >= limit
    _lifecycle, None -> False
  }

  case refused, oversized {
    True, _oversized -> Ok(reset(state, stream_id, frame.RefusedStream))
    False, True -> Ok(answer_early(state, stream_id, block.end_stream, 431))
    False, False -> start_request(state, block, fields)
  }
}

fn start_request(
  state: State,
  block: FieldBlock,
  fields: List(#(BitArray, BitArray)),
) -> Result(State, Halt) {
  let stream_id = block.stream_id

  case parser.request(fields, state.scheme, state.options.websocket) {
    Error(_malformed) -> Ok(reset(state, stream_id, frame.ProtocolError))
    Ok(parser.DecodedRequest(content_length: Some(length), ..))
      if block.end_stream && length != 0
    -> Ok(reset(state, stream_id, frame.ProtocolError))
    Ok(parser.DecodedRequest(request:, content_length:, protocol:)) -> {
      let request =
        http2.Connection(
          commands: state.commands,
          stream_id:,
          has_body: !block.end_stream,
          pending: <<>>,
          pending_trailers: None,
          bytes_read: 0,
          body_read_timeout: state.options.body_read_timeout,
          peer: state.peer,
          protocol:,
        )
        |> connection.Http2
        |> request.set_body(request, _)
      let pid =
        worker.start(
          state.self,
          state.commands,
          stream_id,
          request,
          state.handler,
        )
      let stream =
        Stream(
          ..new_stream(state, block.end_stream, Some(pid)),
          head_request: request.method == http.Head,
          tunnel: request.method == http.Connect,
          content_length:,
        )

      Ok(
        State(
          ..state,
          streams: dict.insert(state.streams, stream_id, stream),
          workers: dict.insert(state.workers, pid, stream_id),
        ),
      )
    }
  }
}

fn new_stream(state: State, end_stream: Bool, worker: Option(Pid)) -> Stream {
  Stream(
    head_request: False,
    outbound: AwaitingResponse,
    inbound: case end_stream {
      True -> Consumed
      False -> Receiving
    },
    tunnel: False,
    worker:,
    send_window: state.peer_initial_window,
    recv_window: state.local_initial_window,
    scheduled: False,
    held_ack: None,
    signals: None,
    files: [],
    unread: bytes_tree.new(),
    unread_size: 0,
    reader: None,
    trailers: [],
    content_length: None,
    received_size: 0,
  )
}

fn answer_early(
  state: State,
  stream_id: Int,
  end_stream: Bool,
  status: Int,
) -> State {
  let stream = new_stream(state, end_stream, None)
  send_response(state, stream_id, stream, status, [], [], Omitted)
}

fn receive_trailers(
  state: State,
  block: FieldBlock,
  fields: List(#(BitArray, BitArray)),
) -> Result(State, Halt) {
  case dict.get(state.streams, block.stream_id) {
    Error(Nil) -> closed_stream_headers(state, block.stream_id)
    Ok(stream) ->
      case stream.inbound, block.end_stream, parser.trailers(fields) {
        Received, _end_stream, _trailers | Consumed, _end_stream, _trailers ->
          stream_error(state, block.stream_id, frame.StreamClosed)
        Receiving, False, _trailers ->
          stream_error(state, block.stream_id, frame.ProtocolError)
        Receiving, True, Error(_malformed) ->
          stream_error(state, block.stream_id, frame.ProtocolError)
        Receiving, True, Ok(trailers) ->
          case
            content_length_mismatch(
              stream.content_length,
              stream.received_size,
              True,
            )
          {
            True -> stream_error(state, block.stream_id, frame.ProtocolError)
            False ->
              Stream(..stream, inbound: Received, trailers:)
              |> feed_reader(state, block.stream_id, _)
              |> Ok
          }
      }
  }
}

fn closed_stream_data(state: State, stream_id: Int) -> Result(State, Halt) {
  case list.contains(state.reset_streams, stream_id) {
    True -> Ok(state)
    False -> Ok(reset(state, stream_id, frame.StreamClosed))
  }
}

fn closed_stream_headers(state: State, stream_id: Int) -> Result(State, Halt) {
  case list.contains(state.reset_streams, stream_id) {
    True -> Ok(state)
    False -> Error(Fail(state, frame.ProtocolError))
  }
}

fn receive_priority(
  state: State,
  stream_id: Int,
  dependency: Int,
) -> Result(State, Halt) {
  case dependency == stream_id {
    True -> stream_error(state, stream_id, frame.ProtocolError)
    False -> Ok(state)
  }
}

fn receive_reset(state: State, stream_id: Int) -> Result(State, Halt) {
  case lookup(state, stream_id) {
    Idle -> Error(Fail(state, frame.ProtocolError))
    Closed -> Ok(state)
    Open(stream) -> {
      use state <- result.map(count_reset(state, stream))
      remove_stream(state, stream_id, stream)
    }
  }
}

fn receive_window_update(
  state: State,
  stream_id: Int,
  increment: Int,
) -> Result(State, Halt) {
  case stream_id, increment, lookup(state, stream_id) {
    0, 0, _lookup -> Error(Fail(state, frame.ProtocolError))
    0, _increment, _lookup ->
      case state.send_window + increment > frame.max_window_size {
        True -> Error(Fail(state, frame.FlowControlError))
        False -> Ok(State(..state, send_window: state.send_window + increment))
      }
    _stream_id, _increment, Idle -> Error(Fail(state, frame.ProtocolError))
    _stream_id, _increment, Closed -> Ok(state)
    _stream_id, 0, Open(_stream) ->
      stream_error(state, stream_id, frame.ProtocolError)
    _stream_id, _increment, Open(stream) ->
      case stream.send_window + increment > frame.max_window_size {
        True -> stream_error(state, stream_id, frame.FlowControlError)
        False ->
          Stream(..stream, send_window: stream.send_window + increment)
          |> schedule(state, stream_id, _)
          |> Ok
      }
  }
}

fn apply_settings(
  state: State,
  settings: List(frame.Setting),
) -> Result(State, Halt) {
  use state <- result.map(list.try_fold(settings, state, apply_setting))
  emit(state, frame.encode(frame.Settings(ack: True, settings: [])))
}

fn apply_setting(state: State, setting: frame.Setting) -> Result(State, Halt) {
  case setting {
    frame.HeaderTableSize(size) -> {
      let size = int.min(size, frame.default_header_table_size)

      case size == alpacki.dynamic_max_size(state.encoder) {
        True -> Ok(state)
        False ->
          Ok(
            State(..state, encoder: alpacki.resize_dynamic(state.encoder, size)),
          )
      }
    }
    frame.InitialWindowSize(size) -> change_initial_window(state, size)
    frame.MaxFrameSize(size) -> Ok(State(..state, peer_max_frame_size: size))
    frame.EnablePush(_enabled)
    | frame.MaxConcurrentStreams(_limit)
    | frame.EnableConnectProtocol(_enabled)
    | frame.MaxHeaderListSize(_size) -> Ok(state)
  }
}

fn change_initial_window(state: State, size: Int) -> Result(State, Halt) {
  let delta = size - state.peer_initial_window
  let state = State(..state, peer_initial_window: size)

  use state, stream_id, stream <- dict.fold(state.streams, Ok(state))
  use state <- result.try(state)
  let send_window = stream.send_window + delta

  case send_window > frame.max_window_size {
    True -> Error(Fail(state, frame.FlowControlError))
    False -> Ok(schedule(state, stream_id, Stream(..stream, send_window:)))
  }
}

fn receive_settings_ack(state: State) -> State {
  case state.settings_acknowledged {
    True -> state
    False -> {
      let limit = state.options.header_table_size
      let decoder = case limit < alpacki.dynamic_max_size(state.decoder) {
        True -> alpacki.expect_table_size_update(state.decoder)
        False -> state.decoder
      }
      let delta = state.options.initial_window_size - state.local_initial_window
      let streams =
        dict.map_values(state.streams, fn(_stream_id, stream) {
          Stream(..stream, recv_window: stream.recv_window + delta)
        })

      State(
        ..state,
        settings_acknowledged: True,
        decoder:,
        decoder_limit: limit,
        local_initial_window: state.options.initial_window_size,
        streams:,
      )
    }
  }
}

fn handshake_timeout(state: State) -> Result(State, Halt) {
  case state.phase, state.settings_acknowledged {
    AwaitingSettings, _acknowledged -> Error(Fail(state, frame.ProtocolError))
    _phase, False -> Error(Fail(state, frame.SettingsTimeout))
    _phase, True -> Ok(state)
  }
}

fn receive_ping_ack(state: State, data: BitArray) -> State {
  case state.lifecycle, data == shutdown_ping {
    Announcing, True -> send_final_goaway(state)
    _lifecycle, _shutdown -> state
  }
}

fn send_final_goaway(state: State) -> State {
  let last_stream_id = state.last_stream_id

  State(..state, lifecycle: Closing(last_stream_id:))
  |> emit(
    frame.encode(
      frame.Goaway(last_stream_id:, error: frame.NoError, debug: <<>>),
    ),
  )
}

fn receive_goaway(state: State, error: ErrorCode) -> Result(State, Halt) {
  case error, state.lifecycle {
    frame.NoError, Closing(..) -> Ok(state)
    frame.NoError, Serving | frame.NoError, Announcing ->
      Ok(send_final_goaway(state))
    _error, _lifecycle -> Error(Quit(state))
  }
}

fn stream_error(
  state: State,
  stream_id: Int,
  error: ErrorCode,
) -> Result(State, Halt) {
  case lookup(state, stream_id) {
    Idle -> Error(Fail(state, error))
    Closed -> Ok(reset(state, stream_id, error))
    Open(stream) -> {
      use state <- result.map(count_reset(state, stream))
      reset(state, stream_id, error)
    }
  }
}

fn reset(state: State, stream_id: Int, error: ErrorCode) -> State {
  let state =
    State(
      ..state,
      reset_streams: list.take(
        [stream_id, ..state.reset_streams],
        remembered_resets,
      ),
    )
    |> emit(frame.encode(frame.RstStream(stream_id:, error:)))

  case dict.get(state.streams, stream_id) {
    Ok(stream) -> remove_stream(state, stream_id, stream)
    Error(Nil) -> state
  }
}

fn count_reset(state: State, stream: Stream) -> Result(State, Halt) {
  case stream.worker {
    None -> Ok(state)
    Some(_pid) -> {
      let now = monotonic_ms()
      let resets = case
        now - state.resets.window_start > state.options.rapid_reset_window_ms
      {
        True -> ResetBudget(window_start: now, count: 1)
        False -> ResetBudget(..state.resets, count: state.resets.count + 1)
      }

      case resets.count > state.options.rapid_reset_threshold {
        True -> Error(Fail(state, frame.EnhanceYourCalm))
        False -> Ok(State(..state, resets:))
      }
    }
  }
}

fn remove_stream(state: State, stream_id: Int, stream: Stream) -> State {
  case stream.worker {
    Some(pid) -> {
      process.send_abnormal_exit(pid, "stream_reset")
      process.send_after(
        state.self,
        worker_grace_ms,
        connection.Http2KillWorker(pid),
      )
      Nil
    }
    None -> Nil
  }

  State(..state, streams: dict.delete(state.streams, stream_id))
  |> close_files(stream.files)
}

fn settle(state: State, stream_id: Int, stream: Stream) -> State {
  case stream.outbound, stream.inbound, stream.worker {
    Responded, Consumed, _worker | Responded, Received, None ->
      State(..state, streams: dict.delete(state.streams, stream_id))
    Responded, Receiving, None ->
      State(..state, streams: dict.insert(state.streams, stream_id, stream))
      |> reset(stream_id, frame.NoError)
    _outbound, _inbound, _worker ->
      State(..state, streams: dict.insert(state.streams, stream_id, stream))
  }
}

fn receive_response(
  state: State,
  stream_id: Int,
  response: Response(Body),
) -> State {
  case dict.get(state.streams, stream_id) {
    Ok(Stream(outbound: AwaitingResponse, ..) as stream) ->
      respond(state, stream_id, stream, response)
    Ok(_stream) | Error(Nil) -> {
      file.release_body(response.body)
      state
    }
  }
}

fn handle_command(state: State, command: http2.Command) -> State {
  case command {
    http2.ReadBody(stream_id:, reply_to:) ->
      case dict.get(state.streams, stream_id) {
        Ok(stream) ->
          feed_reader(
            state,
            stream_id,
            Stream(..stream, reader: Some(reply_to)),
          )
        Error(Nil) -> {
          process.send(reply_to, http2.DoneEvent([]))
          state
        }
      }
    http2.WriteHeaders(stream_id:, ack:, status:, headers:, signals:) ->
      case dict.get(state.streams, stream_id) {
        Ok(Stream(outbound: AwaitingResponse, ..) as stream) ->
          start_streaming(
            state,
            stream_id,
            stream,
            status,
            headers,
            signals,
            ack,
          )
        Ok(_stream) | Error(Nil) -> refuse_write(state, ack)
      }
    http2.WriteData(stream_id:, data:, end_stream:, ack:) ->
      case dict.get(state.streams, stream_id) {
        Ok(Stream(outbound: Responding(outbox), ..) as stream) ->
          case outbox.is_finished(outbox) {
            False ->
              queue_data(
                state,
                stream_id,
                stream,
                outbox,
                data,
                end_stream,
                ack,
              )
            True -> refuse_write(state, ack)
          }
        Ok(_stream) | Error(Nil) -> refuse_write(state, ack)
      }
  }
}

fn refuse_write(state: State, ack: Subject(http2.WriteAck)) -> State {
  process.send(ack, http2.Ended)
  state
}

fn respond(
  state: State,
  stream_id: Int,
  stream: Stream,
  response: Response(Body),
) -> State {
  let status = response.status

  case status {
    _status if status < 200 || status > 599 -> {
      logging.log(
        logging.Error,
        "A handler answered with status "
          <> int.to_string(status)
          <> ", which cannot end an HTTP/2 response",
      )
      file.release_body(response.body)
      reset(state, stream_id, frame.InternalError)
    }
    204 -> no_content(state, stream_id, stream, response, Omitted)
    304 -> no_content(state, stream_id, stream, response, Unknown)
    _status if stream.head_request ->
      no_content(state, stream_id, stream, response, head_length(response.body))
    _status ->
      case open_body(response.body, state.options.file_read_threshold) {
        Ok(#(pieces, size, files)) ->
          send_response(
            state,
            stream_id,
            Stream(..stream, files:),
            status,
            response.headers,
            pieces,
            content_length(stream, status, Length(size)),
          )
        Error(_file_error) -> {
          logging.log(
            logging.Error,
            "Could not open the file of an HTTP/2 response",
          )
          send_response(state, stream_id, stream, 500, [], [], Length(0))
        }
      }
  }
}

fn content_length(
  stream: Stream,
  status: Int,
  length: ContentLength,
) -> ContentLength {
  case stream.tunnel && status >= 200 && status < 300 {
    True -> Omitted
    False -> length
  }
}

fn no_content(
  state: State,
  stream_id: Int,
  stream: Stream,
  response: Response(Body),
  length: ContentLength,
) -> State {
  file.release_body(response.body)
  send_response(
    state,
    stream_id,
    stream,
    response.status,
    response.headers,
    [],
    length,
  )
}

fn head_length(body: Body) -> ContentLength {
  case body {
    connection.Bytes(tree) -> Length(bytes_tree.byte_size(tree))
    connection.Text(text) -> Length(string.byte_size(text))
    connection.Empty -> Length(0)
    connection.File(connection.OpenFile(length:, ..))
    | connection.File(connection.PendingFile(length:, ..)) -> Length(length)
    connection.Streaming(_streaming)
    | connection.Sse(_sse)
    | connection.Websocket(_websocket) -> Unknown
  }
}

fn open_body(
  body: Body,
  threshold: Int,
) -> Result(
  #(List(outbox.Piece), Int, List(connection.FileDescriptor)),
  file.FileError,
) {
  case body {
    connection.Bytes(tree) -> {
      let size = bytes_tree.byte_size(tree)
      Ok(#([outbox.Bytes(tree, size)], size, []))
    }
    connection.Text(text) -> {
      let size = string.byte_size(text)
      Ok(#([outbox.Bytes(bytes_tree.from_string(text), size)], size, []))
    }
    connection.Empty -> Ok(#([], 0, []))
    connection.File(connection.OpenFile(handle:, offset:, length:)) ->
      Ok(#([outbox.File(handle, offset, length)], length, [handle]))
    connection.File(connection.PendingFile(path:, offset:, length:))
      if length <= threshold
    -> {
      use bits <- result.map(file.read_range(path, offset, length))
      #([outbox.bytes(bits)], length, [])
    }
    connection.File(connection.PendingFile(path:, offset:, length:)) -> {
      use handle <- result.map(file.open(path))
      #([outbox.File(handle, offset, length)], length, [handle])
    }
    connection.Streaming(_streaming)
    | connection.Sse(_sse)
    | connection.Websocket(_websocket) -> Ok(#([], 0, []))
  }
}

fn send_response(
  state: State,
  stream_id: Int,
  stream: Stream,
  status: Int,
  response_headers: List(#(String, String)),
  pieces: List(outbox.Piece),
  length: ContentLength,
) -> State {
  case response_fields(status, response_headers, length, clock.get()) {
    Error(UnsafeHeader(name)) -> {
      log_unsafe_header(name)

      state
      |> close_files(stream.files)
      |> send_response(
        stream_id,
        Stream(..stream, files: []),
        500,
        [],
        [],
        Length(0),
      )
    }
    Ok(fields) -> {
      let outbox =
        list.fold(pieces, outbox.new(), outbox.push)
        |> outbox.finish

      case outbox.size(outbox) {
        0 ->
          state
          |> emit_headers(stream_id, fields, True)
          |> close_files(stream.files)
          |> settle(stream_id, Stream(..stream, outbound: Responded, files: []))
        _size ->
          state
          |> emit_headers(stream_id, fields, False)
          |> send_now(stream_id, Stream(..stream, outbound: Responding(outbox)))
      }
    }
  }
}

fn start_streaming(
  state: State,
  stream_id: Int,
  stream: Stream,
  status: Int,
  response_headers: List(#(String, String)),
  signals: Option(Subject(http2.StreamSignal)),
  ack: Subject(http2.WriteAck),
) -> State {
  let length = content_length(stream, status, Unknown)

  case response_fields(status, response_headers, length, clock.get()) {
    Error(UnsafeHeader(name)) -> {
      log_unsafe_header(name)

      refuse_write(state, ack)
      |> reset(stream_id, frame.InternalError)
    }
    Ok(fields) -> {
      process.send(ack, http2.Written)

      case state.lifecycle, signals {
        Serving, _signals | _lifecycle, None -> Nil
        _lifecycle, Some(signals) -> process.send(signals, http2.Draining)
      }

      state
      |> emit_headers(stream_id, fields, False)
      |> settle(
        stream_id,
        Stream(..stream, outbound: Responding(outbox.new()), signals:),
      )
    }
  }
}

fn log_unsafe_header(name: String) -> Nil {
  logging.log(
    logging.Error,
    "Handler produced an unsafe response header: " <> name,
  )
}

fn queue_data(
  state: State,
  stream_id: Int,
  stream: Stream,
  outbox: Outbox,
  data: BitArray,
  end_stream: Bool,
  ack: Subject(http2.WriteAck),
) -> State {
  let outbox = outbox.push(outbox, outbox.bytes(data))
  let outbox = case end_stream {
    True -> outbox.finish(outbox)
    False -> outbox
  }

  Stream(..stream, outbound: Responding(outbox), held_ack: Some(ack))
  |> release_ack(state.options)
  |> send_now(state, stream_id, _)
}

fn release_ack(stream: Stream, options: http2.Options) -> Stream {
  let queued = case stream.outbound {
    Responding(outbox) -> outbox.size(outbox)
    AwaitingResponse | Responded -> 0
  }

  case stream.held_ack {
    Some(ack) if queued <= options.send_buffer_limit -> {
      process.send(ack, http2.Written)
      Stream(..stream, held_ack: None)
    }
    Some(_ack) | None -> stream
  }
}

fn handle_exit(state: State, exit: process.ExitMessage) -> Result(State, Halt) {
  case state.parent == Ok(exit.pid), exit.reason {
    True, process.Abnormal(reason) ->
      case http2.is_shutdown(reason) {
        True -> Ok(begin_shutdown(state))
        False -> Error(Quit(state))
      }
    True, process.Normal | True, process.Killed -> Error(Quit(state))
    False, _reason -> Ok(worker_exited(state, exit.pid))
  }
}

fn worker_exited(state: State, pid: Pid) -> State {
  case dict.get(state.workers, pid) {
    Error(Nil) -> state
    Ok(stream_id) -> {
      let state = State(..state, workers: dict.delete(state.workers, pid))

      case dict.get(state.streams, stream_id) {
        Ok(Stream(worker: Some(worker), ..) as stream) if worker == pid -> {
          let stream =
            Stream(..stream, worker: None, held_ack: None, signals: None)
          let unfinished = case stream.outbound {
            AwaitingResponse -> True
            Responding(outbox) -> !outbox.is_finished(outbox)
            Responded -> False
          }

          case unfinished, stream.tunnel {
            True, True -> abort(state, stream_id, stream, frame.Cancel)
            True, False -> abort(state, stream_id, stream, frame.InternalError)
            False, _tunnel -> settle(state, stream_id, stream)
          }
        }
        Ok(_stream) | Error(Nil) -> state
      }
    }
  }
}

fn abort(
  state: State,
  stream_id: Int,
  stream: Stream,
  error: ErrorCode,
) -> State {
  State(..state, streams: dict.insert(state.streams, stream_id, stream))
  |> reset(stream_id, error)
}

fn kill_worker(state: State, pid: Pid) -> State {
  case dict.has_key(state.workers, pid) {
    True -> process.kill(pid)
    False -> Nil
  }
  state
}

fn schedule(state: State, stream_id: Int, stream: Stream) -> State {
  let sendable = case stream.outbound {
    Responding(outbox) ->
      case outbox.size(outbox) {
        0 -> outbox.is_finished(outbox)
        _size -> stream.send_window > 0
      }
    AwaitingResponse | Responded -> False
  }

  case sendable && !stream.scheduled {
    True ->
      State(
        ..state,
        ready: queue.push(state.ready, stream_id),
        streams: dict.insert(
          state.streams,
          stream_id,
          Stream(..stream, scheduled: True),
        ),
      )
    False -> settle(state, stream_id, stream)
  }
}

fn send_now(state: State, stream_id: Int, stream: Stream) -> State {
  case queue.is_empty(state.ready), stream.outbound {
    True, Responding(outbox) ->
      case send_data(state, stream_id, stream, outbox) {
        Sent(state, _size) -> state
        ConnectionBlocked | StreamBlocked -> schedule(state, stream_id, stream)
      }
    _ready, _outbound -> schedule(state, stream_id, stream)
  }
}

fn transmit(state: State, budget: Int) -> State {
  case budget <= 0, queue.pop(state.ready) {
    _exhausted, Error(Nil) -> state
    True, Ok(_ready) -> resume_later(state)
    False, Ok(#(stream_id, ready)) -> {
      let state = State(..state, ready:)

      case dict.get(state.streams, stream_id) {
        Ok(Stream(outbound: Responding(outbox), ..) as stream) -> {
          let stream = Stream(..stream, scheduled: False)

          case send_data(state, stream_id, stream, outbox) {
            Sent(state, size) -> transmit(state, budget - size)
            ConnectionBlocked ->
              State(
                ..state,
                ready: queue.push_front(state.ready, stream_id),
                streams: dict.insert(
                  state.streams,
                  stream_id,
                  Stream(..stream, scheduled: True),
                ),
              )
            StreamBlocked ->
              State(
                ..state,
                streams: dict.insert(state.streams, stream_id, stream),
              )
              |> transmit(budget)
          }
        }
        Ok(_stream) | Error(Nil) -> transmit(state, budget)
      }
    }
  }
}

type Transmitted {
  Sent(State, size: Int)
  ConnectionBlocked
  StreamBlocked
}

fn send_data(
  state: State,
  stream_id: Int,
  stream: Stream,
  outbox: Outbox,
) -> Transmitted {
  let limit =
    state.send_window
    |> int.min(stream.send_window)
    |> int.min(state.peer_max_frame_size)

  case outbox.size(outbox), outbox.is_finished(outbox) {
    0, True ->
      state
      |> emit(frame.data_header(stream_id, True, 0))
      |> finish_response(stream_id, stream)
      |> Sent(0)
    0, False -> StreamBlocked
    _size, _finished if stream.send_window <= 0 -> StreamBlocked
    _size, _finished if limit <= 0 -> ConnectionBlocked
    _size, _finished ->
      case outbox.take(outbox, limit, file.read) {
        Error(_file_error) -> {
          logging.log(
            logging.Error,
            "Could not read the file of an HTTP/2 response",
          )
          Sent(abort(state, stream_id, stream, frame.InternalError), 0)
        }
        Ok(#(piece, last, outbox)) -> {
          let size = outbox.piece_size(piece)
          let state =
            State(..state, send_window: state.send_window - size)
            |> emit(frame.data_header(stream_id, last, size))
            |> emit_piece(piece)
          let stream =
            Stream(
              ..stream,
              outbound: Responding(outbox),
              send_window: stream.send_window - size,
            )
            |> release_ack(state.options)

          case last {
            True -> finish_response(state, stream_id, stream)
            False -> schedule(state, stream_id, stream)
          }
          |> Sent(size)
        }
      }
  }
}

fn finish_response(state: State, stream_id: Int, stream: Stream) -> State {
  state
  |> close_files(stream.files)
  |> settle(
    stream_id,
    Stream(..stream, outbound: Responded, files: [], held_ack: None),
  )
}

fn hold_output(state: State) -> Bool {
  state.output_size > 0
  && state.output_size < cork_limit
  && message_queue_length() > 0
}

fn resume_later(state: State) -> State {
  case state.resuming {
    True -> state
    False -> {
      process.send(state.self, connection.Http2Resume)
      State(..state, resuming: True)
    }
  }
}

pub type ContentLength {
  Length(Int)
  Unknown
  Omitted
}

pub type UnsafeHeader {
  UnsafeHeader(name: String)
}

pub fn response_fields(
  status: Int,
  headers: List(#(String, String)),
  content_length: ContentLength,
  date: BitArray,
) -> Result(List(alpacki.HeaderField), UnsafeHeader) {
  use fields <- result.map(
    list.try_fold(headers, [], fn(fields, header) {
      case header.0, content_length {
        ":" <> _name, _length
        | "connection", _length
        | "keep-alive", _length
        | "proxy-connection", _length
        | "transfer-encoding", _length
        | "upgrade", _length
        | "te", _length
        | "date", _length
        | "content-length", Length(_length)
        | "content-length", Omitted
        -> Ok(fields)
        name, _length ->
          case
            find_unsafe_header_byte(name),
            find_unsafe_header_byte(header.1)
          {
            Error(Nil), Error(Nil) ->
              Ok([response_field(name, header.1), ..fields])
            _name, _value -> Error(UnsafeHeader(name))
          }
      }
    }),
  )

  let fields = list.reverse(fields)

  let fields = case content_length {
    Length(length) -> [
      response_field("content-length", int.to_string(length)),
      ..fields
    ]
    Unknown | Omitted -> fields
  }

  [
    response_field(":status", int.to_string(status)),
    alpacki.HeaderField(<<"date":utf8>>, date, alpacki.WithIndexing),
    ..fields
  ]
}

fn response_field(name: String, value: String) -> alpacki.HeaderField {
  let indexing = case name {
    ":status"
    | "accept-ranges"
    | "access-control-allow-credentials"
    | "access-control-allow-headers"
    | "access-control-allow-methods"
    | "access-control-allow-origin"
    | "access-control-expose-headers"
    | "access-control-max-age"
    | "allow"
    | "cache-control"
    | "content-encoding"
    | "content-language"
    | "content-security-policy"
    | "content-type"
    | "cross-origin-embedder-policy"
    | "cross-origin-opener-policy"
    | "cross-origin-resource-policy"
    | "link"
    | "location"
    | "permissions-policy"
    | "referrer-policy"
    | "server"
    | "strict-transport-security"
    | "trailer"
    | "vary"
    | "x-content-type-options"
    | "x-frame-options"
    | "x-xss-protection" -> alpacki.WithIndexing
    "set-cookie" -> alpacki.NeverIndexed
    _name -> alpacki.WithoutIndexing
  }

  alpacki.HeaderField(<<name:utf8>>, <<value:utf8>>, indexing)
}

@external(erlang, "ewe_ffi", "find_unsafe_header_byte")
fn find_unsafe_header_byte(value: String) -> Result(Int, Nil)

fn emit_headers(
  state: State,
  stream_id: Int,
  fields: List(alpacki.HeaderField),
  end_stream: Bool,
) -> State {
  let #(block, encoder) =
    alpacki.encode_header_block(fields, state.encoder, True)
  let max_frame_size = state.peer_max_frame_size

  let frames = case block {
    <<fragment:bytes-size(max_frame_size), rest:bits>> if rest != <<>> -> <<
      frame.encode(frame.Headers(
        stream_id:,
        end_stream:,
        end_headers: False,
        dependency: None,
        fragment:,
      )):bits,
      continuation_frames(stream_id, rest, max_frame_size):bits,
    >>
    _block ->
      frame.encode(frame.Headers(
        stream_id:,
        end_stream:,
        end_headers: True,
        dependency: None,
        fragment: block,
      ))
  }

  emit(State(..state, encoder:), frames)
}

fn continuation_frames(
  stream_id: Int,
  block: BitArray,
  max_frame_size: Int,
) -> BitArray {
  case block {
    <<fragment:bytes-size(max_frame_size), rest:bits>> if rest != <<>> -> <<
      frame.encode(frame.Continuation(stream_id:, end_headers: False, fragment:)):bits,
      continuation_frames(stream_id, rest, max_frame_size):bits,
    >>
    _block ->
      frame.encode(frame.Continuation(
        stream_id:,
        end_headers: True,
        fragment: block,
      ))
  }
}

fn emit(state: State, bits: BitArray) -> State {
  let output = case state.output {
    [Frames(frames), ..output] -> [
      Frames(bytes_tree.append(frames, bits)),
      ..output
    ]
    output -> [Frames(bytes_tree.from_bit_array(bits)), ..output]
  }

  State(
    ..state,
    output:,
    output_size: state.output_size + bit_array.byte_size(bits),
  )
}

fn emit_piece(state: State, piece: outbox.Piece) -> State {
  let #(output, size) = case piece, state.output {
    outbox.Bytes(bytes:, size:), [Frames(frames), ..output] -> #(
      [Frames(bytes_tree.append_tree(frames, bytes)), ..output],
      size,
    )
    outbox.Bytes(bytes:, size:), output -> #([Frames(bytes), ..output], size)
    outbox.File(descriptor:, offset:, length:), output -> #(
      [SendFile(descriptor:, offset:, length:), ..output],
      length,
    )
  }

  State(..state, output:, output_size: state.output_size + size)
}

fn close_files(state: State, files: List(connection.FileDescriptor)) -> State {
  let output =
    list.fold(files, state.output, fn(output, descriptor) {
      [CloseFile(descriptor), ..output]
    })

  State(..state, output:)
}

fn write(state: State, connection: tup.Connection) -> Result(State, Nil) {
  let #(transport, socket) = tup.socket(connection)

  list.reverse(state.output)
  |> list.try_each(fn(segment) {
    case segment {
      Frames(frames) ->
        tup.send(connection, frames) |> result.replace_error(Nil)
      SendFile(descriptor:, offset:, length:) ->
        file.send_chunk(transport, socket, descriptor, offset, length)
        |> result.replace_error(Nil)
      CloseFile(descriptor) -> Ok(file.close(descriptor))
    }
  })
  |> result.replace(State(..state, output: [], output_size: 0))
}

fn begin_shutdown(state: State) -> State {
  case state.lifecycle {
    Announcing | Closing(..) -> state
    Serving -> {
      dict.each(state.streams, fn(_stream_id, stream) {
        case stream.signals {
          Some(signals) -> process.send(signals, http2.Draining)
          None -> Nil
        }
      })

      process.send_after(
        state.self,
        state.options.drain_timeout_ms,
        connection.Http2DrainTimeout,
      )

      State(..state, lifecycle: Announcing)
      |> emit(
        frame.encode(
          frame.Goaway(
            last_stream_id: max_stream_id,
            error: frame.NoError,
            debug: <<>>,
          ),
        ),
      )
      |> emit(frame.encode(frame.Ping(ack: False, data: shutdown_ping)))
    }
  }
}

fn idle_timeout(state: State) -> Result(State, Halt) {
  let idle_for = monotonic_ms() - state.last_activity
  let timeout = state.options.idle_timeout_ms
  let quiet = dict.is_empty(state.streams) && dict.is_empty(state.workers)

  case quiet && idle_for >= timeout {
    True -> Error(Fail(state, frame.NoError))
    False -> {
      let wait = case quiet {
        True -> timeout - idle_for
        False -> timeout
      }
      process.send_after(state.self, wait, connection.Http2IdleTimeout)
      Ok(state)
    }
  }
}

fn stop(state: State) -> Next {
  stop_workers(state)
  Close
}

pub fn stop_workers(state: State) -> Nil {
  use pid, _stream_id <- dict.each(state.workers)
  process.send_abnormal_exit(pid, "connection_closed")
}

@external(erlang, "ewe_ffi", "message_queue_length")
fn message_queue_length() -> Int

@external(erlang, "ewe_ffi", "monotonic_ms")
fn monotonic_ms() -> Int
