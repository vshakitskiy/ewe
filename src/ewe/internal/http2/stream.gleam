import ewe/internal/connection
import ewe/internal/http2/connection as http2
import ewe/internal/rescue
import gleam/erlang/process
import gleam/erlang/reference
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option
import gleam/result
import logging

pub fn start(
  reply_to: process.Subject(http2.Reply(connection.Body)),
  stream_id: Int,
  request: request.Request(connection.Connection),
  handler: connection.Handler,
) -> process.Pid {
  use <- process.spawn

  process.trap_exits(True)

  case rescue.handler(fn() { handler.call(request) }) {
    Ok(response) -> deliver(reply_to, stream_id, response, request.method)
    Error(details) -> crashed(reply_to, stream_id, handler.on_crash, details)
  }
}

fn crashed(
  reply_to: process.Subject(http2.Reply(connection.Body)),
  stream_id: Int,
  on_crash: response.Response(connection.Body),
  details: String,
) -> Nil {
  logging.log(logging.Error, "Caught a crash in the handler: " <> details)

  process.send(reply_to, http2.Respond(stream_id, on_crash))
}

fn deliver(
  reply_to: process.Subject(http2.Reply(connection.Body)),
  stream_id: Int,
  response: response.Response(connection.Body),
  method: http.Method,
) -> Nil {
  case response.body, method {
    connection.Websocket(connection.WebsocketMetadata(context:, handler:)),
      _method
    -> {
      let signals = process.new_subject()

      case
        begin(reply_to, stream_id, response, http2.WebsocketStream(signals))
      {
        Error(_interrupted) -> Nil
        Ok(writer) ->
          case
            http2.WebsocketConnection(
              writer:,
              context:,
              body: process.new_subject(),
              signals:,
            )
            |> connection.Http2Websocket
            |> handler
          {
            connection.Stopped -> Nil
            connection.StoppedAbnormal(reason) -> abort(reason)
          }
      }
    }
    _body, http.Head ->
      process.send(reply_to, http2.Respond(stream_id, response))
    connection.Streaming(connection.StreamingMetadata(handler:)), _method ->
      case begin(reply_to, stream_id, response, http2.PlainStream) {
        Error(_interrupted) -> Nil
        Ok(writer) -> handler(connection.Http2Writer(writer))
      }
    connection.Sse(connection.SseMetadata(handler:)), _method ->
      case begin(reply_to, stream_id, response, http2.EventStream) {
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
  mode: http2.ResponseMode,
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
      mode:,
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
    _chunk -> {
      push(writer, http2.Chunk(chunk, option.Some(writer.ack)))

      use _written <- result.map(http2.receive_reply(writer.ack_ref))
      writer
    }
  }
}

pub fn finish_chunk(
  writer: http2.ResponseWriter(connection.Body),
  chunk: BitArray,
) -> Result(Nil, http2.Interrupted) {
  push(writer, http2.Finish(chunk, option.Some(writer.ack)))

  http2.receive_reply(writer.ack_ref) |> result.replace(Nil)
}

pub fn finish_response(
  writer: http2.ResponseWriter(connection.Body),
) -> Result(Nil, http2.Interrupted) {
  finish_chunk(writer, <<>>)
}

fn push(
  writer: http2.ResponseWriter(connection.Body),
  chunk: http2.Chunk,
) -> Nil {
  process.send(writer.connection, http2.PushData(writer.stream_id, chunk))
}

@external(erlang, "ewe_http2_ffi", "exit_self")
fn abort(reason: String) -> a
