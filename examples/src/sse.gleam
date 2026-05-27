import ewe
import gleam/bit_array
import gleam/erlang/charlist
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/http
import gleam/http/response
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/string
import logging

pub fn main() -> Nil {
  logging.configure()

  // Create a named pubsub process for broadcasting messages to all connected
  // SSE clients.
  //
  let pubsub_name = process.new_name("pubsub")
  let pubsub = process.named_subject(pubsub_name)

  // Use a supervisor to manage both the pubsub worker and web server.
  // OneForAll means if either crashes, both will restart together.
  //
  let assert Ok(_) =
    supervisor.new(supervisor.OneForAll)
    |> supervisor.add(pubsub_worker(pubsub_name))
    |> supervisor.add(
      ewe.new(handler(_, pubsub))
      |> ewe.listening(port: 8080)
      |> ewe.bind("0.0.0.0")
      // Use ewe.supervised instead of ewe.start to run under supervision.
      //
      |> ewe.supervised,
    )
    |> supervisor.start

  process.sleep_forever()
}

// SSE
// -----------------------------------------------------------------------------

fn handler(req: ewe.Request, pubsub: Subject(PubSubMessage)) -> ewe.Response {
  case req.method, req.path {
    // Serve the demo HTML page.
    //
    http.Get, "/" -> {
      case ewe.file("priv/index.html", offset: None, limit: None) {
        Ok(file) -> {
          response.new(200)
          |> response.set_body(file)
          |> response.set_header("content-type", "text/html")
        }
        Error(_) -> empty_response(500)
      }
    }

    // Establish a Server-Sent Events connection. SSE is a one-way channel
    // from server to client. The connection stays open and the server can
    // push events at any time.
    //
    http.Get, "/sse" ->
      ewe.sse(
        req,
        // Initialize the connection and subscribe this client to the pubsub.
        //
        on_init: fn(client) {
          process.send(pubsub, Subscribe(client))

          client
        },
        // Handle messages from the pubsub and send them as SSE events.
        //
        handler: fn(conn, client, message) {
          case ewe.send_event(conn, ewe.event(message)) {
            Ok(Nil) -> ewe.sse_continue(client)
            Error(_) -> ewe.sse_stop()
          }
        },
        // Clean up when the client disconnects.
        //
        on_close: fn(_conn, client) {
          process.send(pubsub, Unsubscribe(client))
        },
      )

    // Accept messages via POST and broadcast them to all SSE clients.
    //
    http.Post, "/post" -> {
      // Limit matches the frontend restriction (see index.html).
      //
      case ewe.read_body(req, 128) {
        Ok(req) -> {
          case bit_array.to_string(req.body) {
            Ok(message) -> {
              process.send(pubsub, Publish(message))

              empty_response(200)
            }
            Error(Nil) -> empty_response(400)
          }
        }
        Error(_) -> empty_response(400)
      }
    }

    _, _ -> empty_response(404)
  }
}

fn empty_response(status: Int) -> ewe.Response {
  response.new(status) |> response.set_body(ewe.Empty)
}

// PubSub
// -----------------------------------------------------------------------------

type PubSubMessage {
  Subscribe(client: Subject(String))
  Unsubscribe(client: Subject(String))
  Publish(String)
}

fn pubsub_worker(
  named: Name(PubSubMessage),
) -> ChildSpecification(Subject(PubSubMessage)) {
  supervision.worker(fn() {
    actor.new([])
    |> actor.on_message(handle_pubsub_message)
    |> actor.named(named)
    |> actor.start()
  })
}

fn handle_pubsub_message(
  clients: List(Subject(String)),
  message: PubSubMessage,
) {
  case message {
    Subscribe(client) -> {
      let assert Ok(pid) = process.subject_owner(client)

      logging.log(logging.Info, "Client " <> pid_to_string(pid) <> " connected")

      actor.continue([client, ..clients])
    }

    Unsubscribe(client) -> {
      let assert Ok(pid) = process.subject_owner(client)

      { "Client " <> pid_to_string(pid) <> " disconnected" }
      |> logging.log(logging.Info, _)

      list.filter(clients, fn(subscribed) { subscribed != client })
      |> actor.continue()
    }

    Publish(message) -> {
      let pids =
        list.fold(over: clients, from: [], with: fn(acc, client) {
          let assert Ok(pid) = process.subject_owner(client)
          let _ = process.send(client, message)

          [pid_to_string(pid), ..acc]
        })
        |> string.join(", ")

      { "Sent message `" <> message <> "` to clients: " <> pids }
      |> logging.log(logging.Info, _)

      actor.continue(clients)
    }
  }
}

// Utilities
// -----------------------------------------------------------------------------

fn pid_to_string(pid: Pid) -> String {
  pid_to_list(pid)
  |> charlist.to_string()
}

@external(erlang, "erlang", "pid_to_list")
fn pid_to_list(pid: Pid) -> charlist.Charlist
