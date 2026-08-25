# Changelog

## v6.0.0

- `sse`'s `on_init` function now receives the stream connection and a 
  `process.Selector` and returns the starting state along with that selector.
- Replace `SseNext` and `WebsocketNext` with a single `Next` and their eight
  constructors with `continue`, `continue_with_selector`, `stop` and
  `stop_abnormal`.

## v5.0.2

- Fix the previous fix to be an actual fix.

## v5.0.1

- Fix ffi file names to avoid issues with vendored glisten.

## v5.0.0

### Server

- Add support for Unix sockets.
- Add support for in-memory TLS certificates.
- Rename `enable_tls` to `with_tls`, which now takes the certificate source as a
  `Tls` value: `Disk`, `Pem` or `Der`.
- Add `with_client_verification`, which requires clients to present a
  certificate signed by a given authority and refuses those that do not.
- Require listener and connection factory names in `new` to prevent atom table
  exhaustion.
- Remove `with_name`.
- Remove `on_crash`. A crashing handler now always answers 500.
- Pass the listener to `get_server_info` as a `process.Subject(listener.Message)`
  instead of a `process.Name`.
- Rename the `interface` label of `bind` to `to`, and the `port` label of
  `listening` to `on`.
- Drop the argument labels of `ip_address_to_string`, `get_client_info` and
  `get_server_info`.

### HTTP/1

- Replace `erlang:decode_packet` with ewe's own parser.
- Add `Http1Options`, `default_http1_options` and `with_http1` to set the limits
  and timeouts for every HTTP/1 connection. The request line, header line and
  header count limits, chunk size line limit, idle and body read timeouts, and
  the auto drain limit and chunk size. A value outside the range a field accepts
  is replaced with the default and logged as a warning when the server starts.
- Move `idle_timeout` from a builder function to a field of `Http1Options`.

### HTTP/2

- Add HTTP/2 support! WebSockets need extended CONNECT over HTTP/2 which ewe
  does not negotiate yet, so for now any `websocket` answers 501 on an HTTP/2
  connection.
- Add `Http2Options`, `default_http2_options` and `with_http2` to set the limits
  and timeouts for every HTTP/2 connection. Concurrent streams, window sizes and
  their refill marks, frame and header list sizes, the HPACK table size, the
  CONTINUATION and header block caps, the Rapid Reset window and threshold, the
  handshake, drain and body read timeouts, and the file read threshold. A value
  outside the range a field accepts is replaced with the default and logged as a 
  warning when the server starts.

### Requests and responses

- Remove the `Request` and `Response` aliases.
- Rename `ResponseBody` to `Body`.
- Rename the `bytes_limit` label of `read_body` to `limit`.
- Take the `Connection` as the first argument of `file`.
- Replace `stream_body` with `read_body_chunk`. No consumer API anymore.
- Flush any request body the handler did not read, so the socket can be reused
  for the next request. Past the `auto_drain_limit` of `Http1Options`, 1 MB by
  default, the connection is closed instead.
- Frame responses on the server: ewe computes `content-length` or
  `transfer-encoding: chunked` for a streamed body and drops the handler's own
  `content-length`, `transfer-encoding` and `date` headers.
- Replace `chunked_body`/`send_chunk`/`chunked_continue`/`chunked_stop` with
  `stream_response`/`send_chunk`/`finish_chunk`/`finish_response`. No init/loop
  callback for response streaming anymore.
- Run response streaming, server-sent events and WebSockets in the connection
  process instead of spawning a process per response.
- Send functions now fail with `SendError` instead of a raw `glisten` socket
  reason: `ConnectionClosed`, `StreamReset`, `SendTimedOut`, or a `SocketError`
  carrying a `SocketReason`. A reason ewe does not classify comes back as
  `UnknownReason` and is logged. `send_error_to_string` and
  `socket_reason_to_string` describe either of them.

### Server-Sent Events

- Rename `SSEConnection`, `SSEEvent` and `SSENext` to `SseConnection`,
  `SseEvent` and `SseNext`.
- Add `comment` for sending an SSE comment, which keeps an idle stream from
  being closed by an intermediary.

### WebSocket

- Rename `upgrade_websocket` to `websocket`, matching `sse`.
- Rename the `WebsocketMessage` variants to `TextFrame`, `BinaryFrame` and
  `UserMessage`.
- Replace the `CloseCode` variants that each carried their own data with
  `CloseReason`, either `NoCloseReason` or a code and a description, which
  `send_close_frame` takes.

## v4.0.1 - 04.06.2026

- Fix issue with `decode_packet` not handling http method as binary.

## v4.0.0 - 27.05.2026

- Resolve misleading IPv6 support documentation.
- Rename `enable_ipv6` to `force_ipv6`.

## v3.0.8 - 21.04.2026

- Bumb `gleam_stdlib` to the v1.

## v3.0.7 - 01.04.2026

- Bump `websocks` to next major.

## v3.0.6 - 30.03.2026

- Sanitize CRLF sequences in outgoing HTTP response headers.
- Eliminate `string.lowercase` in a codebase: validate and lowercase header field names in a single pass, validate and lowercase important protocol header values (like `transfer-encoding`, `connection`, `upgrade` and more) at parse time.
- Include validation of trailer header field names and values during chunked body parsing.
- Remove redundant UTF-8 validation on WebSocket `Text` frame payloads.

# v3.0.5 - 15.03.2026

- Remove all usage of `string.inspect` as it is an anti-pattern for logging.
- Fix infinite loop and adjust allowed entries for trailer headers.
- Improve and expand logging messages.
- Improve path parsing.

# v3.0.4 - 13.03.2026

- Fix glisten being incorrectly supervised on start.

# v3.0.3 - 13.03.2026

- Update glisten to next major release.
- Default `on_start` handler now uses `io.println` in addition to logging, so the startup message is visible even without a logger configured.

# v3.0.2 - 23.02.2026

- Gracefully handle HTTP/2 connections: h2c upgrade requests are served as HTTP/1.1, and direct HTTP/2 connections receive a GOAWAY with HTTP_1_1_REQUIRED instead of being silently dropped.
- Fixed HTTP/2 prior-knowledge detection in ffi
- Refactored internal buffer module and moved to `http1`

# v3.0.1 - 25.01.2026

- Fix README file

# v3.0.0 - 25.01.2026

- Fix bug where WebSocket was unusable with TLS enabled
- Remove `bind_all`
- Adjust documentation
- Add HTTPS example

# v2.1.3 - 19.01.2026

- Bump dependency package versions
- Move examples to appropriate folder
- Improve examples with useful documentation lines
- Replace active socket tcp message decoding for WebSocket selector

# v2.1.2 - 19.11.2025

- Improve internal codebase
- Replace `exception` module with a package

# v2.1.1 - 14.11.2025

- Bring back active socket option for SSE

# v2.1.0 - 09.11.2025

- Add `send_close_frame` function for the WebSocket API
- Add `CloseCode` for various close frames

# v2.0.3 - 06.11.2025

- Replace `gramps` with `websocks` package
- Remove alias names for internal stream modules
- Improve script that change documentation
- Move `gleam_crypto` package as dev dependency 

# v2.0.2

- Refactor internal handler code
- Support multiple directives in the `connection` header during upgrade to WebSocket

# v2.0.1

- Update the websocket implementation to set active mode to `Count` to receive N messages, rather than setting `Once` every message

# v2.0.0

- Change API of chunked response to match other streaming APIs
- Handler's process is not waiting until streaming actors are done
- All new actors that are spawned by streaming APIs are now being supervised with factory supervisor

# v1.0.1

- Ensure `compresso` package is fixed version

# v1.0.0

- Improve internal comments
- Add logging
- Remove deprecated `result.unwrap_both`
- Support for automatic `gzip` content encoding for HTTP responses except file sending. 

# v1.0.0-rc2

- Rename internal imports
- Fix invalid ffi file namings
- Add support for Server-Sent Events
- Better README file

# v1.0.0-rc1

- Adjust types & functions to follow responsibilities of a web server, completely excluding potential framework-like features.
- Improve validation of `upgrade` header when upgrading to WebSocket connection.
- Remove internal `information` actor for retrieving server information.
- Improve documentation.
- Expand files response body with optional size limit and offset.

# v0.10.0

### HTTP
- Add `date` header to responses.
- Add `Request` and `Response` aliases.
- Add new response body: `File` and `ChunkedData`. They can be set with `ewe.file` and `ewe.chunked`.
- Fix server still listening on a socket after `connection: close`.
- Keep-alive connection closes after 10_000 milliseconds of idling. Can be adjusted in builder using `ewe.idle_timeout`.

### WebSocket
- Add WebSocket connection failures for control frames with payloads up to 125 octets.
- Fix control frames matching to properly extract rest frames from a list of aggregated frames.
- Store incomplete frames in WebSocket state until they are fully received.
- Ensure unexpected continuation frames correctly cause an abnormal stop.
- Add handling for control frames interleaved with fragmented data frames.
- Overall match implementation to pass Autobahn TestSuite.


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
