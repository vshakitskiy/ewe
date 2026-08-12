import ewe
import examples/pubsub
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/otp/static_supervisor as supervisor
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

  let listener_name = process.new_name("listener_name")
  let connection_factory_name = process.new_name("connection_factory_name")

  // Remember, `handle_request(_, pubsub)` is the same as:
  // fn(request) { handle_request(request, pubsub) }
  let handler = handle_request(_, pubsub)

  // Set up supervision for both pubsub and the web server.
  //
  let assert Ok(_) =
    supervisor.new(supervisor.OneForAll)
    |> supervisor.add(pubsub.worker(pubsub_name))
    |> supervisor.add(
      ewe.new(listener_name:, connection_factory_name:, handler:)
      |> ewe.bind(to: "0.0.0.0")
      |> ewe.listening(on: 8080)
      |> ewe.supervised,
    )
    |> supervisor.start

  process.sleep_forever()
}

fn handle_request(
  req: request.Request(ewe.Connection),
  pubsub: Subject(pubsub.Message(Broadcast)),
) -> response.Response(ewe.Body) {
  case request.path_segments(req) {
    ["topic", topic] -> handle_topic(req, pubsub, topic)
    _segments ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}

type WebsocketState {
  WebsocketState(
    pubsub: Subject(pubsub.Message(Broadcast)),
    topic: String,
    client: Subject(Broadcast),
  )
}

// What one client sends to everyone else subscribed to the same topic.
type Broadcast {
  Text(String)
  Bytes(BitArray)
}

fn handle_topic(
  req: request.Request(ewe.Connection),
  pubsub: Subject(pubsub.Message(Broadcast)),
  topic: String,
) -> response.Response(ewe.Body) {
  // Upgrade the HTTP connection to WebSocket. Unlike SSE, WebSocket is
  // bidirectional, so both client and server can send messages at any time.
  // The upgrade needs an HTTP/1.1 connection, an HTTP/2 one is answered
  // with a 501.
  //
  ewe.websocket(
    request: req,
    // Initialize the WebSocket connection. The selector allows receiving
    // messages from both the WebSocket and the pubsub system.
    on_init: fn(_conn, selector) {
      logging.log(logging.Info, "WebSocket connection opened")

      let client = process.new_subject()
      pubsub.subscribe(pubsub, topic:, client:)

      let state = WebsocketState(pubsub:, topic:, client:)
      // Add the client subject to the selector to receive broadcast messages.
      let selector = process.select(selector, client)

      #(state, selector)
    },
    handler: handle_websocket_message,
    on_close: fn(_conn, state) {
      logging.log(logging.Info, "WebSocket connection closed")

      pubsub.unsubscribe(state.pubsub, topic: state.topic, client: state.client)
    },
  )
}

// Handle three types of messages: text from client, binary from client,
// and broadcast messages from the pubsub system.
//
fn handle_websocket_message(
  conn: ewe.WebsocketConnection,
  state: WebsocketState,
  message: ewe.WebsocketMessage(Broadcast),
) -> ewe.WebsocketNext(WebsocketState, Broadcast) {
  case message {
    // Text frame from the client; broadcast to all subscribers.
    ewe.TextFrame(text) -> {
      pubsub.publish(state.pubsub, topic: state.topic, message: Text(text))
      ewe.websocket_continue(state)
    }

    // Binary frame from the client; broadcast to all subscribers.
    ewe.BinaryFrame(data) -> {
      pubsub.publish(state.pubsub, topic: state.topic, message: Bytes(data))
      ewe.websocket_continue(state)
    }

    // Message from the pubsub; forward to this client.
    ewe.UserMessage(broadcast) -> {
      let sent = case broadcast {
        Text(text) -> ewe.send_text_frame(conn, text)
        Bytes(data) -> ewe.send_binary_frame(conn, data)
      }

      case sent {
        Ok(Nil) -> ewe.websocket_continue(state)
        Error(_send_error) ->
          ewe.websocket_stop_abnormal("Failed to send a frame")
      }
    }
  }
}
