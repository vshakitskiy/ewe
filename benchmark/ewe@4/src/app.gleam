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

  let assert Ok(_started) =
    ewe.new(handle_request)
    |> ewe.listening(port: 3001)
    |> ewe.start

  process.sleep_forever()
}

fn handle_request(
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
        StreamChunk(data) -> {
          case ewe.send_chunk(conn, data) {
            Ok(Nil) -> ewe.chunked_continue(state)
            Error(reason) ->
              ewe.chunked_stop_abnormal(
                "Failed to send chunk: " <> string.inspect(reason),
              )
          }
        }
        StreamDone -> ewe.chunked_stop()
      }
    },
    on_close: fn(_conn, _state) { Nil },
  )
}
