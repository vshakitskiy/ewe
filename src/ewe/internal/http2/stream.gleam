import ewe/internal/connection
import ewe/internal/http2/connection as http2
import ewe/internal/rescue
import gleam/erlang/process
import gleam/erlang/reference
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/result
import logging

pub fn start(
  reply_to: process.Subject(http2.Reply(connection.Body)),
  stream_id: Int,
  request: request.Request(connection.Connection),
  handler: fn(request.Request(connection.Connection)) ->
    response.Response(connection.Body),
) -> process.Pid {
  use <- process.spawn

  process.trap_exits(True)

  case rescue.handler(fn() { handler(request) }) {
    Ok(response) -> deliver(reply_to, stream_id, response, request.method)
    Error(details) -> crashed(reply_to, stream_id, details)
  }
}

fn crashed(
  reply_to: process.Subject(http2.Reply(connection.Body)),
  stream_id: Int,
  details: String,
) -> Nil {
  logging.log(logging.Error, "Caught a crash in the handler: " <> details)

  internal_error(reply_to, stream_id)
}

fn internal_error(
  reply_to: process.Subject(http2.Reply(connection.Body)),
  stream_id: Int,
) -> Nil {
  response.new(500)
  |> response.set_body(connection.Empty)
  |> http2.Respond(stream_id, _)
  |> process.send(reply_to, _)
}

fn deliver(
  reply_to: process.Subject(http2.Reply(connection.Body)),
  stream_id: Int,
  response: response.Response(connection.Body),
  method: http.Method,
) -> Nil {
  case response.body, method {
    connection.Websocket(_metadata), _method -> {
      logging.log(
        logging.Error,
        "Discarded a WebSocket response: HTTP/2 connections do not carry them",
      )

      internal_error(reply_to, stream_id)
    }
    _body, http.Head ->
      process.send(reply_to, http2.Respond(stream_id, response))
    connection.Streaming(connection.StreamingMetadata(handler:)), _method ->
      case begin(reply_to, stream_id, response, http2.Nothing) {
        Error(_interrupted) -> Nil
        Ok(writer) -> handler(connection.Http2Writer(writer))
      }
    connection.Sse(connection.SseMetadata(handler:)), _method ->
      case begin(reply_to, stream_id, response, http2.SseHeaders) {
        Error(_interrupted) -> Nil
        Ok(writer) ->
          case handler(connection.Http2Sse(http2.SseConnection(writer))) {
            connection.Stopped -> Nil
            connection.StoppedAbnormal(reason) -> abort(reason)
          }
      }
    connection.Bytes(_tree), _method
    | connection.Text(_text), _method
    | connection.Empty, _method
    | connection.File(_file), _method
    -> process.send(reply_to, http2.Respond(stream_id, response))
  }
}

fn begin(
  reply_to: process.Subject(http2.Reply(connection.Body)),
  stream_id: Int,
  response: response.Response(connection.Body),
  reserved: http2.Reserved,
) -> Result(http2.ResponseWriter(connection.Body), http2.Interrupted) {
  let ack_ref = reference.new()
  let ack = process.unsafely_create_subject(process.self(), http2.tag(ack_ref))

  process.send(
    reply_to,
    http2.WriteHeaders(
      stream_id:,
      ack:,
      status: response.status,
      headers: response.headers,
      reserved:,
    ),
  )

  use _written <- result.map(http2.receive_reply(ack_ref))
  http2.ResponseWriter(connection: reply_to, stream_id:, ack:, ack_ref:)
}

pub fn send_chunk(
  writer: http2.ResponseWriter(connection.Body),
  chunk: BitArray,
) -> Result(http2.ResponseWriter(connection.Body), http2.Interrupted) {
  case chunk {
    <<>> -> Ok(writer)
    _chunk -> write(writer, chunk, False)
  }
}

pub fn finish_chunk(
  writer: http2.ResponseWriter(connection.Body),
  chunk: BitArray,
) -> Result(Nil, http2.Interrupted) {
  write(writer, chunk, True) |> result.replace(Nil)
}

pub fn finish_response(
  writer: http2.ResponseWriter(connection.Body),
) -> Result(Nil, http2.Interrupted) {
  finish_chunk(writer, <<>>)
}

fn write(
  writer: http2.ResponseWriter(connection.Body),
  chunk: BitArray,
  end_stream: Bool,
) -> Result(http2.ResponseWriter(connection.Body), http2.Interrupted) {
  process.send(
    writer.connection,
    http2.WriteData(
      stream_id: writer.stream_id,
      ack: writer.ack,
      chunk:,
      end_stream:,
    ),
  )

  use _written <- result.map(http2.receive_reply(writer.ack_ref))
  writer
}

@external(erlang, "ewe_http2_ffi", "exit_self")
fn abort(reason: String) -> a
