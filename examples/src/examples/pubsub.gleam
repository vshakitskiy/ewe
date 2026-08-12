//// A small topic based pubsub shared by the examples that need one. Clients
//// subscribe with a subject of their own message type and every message
//// published to a topic is sent to each of them.

import gleam/dict.{type Dict}
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import logging

pub type Message(message) {
  Subscribe(topic: String, client: Subject(message))
  Unsubscribe(topic: String, client: Subject(message))
  Publish(topic: String, message: message)
}

/// Returns the pubsub worker to add to a supervisor. Pass the same name to
/// `process.named_subject` to talk to it.
pub fn worker(
  named: Name(Message(message)),
) -> ChildSpecification(Subject(Message(message))) {
  supervision.worker(fn() {
    logging.log(logging.Info, "Starting pubsub worker")

    dict.new()
    |> actor.new
    |> actor.on_message(handle_message)
    |> actor.named(named)
    |> actor.start
  })
}

pub fn subscribe(
  pubsub: Subject(Message(message)),
  topic topic: String,
  client client: Subject(message),
) -> Nil {
  process.send(pubsub, Subscribe(topic:, client:))
}

pub fn unsubscribe(
  pubsub: Subject(Message(message)),
  topic topic: String,
  client client: Subject(message),
) -> Nil {
  process.send(pubsub, Unsubscribe(topic:, client:))
}

pub fn publish(
  pubsub: Subject(Message(message)),
  topic topic: String,
  message message: message,
) -> Nil {
  process.send(pubsub, Publish(topic:, message:))
}

fn handle_message(
  topics: Dict(String, List(Subject(message))),
  message: Message(message),
) -> actor.Next(Dict(String, List(Subject(message))), Message(message)) {
  case message {
    Subscribe(topic:, client:) -> {
      let topics =
        dict.upsert(in: topics, update: topic, with: fn(clients) {
          case clients {
            Some(clients) -> [client, ..clients]
            None -> {
              logging.log(logging.Info, "Creating topic " <> topic)
              [client]
            }
          }
        })

      log_client("Subscribing client ", client, " to topic " <> topic)

      actor.continue(topics)
    }

    Unsubscribe(topic:, client:) -> {
      log_client("Unsubscribing client ", client, " from topic " <> topic)

      let topics = case dict.get(topics, topic) {
        Ok([_client]) | Ok([]) -> {
          logging.log(logging.Info, "Dropping topic " <> topic)
          dict.drop(topics, [topic])
        }
        Ok(clients) ->
          list.filter(clients, fn(subscribed) { subscribed != client })
          |> dict.insert(topics, topic, _)
        Error(Nil) -> topics
      }

      actor.continue(topics)
    }

    Publish(topic:, message:) -> {
      case dict.get(topics, topic) {
        Ok(clients) -> {
          list.each(clients, process.send(_, message))

          { "Published to " <> topic <> ", " <> client_count(clients) }
          |> logging.log(logging.Info, _)
        }
        Error(Nil) ->
          logging.log(logging.Info, "Nobody is subscribed to " <> topic)
      }

      actor.continue(topics)
    }
  }
}

fn client_count(clients: List(Subject(message))) -> String {
  case list.length(clients) {
    1 -> "1 client"
    count -> int.to_string(count) <> " clients"
  }
}

fn log_client(before: String, client: Subject(message), after: String) -> Nil {
  let assert Ok(pid) = process.subject_owner(client)

  logging.log(logging.Info, before <> pid_to_string(pid) <> after)
}

fn pid_to_string(pid: Pid) -> String {
  charlist.to_string(pid_to_list(pid))
}

@external(erlang, "erlang", "pid_to_list")
fn pid_to_list(pid: Pid) -> Charlist
