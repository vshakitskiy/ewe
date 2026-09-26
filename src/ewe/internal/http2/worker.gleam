import ewe/internal/connection
import ewe/internal/http2/connection as http2
import ewe/internal/rescue
import gleam/erlang/process
import gleam/erlang/reference
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import logging

pub fn start(
  respond_to: process.Subject(connection.Message),
  commands: process.Subject(http2.Command),
  stream_id: Int,
  request: request.Request(connection.Connection),
  handler: connection.Handler,
) -> process.Pid {
  use <- process.spawn

  case rescue.run(fn() { handler.respond(request) }) {
    Ok(response) ->
      deliver(respond_to, commands, stream_id, response, request.method)
    Error(details) -> {
      logging.log(logging.Error, "Caught a crash in the handler: " <> details)
      process.send(
        respond_to,
        connection.Http2Respond(stream_id, handler.on_crash),
      )
    }
  }
}

fn deliver(
  respond_to: process.Subject(connection.Message),
  commands: process.Subject(http2.Command),
  stream_id: Int,
  response: response.Response(connection.Body),
  method: http.Method,
) -> Nil {
  case response.body, has_content(response.status, method) {
    _body, False ->
      process.send(respond_to, connection.Http2Respond(stream_id, response))
    connection.Websocket(connection.WebsocketMetadata(context:, handler:)), True
    -> {
      let signals = process.new_subject()
      use writer <- send_headers(commands, stream_id, response, Some(signals))

      http2.WebsocketConnection(
        writer:,
        context:,
        body: process.new_subject(),
        signals:,
      )
      |> connection.Http2Websocket
      |> handler
      |> exit_with
    }
    connection.Streaming(connection.StreamingMetadata(handler:)), True -> {
      use writer <- send_headers(commands, stream_id, response, None)
      handler(connection.Http2Writer(writer))
    }
    connection.Sse(connection.SseMetadata(handler:)), True -> {
      let signals = process.new_subject()
      let response =
        response.Response(..response, headers: event_stream_headers(response))
      use writer <- send_headers(commands, stream_id, response, Some(signals))

      handler(connection.Http2Sse(http2.SseConnection(writer:, signals:)))
      |> exit_with
    }
    connection.Bytes(_tree), True
    | connection.Text(_text), True
    | connection.Empty, True
    | connection.File(_file), True
    -> process.send(respond_to, connection.Http2Respond(stream_id, response))
  }
}

fn has_content(status: Int, method: http.Method) -> Bool {
  method != http.Head && status >= 200 && status != 204 && status != 304
}

fn exit_with(outcome: connection.Outcome) -> Nil {
  case outcome {
    connection.Stopped -> Nil
    connection.StoppedAbnormal(reason) -> abort(reason)
  }
}

fn event_stream_headers(
  response: response.Response(connection.Body),
) -> List(#(String, String)) {
  let headers =
    list.filter(response.headers, fn(header) {
      header.0 != "content-type" && header.0 != "cache-control"
    })

  [
    #("content-type", "text/event-stream"),
    #("cache-control", "no-cache"),
    ..headers
  ]
}

fn send_headers(
  commands: process.Subject(http2.Command),
  stream_id: Int,
  response: response.Response(connection.Body),
  signals: Option(process.Subject(http2.StreamSignal)),
  stream: fn(http2.ResponseWriter) -> Nil,
) -> Nil {
  process.trap_exits(True)

  let ack_ref = reference.new()
  let ack = process.unsafely_create_subject(process.self(), http2.tag(ack_ref))

  process.send(
    commands,
    http2.WriteHeaders(
      stream_id:,
      ack:,
      status: response.status,
      headers: response.headers,
      signals:,
    ),
  )

  case from_ack(http2.receive_reply(ack_ref)) {
    Ok(Nil) ->
      stream(http2.ResponseWriter(commands:, stream_id:, ack:, ack_ref:))
    Error(_interrupted) -> Nil
  }
}

pub fn write(
  writer: http2.ResponseWriter,
  data: BitArray,
  end_stream: Bool,
) -> Result(Nil, http2.Interrupted) {
  queue_write(writer, data, end_stream)
  from_ack(http2.receive_reply(writer.ack_ref))
}

pub fn write_within(
  writer: http2.ResponseWriter,
  data: BitArray,
  end_stream: Bool,
  timeout: Int,
) -> Result(Nil, http2.Interrupted) {
  queue_write(writer, data, end_stream)
  from_ack(http2.receive_reply_within(writer.ack_ref, timeout))
}

fn from_ack(
  ack: Result(http2.WriteAck, http2.Interrupted),
) -> Result(Nil, http2.Interrupted) {
  case ack {
    Ok(http2.Written) -> Ok(Nil)
    Ok(http2.Ended) -> Error(http2.StreamEnded)
    Error(interrupted) -> Error(interrupted)
  }
}

fn queue_write(
  writer: http2.ResponseWriter,
  data: BitArray,
  end_stream: Bool,
) -> Nil {
  process.send(
    writer.commands,
    http2.WriteData(
      stream_id: writer.stream_id,
      data:,
      end_stream:,
      ack: writer.ack,
    ),
  )
}

pub fn send_chunk(
  writer: http2.ResponseWriter,
  chunk: BitArray,
) -> Result(http2.ResponseWriter, http2.Interrupted) {
  case chunk {
    <<>> -> Ok(writer)
    _chunk -> write(writer, chunk, False) |> result.replace(writer)
  }
}

pub fn finish_chunk(
  writer: http2.ResponseWriter,
  chunk: BitArray,
) -> Result(Nil, http2.Interrupted) {
  write(writer, chunk, True)
}

pub fn finish_response(
  writer: http2.ResponseWriter,
) -> Result(Nil, http2.Interrupted) {
  write(writer, <<>>, True)
}

@external(erlang, "ewe_ffi", "exit_self")
fn abort(reason: String) -> a
