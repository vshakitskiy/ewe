import ewe/internal/connection
import ewe/internal/file
import ewe/internal/http1/body
import ewe/internal/http1/connection as http1
import ewe/internal/http1/encoder
import ewe/internal/http1/parser
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option
import gleam/result
import glisten
import glisten/socket
import glisten/transport
import logging

pub type State {
  State(
    handler: fn(request.Request(connection.Connection)) ->
      response.Response(connection.Body),
    buffer: BitArray,
    idle_timer: option.Option(process.Timer),
  )
}

pub type Next {
  Continue(State)
  Close
  CloseAbnormal(reason: String)
}

type Sent {
  SentKeepAlive
  SentClose
  SentAbnormal(reason: String)
}

pub fn handle_message(
  state: State,
  connection: glisten.Connection(connection.Message),
) -> Next {
  connection.cancel_idle_timer(state.idle_timer)

  case parser.parse(state.buffer) {
    Ok(parser.Complete(head, metadata, remaining)) -> {
      let self = process.new_subject()

      let body_connection =
        http1.Connection(
          transport: connection.transport,
          socket: connection.socket,
          self:,
          buffer: remaining,
          framing: metadata.framing,
          read: 0,
          chunk_remaining: 0,
        )

      let response =
        state.handler(to_request(head, connection, body_connection))

      let drained = drain_messages(self)
      let ResolvedBody(buffer, body_keep_alive) =
        resolve_body(body_connection, drained.body)
      let keep_alive =
        http1.and_keep_alive(metadata.keep_alive, body_keep_alive)

      let sent = case
        encoder.encode_response(response, head.method, head.version, keep_alive)
      {
        Ok(encoded) ->
          send_response(encoded, connection.transport, connection.socket, self)
        Error(encoder.UnsafeHeader(name)) -> {
          logging.log(
            logging.Error,
            "Handler produced an unsafe response header: " <> name,
          )

          transport.send(
            connection.transport,
            connection.socket,
            encoder.internal_server_error(),
          )
          |> result.replace(SentClose)
        }
      }

      case sent {
        Ok(SentKeepAlive) -> {
          let idle_timer = connection.start_idle_timer(connection)
          Continue(State(..state, buffer:, idle_timer:))
        }
        Ok(SentClose) -> Close
        Ok(SentAbnormal(reason)) -> CloseAbnormal(reason)
        Error(_reason) -> Close
      }
    }
    Ok(parser.Incomplete) ->
      State(..state, idle_timer: connection.start_idle_timer(connection))
      |> Continue
    Error(error) -> {
      logging.log(
        logging.Error,
        "Failed to parser.parse HTTP/1.x request: "
          <> parser.error_to_string(error),
      )

      Close
    }
  }
}

fn to_request(
  head: parser.Head,
  connection: glisten.Connection(connection.Message),
  body: http1.Connection,
) -> request.Request(connection.Connection) {
  let scheme = case connection.transport {
    transport.Tcp -> http.Http
    transport.Ssl -> http.Https
  }

  request.Request(
    method: head.method,
    headers: head.headers,
    body: connection.Http1(body),
    scheme:,
    host: head.host,
    port: head.port,
    path: head.path,
    query: head.query,
  )
}

fn send_response(
  encoded: encoder.Encoded,
  transport: transport.Transport,
  socket: socket.Socket,
  self: process.Subject(http1.Signal),
) -> Result(Sent, socket.SocketReason) {
  let encoder.Encoded(head:, keep_alive:, remainder:) = encoded

  case remainder {
    encoder.NoRemainder -> {
      use Nil <- result.try(transport.send(transport, socket, head))
      Ok(to_sent(keep_alive))
    }
    encoder.RemainderInline(body) -> {
      use Nil <- result.try(transport.send(
        transport,
        socket,
        bytes_tree.append_tree(head, body),
      ))
      Ok(to_sent(keep_alive))
    }
    encoder.RemainderFile(data) -> {
      use Nil <- result.try(transport.send(transport, socket, head))
      use Nil <- result.try(file.send(transport, socket, data))
      Ok(to_sent(keep_alive))
    }
    encoder.RemainderStream(handler: stream_handler, framing:) -> {
      use Nil <- result.try(transport.send(transport, socket, head))

      connection.Http1Writer(http1.ResponseWriter(
        transport:,
        socket:,
        self:,
        framing:,
        keep_alive:,
      ))
      |> stream_handler

      let drained = drain_messages(self)
      case drained.stream {
        option.Some(http1.StreamFinished(keep_alive:)) ->
          Ok(to_sent(keep_alive))
        // A handler that returns without finishing left the body unterminated,
        // so close it out here and drop a connection we can no longer reuse.
        option.None -> {
          let _ = encoder.end_stream(transport, socket, framing)
          Ok(SentClose)
        }
      }
    }
    encoder.RemainderSse(handler: sse_handler) -> {
      use Nil <- result.try(transport.send(transport, socket, head))

      connection.Http1Sse(http1.SseConnection(transport:, socket:))
      |> sse_handler
      |> to_sse_sent
      |> Ok
    }
  }
}

fn to_sent(keep_alive: http1.KeepAlive) -> Sent {
  case keep_alive {
    http1.KeepAlive -> SentKeepAlive
    http1.CloseAfterResponse -> SentClose
  }
}

fn to_sse_sent(outcome: connection.Outcome) -> Sent {
  case outcome {
    connection.Stopped -> SentClose
    connection.StoppedAbnormal(reason:) -> SentAbnormal(reason)
  }
}

const auto_drain_limit = 1_048_576

const auto_drain_chunk_bytes = 65_536

/// What the request body left behind: the bytes after it, which begin the next
/// pipelined request, and whether it was consumed cleanly enough to reuse the
/// connection at all.
type ResolvedBody {
  ResolvedBody(leftover: BitArray, keep_alive: http1.KeepAlive)
}

fn resolve_body(
  conn: http1.Connection,
  drained: option.Option(http1.BodySignal),
) -> ResolvedBody {
  case drained {
    option.Some(http1.BodyDrained(leftover)) ->
      ResolvedBody(leftover, http1.KeepAlive)
    option.Some(http1.BodyAbandoned) ->
      ResolvedBody(<<>>, http1.CloseAfterResponse)
    option.Some(http1.BodyProgress(buffer:, read:, chunk_remaining:)) ->
      http1.Connection(..conn, buffer:, read:, chunk_remaining:)
      |> drain_remaining
    option.None -> drain_remaining(conn)
  }
}

type Drained {
  Drained(
    body: option.Option(http1.BodySignal),
    stream: option.Option(http1.StreamSignal),
  )
}

fn drain_messages(self: process.Subject(http1.Signal)) -> Drained {
  do_drain_messages(self, Drained(body: option.None, stream: option.None))
}

fn do_drain_messages(
  self: process.Subject(http1.Signal),
  acc: Drained,
) -> Drained {
  case process.receive(self, 0) {
    Ok(http1.BodySignal(signal)) ->
      do_drain_messages(self, Drained(..acc, body: option.Some(signal)))
    Ok(http1.StreamSignal(signal)) ->
      do_drain_messages(self, Drained(..acc, stream: option.Some(signal)))
    Error(Nil) -> acc
  }
}

fn drain_remaining(conn: http1.Connection) -> ResolvedBody {
  let http1.Connection(read:, ..) = conn
  do_drain_remaining(conn, read + auto_drain_limit)
}

fn do_drain_remaining(conn: http1.Connection, limit: Int) -> ResolvedBody {
  case body.pull_chunk(conn, auto_drain_chunk_bytes, limit) {
    Ok(body.PulledChunk(_data, next)) -> do_drain_remaining(next, limit)
    Ok(body.PulledDone(_trailers, leftover)) ->
      ResolvedBody(leftover, http1.KeepAlive)
    Error(_reason) -> ResolvedBody(<<>>, http1.CloseAfterResponse)
  }
}
