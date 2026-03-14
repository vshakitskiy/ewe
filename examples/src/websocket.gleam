import ewe.{type Request, type Response}
import gleam/dict
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  // Create a named pubsub process for topic-based message broadcasting.
  // Multiple clients can subscribe to different topics and receive messages
  // sent to those topics.
  //
  let pubsub_name = process.new_name("pubsub")
  let pubsub = process.named_subject(pubsub_name)

  // Set up supervision for both pubsub and the web server.
  //
  let assert Ok(_) =
    supervisor.new(supervisor.OneForAll)
    |> supervisor.add(pubsub_worker(pubsub_name))
    |> supervisor.add(
      ewe.new(handler(_, pubsub))
      |> ewe.bind("0.0.0.0")
      |> ewe.listening(port: 8080)
      |> ewe.supervised,
    )
    |> supervisor.start

  process.sleep_forever()
}

fn handler(req: Request, pubsub: Subject(PubSubMessage)) -> Response {
  case request.path_segments(req) {
    ["topic", topic] -> handle_topic(req, pubsub, topic)
    _ ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}

// Websocket
// -----------------------------------------------------------------------------

type WebsocketState {
  WebsocketState(
    pubsub: Subject(PubSubMessage),
    topic: String,
    client: Subject(Broadcast),
  )
}

type Broadcast {
  Text(String)
  Bytes(BitArray)
}

fn handle_topic(req: Request, pubsub: Subject(PubSubMessage), topic: String) {
  // Upgrade the HTTP connection to WebSocket. Unlike SSE, WebSocket is
  // bidirectional - both client and server can send messages at any time.
  //
  ewe.upgrade_websocket(
    req,
    // Initialize the WebSocket connection. The selector allows receiving
    // messages from both the WebSocket and the pubsub system.
    //
    on_init: fn(_conn, selector) {
      logging.log(
        logging.Info,
        "WebSocket connection opened: " <> pid_to_string(process.self()),
      )

      let client = process.new_subject()
      process.send(pubsub, Subscribe(topic:, client:))

      let state = WebsocketState(pubsub:, topic:, client:)
      // Add the client subject to the selector to receive broadcast messages.
      //
      let selector = process.select(selector, client)

      #(state, selector)
    },
    handler: handle_websocket_message,
    on_close: fn(_conn, state) {
      let assert Ok(pid) = process.subject_owner(state.client)
      logging.log(
        logging.Info,
        "WebSocket connection closed: " <> pid_to_string(pid),
      )

      process.send(pubsub, Unsubscribe(state.topic, state.client))
    },
  )
}

// Handle three types of messages: text from client, binary from client,
// and broadcast messages from the pubsub system.
//
fn handle_websocket_message(
  conn: ewe.WebsocketConnection,
  state: WebsocketState,
  msg: ewe.WebsocketMessage(Broadcast),
) -> ewe.WebsocketNext(WebsocketState, Broadcast) {
  case msg {
    // Text message from the client - broadcast to all subscribers.
    //
    ewe.Text(text) -> {
      process.send(state.pubsub, Publish(state.topic, Text(text)))
      ewe.websocket_continue(state)
    }

    // Binary message from the client - broadcast to all subscribers.
    //
    ewe.Binary(binary) -> {
      process.send(state.pubsub, Publish(state.topic, Bytes(binary)))
      ewe.websocket_continue(state)
    }

    // User message from the pubsub - forward to this client.
    //
    ewe.User(message) -> {
      let assert Ok(_) = case message {
        Text(text) -> ewe.send_text_frame(conn, text)
        Bytes(binary) -> ewe.send_binary_frame(conn, binary)
      }

      ewe.websocket_continue(state)
    }
  }
}

// PubSub
// -----------------------------------------------------------------------------

type PubSubMessage {
  Subscribe(topic: String, client: Subject(Broadcast))
  Publish(topic: String, message: Broadcast)
  Unsubscribe(topic: String, client: Subject(Broadcast))
}

fn pubsub_worker(
  named: Name(PubSubMessage),
) -> ChildSpecification(Subject(PubSubMessage)) {
  let pubsub =
    dict.new()
    |> actor.new
    |> actor.on_message(handle_pubsub_message)
    |> actor.named(named)

  supervision.worker(fn() {
    logging.log(logging.Info, "Starting pubsub worker")
    actor.start(pubsub)
  })
}

fn handle_pubsub_message(state, message) {
  case message {
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
        "Unsubscribing client " <> pid_to_string(pid) <> " from topic " <> topic,
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
}

// Utilities
// -----------------------------------------------------------------------------

fn pid_to_string(pid: Pid) -> String {
  charlist.to_string(pid_to_list(pid))
}

@external(erlang, "erlang", "pid_to_list")
fn pid_to_list(pid: Pid) -> Charlist
