import ewe
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option
import gleam/string
import logging

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Debug)

  let payload = payload()

  let assert Ok(_started) =
    ewe.new(handle_request(payload, _))
    |> ewe.listening(port: 3001)
    |> ewe.start

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
  request: request.Request(ewe.Connection),
) -> response.Response(ewe.ResponseBody) {
  case request.method, request.path {
    http.Get, "/hello" ->
      response.new(200)
      |> response.set_body(ewe.TextData("Hello, Joe!"))
    http.Post, "/echo" ->
      case ewe.read_body(request, 10_000_000) {
        Ok(req) ->
          response.new(200)
          |> response.set_body(ewe.BitsData(req.body))
        Error(_error) -> response.new(400) |> response.set_body(ewe.Empty)
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
      |> response.set_body(ewe.Empty)
  }
}

fn file(path: String) -> response.Response(ewe.ResponseBody) {
  let assert Ok(file) = ewe.file(path, offset: option.None, limit: option.None)

  response.Response(
    status: 200,
    headers: [#("content-type", "application/octet-stream")],
    body: file,
  )
}

fn echo_chunked(
  request: request.Request(ewe.Connection),
) -> response.Response(ewe.ResponseBody) {
  let failed = response.new(400) |> response.set_body(ewe.Empty)

  case ewe.stream_body(request) {
    Ok(consumer) ->
      case consume_chunks(consumer, bytes_tree.new()) {
        Ok(body) -> response.new(200) |> response.set_body(ewe.BytesData(body))
        Error(Nil) -> failed
      }
    Error(_reason) -> failed
  }
}

fn consume_chunks(
  consumer: ewe.Consumer,
  acc: bytes_tree.BytesTree,
) -> Result(bytes_tree.BytesTree, Nil) {
  case consumer(4096) {
    Ok(ewe.Consumed(data, next)) ->
      consume_chunks(next, bytes_tree.append(acc, data))
    Ok(ewe.Done) -> Ok(acc)
    Error(_reason) -> Error(Nil)
  }
}

type StreamMessage {
  StreamChunk(data: BitArray)
  StreamDone
}

fn stream_hello(
  request: request.Request(ewe.Connection),
) -> response.Response(ewe.ResponseBody) {
  ewe.chunked_body(
    request,
    response.new(200),
    on_init: fn(subject: Subject(StreamMessage)) {
      process.send(subject, StreamChunk(bit_array.from_string("hello, ")))
      process.send(subject, StreamChunk(bit_array.from_string("Joe!")))
      process.send(subject, StreamDone)
      Nil
    },
    handler: fn(conn, state, message) {
      case message {
        StreamChunk(data) ->
          case ewe.send_chunk(conn, data) {
            Ok(Nil) -> ewe.chunked_continue(state)
            Error(_reason) -> ewe.chunked_stop_abnormal("failed to send chunk")
          }
        StreamDone -> ewe.chunked_stop()
      }
    },
    on_close: fn(_conn, _state) { Nil },
  )
}

type Tick {
  Tick(Int)
}

fn stream_burst(
  request: request.Request(ewe.Connection),
  chunk: BitArray,
  count: Int,
) -> response.Response(ewe.ResponseBody) {
  ewe.chunked_body(
    request,
    response.new(200),
    on_init: fn(subject: Subject(Tick)) {
      process.send(subject, Tick(1))
      subject
    },
    handler: fn(conn, subject, message) {
      let Tick(n) = message

      case ewe.send_chunk(conn, chunk) {
        Error(_reason) -> ewe.chunked_stop_abnormal("failed to send chunk")
        Ok(Nil) if n >= count -> ewe.chunked_stop()
        Ok(Nil) -> {
          process.send(subject, Tick(n + 1))
          ewe.chunked_continue(subject)
        }
      }
    },
    on_close: fn(_conn, _state) { Nil },
  )
}

fn sse_burst(
  request: request.Request(ewe.Connection),
  data: String,
  count: Int,
) -> response.Response(ewe.ResponseBody) {
  ewe.sse(
    request,
    on_init: fn(subject) {
      process.send(subject, Tick(1))
      subject
    },
    handler: fn(conn, subject, message) {
      let Tick(n) = message

      case ewe.send_event(conn, ewe.event(data) |> ewe.event_name("tick")) {
        Error(_reason) -> ewe.sse_stop_abnormal("failed to send event")
        Ok(Nil) if n >= count -> ewe.sse_stop()
        Ok(Nil) -> {
          process.send(subject, Tick(n + 1))
          ewe.sse_continue(subject)
        }
      }
    },
    on_close: fn(_conn, _state) { Nil },
  )
}
