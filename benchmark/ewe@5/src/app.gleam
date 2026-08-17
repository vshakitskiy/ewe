import ewe
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option
import gleam/result
import gleam/string
import logging

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Debug)

  let listener_name = process.new_name("listener_name")
  let connection_factory_name = process.new_name("connection_factory_name")
  let payload = payload()
  let handler = handle_request(payload, _)

  let assert Ok(_started) =
    ewe.new(listener_name:, connection_factory_name:, handler:)
    |> ewe.listening(on: 3006)
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
) -> response.Response(ewe.Body) {
  case request.method, request.path {
    http.Get, "/hello" ->
      response.new(200)
      |> response.set_body(ewe.Text("Hello, Joe!"))
    http.Post, "/echo" ->
      case ewe.read_body(request, 10_000_000) {
        Ok(req) ->
          response.new(200)
          |> response.set_body(ewe.Bytes(bytes_tree.from_bit_array(req.body)))
        Error(_error) -> response.new(400) |> response.set_body(ewe.Empty)
      }
    http.Post, "/echo/chunked" -> echo_chunked(request, bytes_tree.new())
    http.Get, "/stream" -> {
      use writer <- ewe.stream_response(response.new(200))
      use writer <- result.try(ewe.send_chunk(writer, <<"hello, ":utf8>>))
      ewe.finish_chunk(writer, <<"Joe!":utf8>>)
    }
    http.Get, "/stream/small" -> stream_burst(payload.small, small_count)
    http.Get, "/stream/big" -> stream_burst(payload.big, big_count)
    http.Get, "/sse" -> sse_burst(small_line, sse_events)
    http.Get, "/sse/small" -> sse_burst(small_line, small_count)
    http.Get, "/sse/big" -> sse_burst(payload.big_line, big_count)
    http.Get, "/file/tiny" -> file(request, "../priv/file_1kb.bin")
    http.Get, "/file/small" -> file(request, "../priv/file_100kb.bin")
    http.Get, "/file/big" -> file(request, "../priv/file_5mb.bin")
    _method, _path ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}

fn file(
  request: request.Request(ewe.Connection),
  path: String,
) -> response.Response(ewe.Body) {
  let assert Ok(file) =
    ewe.file(request.body, path, offset: option.None, limit: option.None)

  response.Response(
    status: 200,
    headers: [#("content-type", "application/octet-stream")],
    body: file,
  )
}

fn echo_chunked(
  request: request.Request(ewe.Connection),
  acc: bytes_tree.BytesTree,
) -> response.Response(ewe.Body) {
  case ewe.read_body_chunk(request, max_chunk_bytes: 4096, limit: 10_000_000) {
    Ok(ewe.Chunk(data, request)) ->
      echo_chunked(request, bytes_tree.append(acc, data))
    Ok(ewe.Done(_request)) ->
      response.new(200) |> response.set_body(ewe.Bytes(acc))
    Error(_error) -> response.new(400) |> response.set_body(ewe.Empty)
  }
}

fn stream_burst(chunk: BitArray, count: Int) -> response.Response(ewe.Body) {
  use writer <- ewe.stream_response(response.new(200))
  stream_chunks(writer, chunk, count)
}

fn stream_chunks(
  writer: ewe.ResponseWriter,
  chunk: BitArray,
  remaining: Int,
) -> Result(Nil, ewe.SendError) {
  case remaining {
    1 -> ewe.finish_chunk(writer, chunk)
    _remaining -> {
      use writer <- result.try(ewe.send_chunk(writer, chunk))
      stream_chunks(writer, chunk, remaining - 1)
    }
  }
}

type Tick {
  Tick(Int)
}

fn sse_burst(data: String, count: Int) -> response.Response(ewe.Body) {
  ewe.sse(
    response.new(200),
    on_init: fn(subject) {
      process.send(subject, Tick(1))
      subject
    },
    handler: fn(conn, subject, message) {
      let Tick(n) = message

      case ewe.send_event(conn, ewe.event(data) |> ewe.event_name("tick")) {
        Error(_reason) -> ewe.sse_stop()
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
