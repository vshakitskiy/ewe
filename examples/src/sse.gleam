import ewe
import examples/pubsub
import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option.{None}
import gleam/otp/static_supervisor as supervisor
import logging

// Every SSE client here listens to the same topic, so a message posted to the
// server reaches all of them.
const topic = "messages"

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Info)

  // Create a named pubsub process for broadcasting messages to all connected
  // SSE clients.
  //
  let pubsub_name = process.new_name("pubsub")
  let pubsub = process.named_subject(pubsub_name)

  let listener_name = process.new_name("listener_name")
  let connection_factory_name = process.new_name("connection_factory_name")

  // Remember, `handle_request(_, pubsub)` is the same as:
  // fn(request) { handle_request(request, pubsub) }
  let handler = handle_request(_, pubsub)

  // Use a supervisor to manage both the pubsub worker and web server.
  // OneForAll means if either crashes, both will restart together.
  //
  let assert Ok(_) =
    supervisor.new(supervisor.OneForAll)
    |> supervisor.add(pubsub.worker(pubsub_name))
    |> supervisor.add(
      ewe.new(listener_name:, connection_factory_name:, handler:)
      |> ewe.bind(to: "0.0.0.0")
      |> ewe.listening(on: 8080)
      // Use ewe.supervised instead of ewe.start to run under supervision.
      |> ewe.supervised,
    )
    |> supervisor.start

  process.sleep_forever()
}

fn handle_request(
  req: request.Request(ewe.Connection),
  pubsub: process.Subject(pubsub.Message(String)),
) -> response.Response(ewe.Body) {
  case req.method, req.path {
    // Serve the demo HTML page.
    http.Get, "/" -> {
      case ewe.file(req.body, "priv/index.html", offset: None, limit: None) {
        Ok(file) -> {
          response.new(200)
          |> response.set_body(file)
          |> response.set_header("content-type", "text/html")
        }
        Error(_error) ->
          response.new(500)
          |> response.set_body(ewe.Empty)
      }
    }

    // Establish a Server-Sent Events connection. SSE is a one-way channel
    // from server to client. The connection stays open and the server can
    // push events at any time. The `content-type` and `cache-control` headers
    // the stream needs are set by ewe.
    http.Get, "/sse" ->
      response.new(200)
      |> ewe.sse(
        // Subscribe this client to the pubsub and listen on the subject it
        // publishes to.
        on_init: fn(_conn, selector) {
          let client = process.new_subject()
          pubsub.subscribe(pubsub, topic:, client:)

          #(client, process.select(selector, client))
        },
        // Handle messages from the pubsub and send them as SSE events.
        handler: fn(conn, client, message) {
          case ewe.send_event(conn, ewe.event(message)) {
            Ok(Nil) -> ewe.continue(client)
            Error(_send_error) -> ewe.stop()
          }
        },
        // Clean up when the client disconnects.
        on_close: fn(_conn, client) {
          pubsub.unsubscribe(pubsub, topic:, client:)
        },
      )

    // Accept messages via POST and broadcast them to all SSE clients.
    http.Post, "/post" -> {
      // Limit matches the frontend restriction.
      case ewe.read_body(req, limit: 128) {
        Ok(req) -> {
          case bit_array.to_string(req.body) {
            Ok(message) -> {
              pubsub.publish(pubsub, topic:, message:)

              response.new(200)
              |> response.set_body(ewe.Empty)
            }
            Error(Nil) ->
              response.new(400)
              |> response.set_body(ewe.Empty)
          }
        }
        Error(_body_error) ->
          response.new(400)
          |> response.set_body(ewe.Empty)
      }
    }

    _method, _path ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}
