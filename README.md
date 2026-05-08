![ewe](https://raw.githubusercontent.com/vshakitskiy/ewe/mistress/public/banner.jpg)

# 🐑 ewe

ewe [/juː/] - fluffy package for building web servers.

[![Package Version](https://img.shields.io/hexpm/v/ewe)](https://hex.pm/packages/ewe)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/ewe/)

## Installation

```sh
gleam add ewe@3 gleam_erlang gleam_otp gleam_http logging
```

## Getting Started

```gleam
import gleam/erlang/process
import logging
import gleam/http/response

import ewe.{type Request, type Response}

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  let assert Ok(_) =
    ewe.new(handler)
    |> ewe.bind("0.0.0.0")
    |> ewe.listening(port: 8080)
    |> ewe.start

  process.sleep_forever()
}

fn handler(_req: Request) -> Response {
  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(ewe.TextData("Hello, World!"))
}
```

## Usage

### [HTTPS](examples/src/https.gleam)

To enable HTTPS support via TLS, use [`ewe.enable_tls`](https://hexdocs.pm/ewe/ewe.html#enable_tls) with paths to your certificate and key files. The server validates the certificate and key files on startup and will crash if they're missing or invalid.

```gleam
ewe.new(handler)
|> ewe.bind("0.0.0.0")
|> ewe.listening(port: 8080)
|> ewe.enable_tls(
  certificate_file: "priv/localhost.crt",
  key_file: "priv/localhost.key",
)
|> ewe.start
```

### [Sending Response](examples/src/sending_response.gleam)

`ewe` provides several response body types (see [`ewe.ResponseBody`](https://hexdocs.pm/ewe/ewe.html#ResponseBody) type). Request handler must return [`response.Response`](https://hexdocs.pm/gleam_http/gleam/http/response.html#Response) type with [`ewe.ResponseBody`](https://hexdocs.pm/ewe/ewe.html#ResponseBody). You can also use [`ewe.Request`](https://hexdocs.pm/ewe/ewe.html#Request)/[`ewe.Response`](https://hexdocs.pm/ewe/ewe.html#Response) as they are aliases for `request.Request(Connection)`(see [`request.Request`](https://hexdocs.pm/gleam_http/gleam/http/request.html#Request) & [`ewe.Connection`](https://hexdocs.pm/ewe/ewe.html#Connection))/`response.Response(ResponseBody)`.


```gleam
import gleam/crypto
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/result

import ewe.{type Connection, type ResponseBody}

fn handler(req: Request(Connection)) -> Response(ResponseBody) {
  case request.path_segments(req) {
    ["hello", name] -> {
      // Use TextData for text responses.
      // 
      response.new(200)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Hello, " <> name <> "!"))
    }
    ["bytes", amount] -> {
      // Use BitsData for binary responses.
      // 
      let random_bytes =
        int.parse(amount)
        |> result.unwrap(0)
        |> crypto.strong_random_bytes()

      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(ewe.BitsData(random_bytes))
    }
    _ ->
      // Use Empty for responses with no body (like 404, 204, etc).
      // 
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}
```

### [Reading Body](examples/src/reading_body.gleam)

To read the body of a request, use [`ewe.read_body`](https://hexdocs.pm/ewe/ewe.html#read_body). This function is intended for cases where the entire body can safely be loaded into memory.

```gleam
import gleam/http/request
import gleam/http/response
import gleam/result

import ewe.{type Request, type Response}

fn handler(req: Request) -> Response {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("application/octet-stream")

  // Read the entire request body into memory with a 10KB limit. This blocks
  // until the full body is received.
  // 
  case ewe.read_body(req, 10_240) {
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
```

### [Streaming Body](examples/src/streaming_body.gleam)

For larger request bodies, [`ewe.stream_body`](https://hexdocs.pm/ewe/ewe.html#stream_body) provides a streaming interface. It produces a [`ewe.Consumer`](https://hexdocs.pm/ewe/ewe.html#Consumer) which can be called repeatedly to read fixed-size chunks. This enables efficient handling of large payloads without buffering them fully.

As for responses, use [`ewe.chunked_body`](https://hexdocs.pm/ewe/ewe.html#chunked_body) to send a chunked response for streaming data to the client. The response body is managed through [`ewe.ChunkedBody`](https://hexdocs.pm/ewe/ewe.html#ChunkedBody) and chunks are sent by calling [`ewe.send_chunk`](https://hexdocs.pm/ewe/ewe.html#send_chunk). Handlers control the connection lifecycle with [`ewe.ChunkedNext`](https://hexdocs.pm/ewe/ewe.html#ChunkedNext). 


```gleam
pub type Message {
  Chunk(BitArray)
  Done
  BodyError(ewe.BodyError)
}

// Recursively consume chunks from the request body and send them to the
// chunked response handler via the subject.
// 
fn stream_resource(
  consumer: ewe.Consumer,
  subject: Subject(Message),
  chunk_size: Int,
) -> Nil {
  process.sleep(int.random(250))
  // Call the consumer with the chunk size. It returns the next chunk of data
  // and a new consumer for the remaining body.
  // 
  case consumer(chunk_size) {
    Ok(ewe.Consumed(data, next)) -> {
      logging.log(logging.Info, {
        "Consumed " <> int.to_string(bit_array.byte_size(data)) <> " bytes."
      })

      process.send(subject, Chunk(data))
      // Recursively process the next chunk.
      // 
      stream_resource(next, subject, chunk_size)
    }
    Ok(ewe.Done) -> process.send(subject, Done)
    Error(body_error) -> process.send(subject, BodyError(body_error))
  }
}

fn handle_stream(req: Request, chunk_size: Int) -> Response {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("application/octet-stream")

  // Get a consumer function for streaming the request body.
  // 
  case ewe.stream_body(req) {
    Ok(consumer) -> {
      // Set up a chunked response. The response is sent in chunks as we
      // consume the request body.
      // 
      ewe.chunked_body(
        req,
        response.new(200) |> response.set_header("content-type", content_type),
        // Spawn a separate process to consume the body and send chunks.
        // This prevents blocking the handler while reading data.
        // 
        on_init: fn(subject) {
          let _pid =
            fn() { stream_resource(consumer, subject, chunk_size) }
            |> process.spawn
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
```

### [Serving Files](examples/src/serving_files.gleam)

Static files can be sent using [`ewe.file`](https://hexdocs.pm/ewe/ewe.html#file). It accepts a path and optional `offset`/`limit` parameters. This allows serving HTML pages, assets, or binary files with minimal effort.

```gleam
import gleam/http/response
import gleam/string

fn serve_file(path: String) -> Response {
  // Resolve the URL path against the `public` directory and confirm the result 
  // stays inside it.
  //
  let dir = absname("public")
  let relative = string.drop_start(path, 1)
  let resolved = absname_join(dir, relative)

  case string.starts_with(resolved, dir <> "/") {
    True -> {
      // Load file from disk using ewe.file(). This efficiently streams the file
      // content without loading it entirely into memory.
      //
      case ewe.file(resolved, offset: None, limit: None) {
        Ok(file) -> {
          // Using "application/octet-stream" is safe for any file type, but you
          // may want to specify content-type based on file extension in 
          // production.
          //
          response.new(200)
          |> response.set_header("content-type", "application/octet-stream")
          |> response.set_body(file)
        }
        Error(_) -> not_found()
      }
    }
    False -> not_found()
  }
}

@external(erlang, "filename", "absname")
fn absname(path: String) -> String

@external(erlang, "filename", "absname_join")
fn absname_join(dir: String, file: String) -> String
```

### [WebSocket](examples/src/websocket.gleam)

Use [`ewe.upgrade_websocket`](https://hexdocs.pm/ewe/ewe.html#upgrade_websocket) to switch an HTTP request into a WebSocket connection. Incoming messages are represented as [`ewe.WebsocketMessage`](https://hexdocs.pm/ewe/ewe.html#WebsocketMessage). Outgoing frames are sent with [`ewe.send_text_frame`](https://hexdocs.pm/ewe/ewe.html#send_text_frame) or [`ewe.send_binary_frame`](https://hexdocs.pm/ewe/ewe.html#send_binary_frame). Handlers control the connection lifecycle with [`ewe.WebsocketNext`](https://hexdocs.pm/ewe/ewe.html#WebsocketNext).

```gleam
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/request
import gleam/http/response
import logging

import ewe.{type Request, type Response}

type PubSubMessage {
  Subscribe(topic: String, client: Subject(Broadcast))
  Publish(topic: String, message: Broadcast)
  Unsubscribe(topic: String, client: Subject(Broadcast))
}

type Broadcast {
  Text(String)
  Bytes(BitArray)
}

type WebsocketState {
  WebsocketState(
    pubsub: Subject(PubSubMessage),
    topic: String,
    client: Subject(Broadcast),
  )
}

fn handler(req: Request, pubsub: Subject(PubSubMessage)) -> Response {
  case request.path_segments(req) {
    ["topic", topic] -> handle_topic(req, pubsub, topic)
    _ ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
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
```

### [Server-Sent Events](examples/src/sse.gleam)


Use [`ewe.sse`](https://hexdocs.pm/ewe/ewe.html#sse) to establish a Server-Sent Events connection for real-time data streaming to clients. The connection is managed through [`ewe.SSEConnection`](https://hexdocs.pm/ewe/ewe.html#SSEConnection) and events are sent with [`ewe.send_event`](https://hexdocs.pm/ewe/ewe.html#send_event). Handlers control the connection lifecycle with [`ewe.SSENext`](https://hexdocs.pm/ewe/ewe.html#SSENext). This enables efficient one-way communication for live updates, notifications, or real-time data feeds.

```gleam
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/response

import ewe

type PubSubMessage {
  Subscribe(client: Subject(String))
  Unsubscribe(client: Subject(String))
  Publish(String)
}

fn handler(req: ewe.Request, pubsub: Subject(PubSubMessage)) -> ewe.Response {
  case req.method, req.path {
    http.Get, "/sse" ->
      // Establish a Server-Sent Events connection. SSE is a one-way channel
      // from server to client. The connection stays open and the server can
      // push events at any time.
      // 
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
      case ewe.read_body(req, 128) {
        Ok(req) -> {
          case bit_array.to_string(req.body) {
            Ok(message) -> {
              process.send(pubsub, Publish(message))

              response.new(200) |> response.set_body(ewe.Empty)
            }
            Error(Nil) -> response.new(400) |> response.set_body(ewe.Empty)
          }
        }
        Error(_) -> response.new(400) |> response.set_body(ewe.Empty)
      }
    }

    _, _ -> response.new(404) |> response.set_body(ewe.Empty)
  }
}
```

## API Reference

For detailed API documentation, see [hexdocs.pm/ewe](https://hexdocs.pm/ewe/ewe.html).
