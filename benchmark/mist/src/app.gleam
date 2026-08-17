import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option
import gleam/otp/actor
import gleam/string
import gleam/string_tree
import logging
import mist

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Debug)

  let payload = payload()

  let assert Ok(_started) =
    mist.new(handle_request(payload, _))
    |> mist.port(3002)
    |> mist.start

  process.sleep_forever()
}

const sse_events = 32

const small_count = 100

const big_count = 64

const big_repeats = 256

const small_line = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

type Payload {
  Payload(small: BitArray, big: BitArray, big_line: String)
}

fn payload() -> Payload {
  let big_line = string.repeat(small_line, big_repeats)

  Payload(
    small: bit_array.from_string(small_line),
    big: bit_array.from_string(big_line),
    big_line:,
  )
}

fn handle_request(
  payload: Payload,
  request: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case request.method, request.path {
    http.Get, "/hello" ->
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Hello, Joe!")))
    http.Post, "/echo" ->
      case mist.read_body(request, 10_000_000) {
        Ok(req) ->
          response.new(200)
          |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(req.body)))
        Error(_error) ->
          response.new(400) |> response.set_body(mist.Bytes(bytes_tree.new()))
      }
    http.Post, "/echo/chunked" -> echo_chunked(request)
    http.Get, "/stream" -> stream_hello(request)
    http.Get, "/stream/small" ->
      stream_burst(request, payload.small, small_count)
    http.Get, "/stream/big" -> stream_burst(request, payload.big, big_count)
    http.Get, "/sse" -> sse_burst(request, small_line, sse_events)
    http.Get, "/sse/small" -> sse_burst(request, small_line, small_count)
    http.Get, "/sse/big" -> sse_burst(request, payload.big_line, big_count)
    http.Get, "/file/tiny" -> file("../priv/file_1kb.bin")
    http.Get, "/file/small" -> file("../priv/file_100kb.bin")
    http.Get, "/file/big" -> file("../priv/file_5mb.bin")
    _method, _path ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn file(path: String) -> response.Response(mist.ResponseData) {
  let assert Ok(file) = mist.send_file(path, offset: 0, limit: option.None)

  response.Response(
    status: 200,
    headers: [#("content-type", "application/octet-stream")],
    body: file,
  )
}

fn echo_chunked(
  request: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let failed =
    response.new(400) |> response.set_body(mist.Bytes(bytes_tree.new()))

  case mist.stream(request) {
    Ok(consume) ->
      case consume_chunks(consume, bytes_tree.new()) {
        Ok(body) -> response.new(200) |> response.set_body(mist.Bytes(body))
        Error(Nil) -> failed
      }
    Error(_reason) -> failed
  }
}

fn consume_chunks(
  consume: fn(Int) -> Result(mist.Chunk, mist.ReadError),
  acc: bytes_tree.BytesTree,
) -> Result(bytes_tree.BytesTree, Nil) {
  case consume(4096) {
    Ok(mist.Chunk(data, consume)) ->
      consume_chunks(consume, bytes_tree.append(acc, data))
    Ok(mist.Done) -> Ok(acc)
    Error(_reason) -> Error(Nil)
  }
}

type StreamMessage {
  StreamChunk(data: BitArray)
  StreamDone
}

fn stream_hello(
  request: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  mist.chunked(
    request:,
    response: response.new(200),
    init: fn(subject: Subject(StreamMessage)) {
      process.send(subject, StreamChunk(bit_array.from_string("hello, ")))
      process.send(subject, StreamChunk(bit_array.from_string("Joe!")))
      process.send(subject, StreamDone)
      Nil
    },
    loop: fn(state, message, connection) {
      case message {
        StreamChunk(data) -> {
          let assert Ok(Nil) = mist.send_chunk(connection, data)
          mist.chunk_continue(state)
        }
        StreamDone -> mist.chunk_stop()
      }
    },
  )
}

type Tick {
  Tick(Int)
}

fn stream_burst(
  request: request.Request(mist.Connection),
  chunk: BitArray,
  count: Int,
) -> response.Response(mist.ResponseData) {
  mist.chunked(
    request:,
    response: response.new(200),
    init: fn(subject: Subject(Tick)) {
      process.send(subject, Tick(1))
      subject
    },
    loop: fn(subject, message, connection) {
      let Tick(n) = message

      case mist.send_chunk(connection, chunk) {
        Error(Nil) -> mist.chunk_stop()
        Ok(Nil) if n >= count -> mist.chunk_stop()
        Ok(Nil) -> {
          process.send(subject, Tick(n + 1))
          mist.chunk_continue(subject)
        }
      }
    },
  )
}

fn sse_burst(
  request: request.Request(mist.Connection),
  data: String,
  count: Int,
) -> response.Response(mist.ResponseData) {
  mist.server_sent_events(
    request:,
    initial_response: response.new(200),
    init: fn(subject: Subject(Tick)) {
      process.send(subject, Tick(1))
      subject
    },
    loop: fn(subject, message, connection) {
      let Tick(n) = message

      case mist.send_event(connection, tick_event(data)) {
        Error(Nil) -> actor.stop()
        Ok(Nil) if n >= count -> actor.stop()
        Ok(Nil) -> {
          process.send(subject, Tick(n + 1))
          actor.continue(subject)
        }
      }
    },
  )
}

fn tick_event(data: String) -> mist.SSEEvent {
  string_tree.from_string(data)
  |> mist.event
  |> mist.event_name("tick")
}
