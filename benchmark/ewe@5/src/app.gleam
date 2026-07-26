import ewe
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/option
import logging

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Debug)

  let listener_name = process.new_name("listener_name")
  let connection_factory_name = process.new_name("connection_factory_name")

  let assert Ok(_started) =
    ewe.new(listener_name:, connection_factory_name:, handler: handle_request)
    |> ewe.listening(on: 3006)
    |> ewe.start

  process.sleep_forever()
}

fn handle_request(
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
      let writer = ewe.send_chunk(writer, <<"hello, ":utf8>>)
      ewe.finish_chunk(writer, <<"Joe!":utf8>>)
    }
    http.Get, "/sse" -> sse_burst()
    http.Get, "/file/small" -> {
      // head -c 100K /dev/urandom > file_100kb.bin
      let assert Ok(file) =
        ewe.file(
          "../priv/file_100kb.bin",
          offset: option.None,
          limit: option.None,
        )

      response.Response(
        status: 200,
        headers: [#("content-type", "application/octet-stream")],
        body: file,
      )
    }
    http.Get, "/file/big" -> {
      // head -c 1G /dev/urandom > file_1gb.bin
      let assert Ok(file) =
        ewe.file(
          "../priv/file_1gb.bin",
          offset: option.None,
          limit: option.None,
        )

      response.Response(
        status: 200,
        headers: [#("content-type", "application/octet-stream")],
        body: file,
      )
    }
    _method, _path ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
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

const sse_events = 32

type Tick {
  Tick(Int)
}

fn sse_burst() -> response.Response(ewe.Body) {
  ewe.sse(
    response.new(200),
    on_init: fn(subject) {
      process.send(subject, Tick(1))
      subject
    },
    handler: fn(conn, subject, message) {
      let Tick(n) = message

      case ewe.send_event(conn, tick_event(n)) {
        Error(_reason) -> ewe.sse_stop_abnormal("failed to send event")
        Ok(Nil) if n >= sse_events -> ewe.sse_stop()
        Ok(Nil) -> {
          process.send(subject, Tick(n + 1))
          ewe.sse_continue(subject)
        }
      }
    },
    on_close: fn(_conn, _state) { Nil },
  )
}

fn tick_event(n: Int) -> ewe.SseEvent {
  let n = int.to_string(n)

  ewe.event("{\"n\":" <> n <> ",\"at\":\"benchmark\"}")
  |> ewe.event_name("tick")
  |> ewe.event_id(n)
}
