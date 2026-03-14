import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import logging

import ewe.{type Request, type Response}

pub fn main() {
  logging.configure()
  logging.set_level(logging.Debug)

  // Create a named subject for the pubsub worker
  let pubsub_name = process.new_name("pubsub")
  let pubsub = process.named_subject(pubsub_name)

  // Configure and start the supervision tree with pubsub worker and the ewe
  // server, that listens on port 8080
  let assert Ok(_) =
    supervisor.new(supervisor.OneForAll)
    |> supervisor.add(pubsub_worker(pubsub_name))
    |> supervisor.add(
      ewe.new(handler(_, pubsub))
      |> ewe.bind("0.0.0.0")
      |> ewe.listening(port: 8080)
      |> ewe.supervised(),
    )
    |> supervisor.start()

  process.sleep_forever()
}

// Define the messages that can be sent to the pubsub worker
type PubSubMessage {
  Subscribe(topic: String, client: Subject(Broadcast))
  Publish(topic: String, message: Broadcast)
  Unsubscribe(topic: String, client: Subject(Broadcast))
}

// Define the messages that could be received by websocket and SSE clients
type Broadcast {
  Text(String)
  Bytes(BitArray)
}

// Define the state of the websocket connection
type WebsocketState {
  WebsocketState(
    pubsub: Subject(PubSubMessage),
    topic: String,
    client: Subject(Broadcast),
  )
}

// Main logic of the pubsub worker, that handles the messages and keeps track of
// the clients on topics. Its implementation is not really important
fn pubsub_worker(
  named: Name(PubSubMessage),
) -> ChildSpecification(Subject(PubSubMessage)) {
  let pubsub =
    actor.new(dict.new())
    |> actor.on_message(fn(state, msg) {
      case msg {
        Subscribe(topic:, client:) -> {
          let new_state =
            dict.upsert(in: state, update: topic, with: fn(clients) {
              case clients {
                Some(clients) -> [client, ..clients]
                None -> {
                  logging.log(logging.Info, "Creating topic " <> topic)
                  [client]
                }
              }
            })

          let assert Ok(pid) = process.subject_owner(client)
          logging.log(
            logging.Info,
            "Subscribing client " <> pid_to_string(pid) <> " to topic " <> topic,
          )

          actor.continue(new_state)
        }
        Publish(topic:, message:) -> {
          case message {
            Text(text) ->
              logging.log(
                logging.Info,
                "Publishing text message `" <> text <> "` to topic " <> topic,
              )
            Bytes(_binary) ->
              logging.log(
                logging.Info,
                "Publishing binary message to topic " <> topic,
              )
          }

          case dict.get(state, topic) {
            Ok(clients) -> list.each(clients, actor.send(_, message))
            Error(_) -> Nil
          }

          actor.continue(state)
        }
        Unsubscribe(topic:, client:) -> {
          let assert Ok(pid) = process.subject_owner(client)
          logging.log(
            logging.Info,
            "Unsubscribing client "
              <> pid_to_string(pid)
              <> " from topic "
              <> topic,
          )

          let new_state = case dict.get(state, topic) {
            Ok([_]) | Ok([]) -> {
              logging.log(logging.Info, "Dropping topic " <> topic)
              dict.drop(state, [topic])
            }
            Ok(clients) -> {
              list.filter(clients, fn(c) { c != client })
              |> dict.insert(state, topic, _)
            }
            Error(_) -> state
          }

          actor.continue(new_state)
        }
      }
    })
    |> actor.named(named)

  supervision.worker(fn() {
    logging.log(logging.Info, "Starting pubsub worker")
    actor.start(pubsub)
  })
}

// Main HTTP request handler that routes requests to different endpoints
fn handler(req: Request, pubsub: Subject(PubSubMessage)) -> Response {
  case request.path_segments(req) {
    // GET /hello/:name - Simple greeting endpoint
    ["hello", name] -> {
      response.new(200)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Hello, " <> name <> "!"))
    }
    // GET /bytes/:amount - Generate random N bytes
    ["bytes", amount] -> {
      let random_bytes =
        int.parse(amount)
        |> result.unwrap(0)
        |> crypto.strong_random_bytes()

      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(ewe.BitsData(random_bytes))
    }

    // POST /echo - Echo back the request body
    ["echo"] -> handle_echo(req)

    // POST /stream/:chunk_size - Stream and echo back the request body in chunks
    ["stream", chunk_size] ->
      handle_stream(req, int.parse(chunk_size) |> result.unwrap(16))
    // GET /file/:path - Serve a file from the public directory
    ["file", path] -> serve_file(path)

    // POST /topic/:topic/ws - Upgrade to WebSocket connection
    ["topic", topic, "ws"] ->
      ewe.upgrade_websocket(
        req,
        on_init: fn(_conn, selector) {
          logging.log(
            logging.Info,
            "WebSocket connection opened: " <> pid_to_string(process.self()),
          )

          let client = process.new_subject()
          process.send(pubsub, Subscribe(topic:, client:))

          let state = WebsocketState(pubsub:, topic:, client:)
          let selector = process.select(selector, client)

          #(state, selector)
        },
        handler: handle_websocket,
        on_close: fn(_conn, state) {
          let assert Ok(pid) = process.subject_owner(state.client)
          logging.log(
            logging.Info,
            "WebSocket connection closed: " <> pid_to_string(pid),
          )

          process.send(pubsub, Unsubscribe(state.topic, state.client))
        },
      )

    // POST /topic/:topic/sse - Switch to Server-Sent Events connection
    ["topic", topic, "sse"] ->
      ewe.sse(
        req,
        on_init: fn(client) {
          logging.log(
            logging.Info,
            "SSE connection opened: " <> pid_to_string(process.self()),
          )

          process.send(pubsub, Subscribe(topic:, client:))
          client
        },
        handler: fn(conn, client, message) {
          let assert Ok(_) = case message {
            Text(text) -> ewe.send_event(conn, ewe.event(text))
            _ -> Ok(Nil)
          }

          ewe.sse_continue(client)
        },
        on_close: fn(_conn, client) {
          logging.log(
            logging.Info,
            "SSE connection closed: " <> pid_to_string(process.self()),
          )

          process.send(pubsub, Unsubscribe(topic:, client:))
        },
      )

    // All other routes return 404
    _ ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}

fn handle_echo(req: Request) -> Response {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("application/octet-stream")

  case ewe.read_body(req, 1024) {
    Ok(req) ->
      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_body(ewe.BitsData(req.body))
    Error(ewe.BodyTooLarge) ->
      response.new(413)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Body too large"))
    Error(ewe.InvalidBody) ->
      response.new(400)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Invalid request"))
  }
}

pub type StreamMessage {
  Chunk(BitArray)
  Done
  BodyError(ewe.BodyError)
}

fn stream_resource(
  consumer: ewe.Consumer,
  subject: Subject(StreamMessage),
  chunk_size: Int,
) -> Nil {
  process.sleep(int.random(250))
  case consumer(chunk_size) {
    Ok(ewe.Consumed(data, next)) -> {
      logging.log(logging.Info, {
        "Consumed " <> int.to_string(bit_array.byte_size(data)) <> " bytes"
      })

      process.send(subject, Chunk(data))
      stream_resource(next, subject, chunk_size)
    }
    Ok(ewe.Done) -> {
      process.send(subject, Done)
    }
    Error(body_error) -> {
      process.send(subject, BodyError(body_error))
    }
  }
}

fn handle_stream(req: Request, chunk_size: Int) -> Response {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("application/octet-stream")

  case ewe.stream_body(req) {
    Ok(consumer) -> {
      ewe.chunked_body(
        req,
        response.new(200) |> response.set_header("content-type", content_type),
        on_init: fn(subject) {
          process.spawn(fn() { stream_resource(consumer, subject, chunk_size) })

          Nil
        },
        handler: fn(chunked_body, state, message) {
          case message {
            Chunk(data) ->
              case ewe.send_chunk(chunked_body, data) {
                Ok(Nil) -> ewe.chunked_continue(state)
                Error(_) -> ewe.chunked_stop_abnormal("Failed to send chunk")
              }
            Done -> ewe.chunked_stop()
            BodyError(_body_error) ->
              ewe.chunked_stop_abnormal("failed to read body")
          }
        },
        on_close: fn(_conn, _state) {
          logging.log(logging.Info, "Stream closed")
        },
      )
    }
    Error(_) ->
      response.new(400)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Invalid request"))
  }
}

fn serve_file(path: String) -> Response {
  case ewe.file("public/" <> path, offset: None, limit: None) {
    Ok(file) -> {
      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(file)
    }
    Error(_) -> {
      response.new(404)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("File not found"))
    }
  }
}

fn handle_websocket(
  conn: ewe.WebsocketConnection,
  state: WebsocketState,
  msg: ewe.WebsocketMessage(Broadcast),
) -> ewe.WebsocketNext(WebsocketState, Broadcast) {
  case msg {
    ewe.Text(text) -> {
      process.send(state.pubsub, Publish(state.topic, Text(text)))
      ewe.websocket_continue(state)
    }

    ewe.Binary(binary) -> {
      process.send(state.pubsub, Publish(state.topic, Bytes(binary)))
      ewe.websocket_continue(state)
    }

    ewe.User(message) -> {
      let assert Ok(_) = case message {
        Text(text) -> ewe.send_text_frame(conn, text)
        Bytes(binary) -> ewe.send_binary_frame(conn, binary)
      }

      ewe.websocket_continue(state)
    }
  }
}

fn pid_to_string(pid: Pid) -> String {
  charlist.to_string(pid_to_list(pid))
}

@external(erlang, "erlang", "pid_to_list")
fn pid_to_list(pid: Pid) -> Charlist
