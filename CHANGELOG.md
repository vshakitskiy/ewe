# Changelog

# Unreleased

- Add WebSocket connection failures for control frames with payloads up to 125 octets.
- Fix control frames matching to properly extract rest frames from a list of aggregated frames.
- Store incomplete frames in WebSocket state until they are fully received.
- Ensure unexpected continuation frames correctly cause an abnormal stop.
- Add handling for control frames interleaved with fragmented data frames.
- Add `date` header to responses.

# v0.9.0

- Add `ewe.continue_with_selector` to continue processing WebSocket messages, including selector for custom messages.
- Add proper conditions for `connection: close`.
- Expand request's host header parsing.
- Send response with proper status code on HTTP parser failure before closing connection.
- HTTP parser now handles host header duplication, invalid content-length format, and headers with invalid control characters.

# v0.8.1

- Quick documentation fix

# v0.8.0

- Add `ewe.stream_body` for streaming the request body (including chunked encoding).
- Simplified `Builder` type.
- Add internal `Buffer` type.
- Add `ewe.quiet` for setting empty `on_start` function.
- Rename multiple functions and types, add aliases for clarity.
- Add `ewe.on_close` argument for WebSocket upgrade function.
- Add bunch of comments and separated internals into logical sections.

# v0.7.0

- Add support for custom user messages in WebSocket handlers. The `on_init` function now receives a `process.Selector` that can be used to listen for custom messages sent from other parts of the application.
- Custom messages are delivered to WebSocket handlers as `ewe.User(message)` type.
- Add permessage-deflate compression support for WebSocket connections. When enabled, messages are automatically compressed using defalte algorithm, reducing bandwidth usage for text-heavy applications.

# v0.6.0

- HTTP parser now handles trailers when working with chunked encoding.
- Remove `ewe.with_read_body`, leaving `ewe.read_body` as the only option to read the body.
- Improve documentation page by adding headers for each logical section (see [smol](https://gitlab.com/arkandos/smol/-/blob/main/src/smol.gleam?ref_type=heads)).
- Improve WebSockets. Users can now specify state with `on_init` function. WebSocket handler accepts connection, user's state and message. `ewe.continue` requires user to specify new state.
- Add `ewe.send_binary_frame` and `ewe.send_text_frame`, allowing to send messages back to the client.

# v0.5.0

- Response body must now be of type `ResponseBody`. To set the response body, use the following functions: `ewe.text`, `ewe.bytes`, `ewe.bits`, `ewe.string_tree`, `ewe.empty`, `ewe.json`.
- HTTP parser now handles `Expect: 100-continue`.
- Optimize formatting of popular HTTP fields without wasting time on transforming from `BitArray` to `String`.
- Duplicate request headers are now being combined (except `set-cookie`).

# v0.4.0

- Implement WebSocket protocol; request can be upgraded in handler using `ewe.upgrade_websocket`.
- Every message received in WebSocket handler is of `WebsocketMessage` type.
- Handler must return a `Next` type, which can be created using `ewe.continue`, `ewe.stop` and `ewe.stop_abnormal`.
- Add `ewe.bits` for setting response body from `BitArray` type.
- Add experimental `ewe.use_expression`.
- Rename internal file from `response.gleam` to `encoder.gleam`, matching `decoder.gleam` file.

# v0.3.0

- Remove atom values from ffi's `decode_packet`.
- Request handler is now rescued during crashes, thanks to ffi's `rescue` function.
- Add new `on_crash` option that sends a custom response when the handler is rescued. Use `ewe.on_crash` to configure this option.
- Glisten server is now part of a supervision tree along with an information actor for managing server state. Server information can be extracted using `ewe.get_server_info`.
- Add new `info_worker_name` option for naming the information worker's subject. Use `ewe.with_name` to configure this option.
- `ewe.client_stats` is now named `ewe.get_client_info` for consistency with the server getter pattern.
- Add `ewe.with_random_port` that sets `port` to `0`.
- Add `ewe.with_read_body` that allows reading the body before passing the request to the handler.
- Add `ewe.json`, `ewe.text`, `ewe.bytes` for different response body.
- Fill documentation