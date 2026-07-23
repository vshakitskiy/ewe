import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option
import logging
import mist

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Debug)

  let assert Ok(_started) =
    mist.new(handle_request)
    |> mist.port(3002)
    |> mist.start

  process.sleep_forever()
}

fn handle_request(
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
    http.Get, "/file/small" -> {
      // head -c 100K /dev/urandom > file_100kb.bin
      let assert Ok(file) =
        mist.send_file(
          "../priv/file_100kb.bin",
          offset: 0,
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
        mist.send_file(
          "../priv/file_1gb.bin",
          offset: 0,
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
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
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
