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
    config: http1.Config,
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

  case parser.parse(state.buffer, state.config) {
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
          config: state.config,
        )

      let response =
        state.handler(to_request(head, connection, body_connection))

      let drained = drain_messages(self)
      let ResolvedBody(buffer, body_keep_alive) =
        resolve_body(body_connection, drained.body, state.config)
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
          file.release_body(response.body)

          transport.send(
            connection.transport,
            connection.socket,
            encoder.internal_server_error(),
          )
          |> result.replace(SentClose)
        }
      }

      case sent {
        Ok(SentKeepAlive) -> await_next_request(state, buffer, connection)
        Ok(SentClose) -> Close
        Ok(SentAbnormal(reason)) -> CloseAbnormal(reason)
        Error(_reason) -> Close
      }
    }
    Ok(parser.Incomplete) -> {
      let idle_timer =
        connection.start_idle_timer(connection, state.config.idle_timeout)
      Continue(State(..state, idle_timer:))
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "Failed to parse HTTP/1.x request: " <> parser.error_to_string(error),
      )

      let _sent =
        transport.send(
          connection.transport,
          connection.socket,
          encoder.error_response(parser.error_to_status(error)),
        )

      Close
    }
  }
}

/// A pipelining client sends its next request without waiting for this 
/// response, so anything left over has to be handled now. Waiting on the socket
/// for it would deadlock: those bytes have already arrived.
fn await_next_request(
  state: State,
  buffer: BitArray,
  connection: glisten.Connection(connection.Message),
) -> Next {
  case buffer {
    <<>> -> {
      let idle_timer =
        connection.start_idle_timer(connection, state.config.idle_timeout)
      Continue(State(..state, buffer:, idle_timer:))
    }
    _buffer ->
      State(..state, buffer:, idle_timer: option.None)
      |> handle_message(connection)
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
    // `file.send` owns the descriptor once it is reached, so only a head that
    // never made it to the socket leaves one to hand back.
    encoder.RemainderFile(data) ->
      case transport.send(transport, socket, head) {
        Error(reason) -> {
          file.release(data)
          Error(reason)
        }
        Ok(Nil) -> {
          use Nil <- result.try(file.send(transport, socket, data))
          Ok(to_sent(keep_alive))
        }
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
    encoder.RemainderSse(handler: sse_handler, framing:) -> {
      use Nil <- result.try(transport.send(transport, socket, head))

      let outcome =
        http1.SseConnection(transport:, socket:, self:, framing:)
        |> connection.Http1Sse
        |> sse_handler

      let _ = encoder.end_stream(transport, socket, framing)

      // The stream reports whether it left the socket at a point another
      // request could start from.
      let drained = drain_messages(self)
      let stream_keep_alive = case drained.stream {
        option.Some(http1.StreamFinished(keep_alive:)) -> keep_alive
        option.None -> http1.CloseAfterResponse
      }

      case outcome {
        connection.StoppedAbnormal(reason) -> Ok(SentAbnormal(reason))
        connection.Stopped ->
          http1.and_keep_alive(keep_alive, stream_keep_alive)
          |> to_sent
          |> Ok
      }
    }
  }
}

fn to_sent(keep_alive: http1.KeepAlive) -> Sent {
  case keep_alive {
    http1.KeepAlive -> SentKeepAlive
    http1.CloseAfterResponse -> SentClose
  }
}

/// What the request body left behind: the bytes after it, which begin the next
/// pipelined request, and whether it was consumed cleanly enough to reuse the
/// connection at all.
type ResolvedBody {
  ResolvedBody(leftover: BitArray, keep_alive: http1.KeepAlive)
}

fn resolve_body(
  conn: http1.Connection,
  drained: option.Option(http1.BodySignal),
  config: http1.Config,
) -> ResolvedBody {
  case drained {
    option.Some(http1.BodyDrained(leftover)) ->
      ResolvedBody(leftover, http1.KeepAlive)
    option.Some(http1.BodyAbandoned) ->
      ResolvedBody(<<>>, http1.CloseAfterResponse)
    option.Some(http1.BodyProgress(buffer:, read:, chunk_remaining:)) ->
      http1.Connection(..conn, buffer:, read:, chunk_remaining:)
      |> drain_remaining(config)
    option.None -> drain_remaining(conn, config)
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

fn drain_remaining(
  conn: http1.Connection,
  config: http1.Config,
) -> ResolvedBody {
  let http1.Connection(read:, ..) = conn
  do_drain_remaining(conn, read + config.auto_drain_limit, config)
}

fn do_drain_remaining(
  conn: http1.Connection,
  limit: Int,
  config: http1.Config,
) -> ResolvedBody {
  case body.pull_chunk(conn, config.auto_drain_chunk_bytes, limit) {
    Ok(body.PulledChunk(_data, next)) -> do_drain_remaining(next, limit, config)
    Ok(body.PulledDone(_trailers, leftover)) ->
      ResolvedBody(leftover, http1.KeepAlive)
    Error(_reason) -> ResolvedBody(<<>>, http1.CloseAfterResponse)
  }
}
