import ewe
import ewe/internal/http2/client.{Response}
import ewe/internal/http2/frame
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

fn app(req: request.Request(ewe.Connection)) -> response.Response(ewe.Body) {
  case request.path_segments(req) {
    ["hello"] -> text(200, "hello")
    ["echo"] ->
      case ewe.read_body(req, 10_000_000) {
        Ok(req) ->
          response.new(200)
          |> response.set_body(ewe.Bytes(bytes_tree.from_bit_array(req.body)))
        Error(_error) -> text(400, "")
      }
    ["trailer"] ->
      case ewe.read_body(req, 10_000_000) {
        Ok(req) ->
          text(200, result.unwrap(request.get_header(req, "x-trailer"), ""))
        Error(_error) -> text(400, "")
      }
    ["file"] -> {
      let assert Ok(body) =
        ewe.file(req.body, served_file, offset: None, limit: None)
      response.set_body(response.new(200), body)
    }
    ["big", size] -> {
      let assert Ok(size) = int.parse(size)
      response.new(200)
      |> response.set_body(ewe.Bytes(bytes_tree.from_bit_array(filler(size))))
    }
    ["large-header"] ->
      response.new(200)
      |> response.set_header("x-large", string.repeat("~", 20_000))
      |> response.set_body(ewe.Empty)
    ["no-content"] -> text(204, "never sent")
    ["streamed-no-content"] -> {
      use writer <- ewe.stream_response(response.new(204))
      ewe.finish_chunk(writer, <<"never sent":utf8>>)
    }
    ["informational"] -> text(103, "")
    ["streamed-out-of-range"] -> {
      use writer <- ewe.stream_response(response.new(600))
      ewe.finish_chunk(writer, <<"never sent":utf8>>)
    }
    ["unsafe"] -> text(200, "") |> response.set_header("x-a", "a\r\nb")
    ["unsafe-stream"] -> {
      use writer <- ewe.stream_response(
        response.new(200) |> response.set_header("x-a", "a\r\nb"),
      )
      ewe.finish_chunk(writer, <<"never sent":utf8>>)
    }
    ["stream"] -> {
      use writer <- ewe.stream_response(response.new(200))
      use writer <- result.try(ewe.send_chunk(writer, <<"a":utf8>>))
      use writer <- result.try(ewe.send_chunk(writer, <<"b":utf8>>))
      ewe.finish_chunk(writer, <<"c":utf8>>)
    }
    ["hang"] -> {
      process.sleep_forever()
      text(200, "")
    }
    ["crash"] -> panic as "the handler crashed on purpose"
    _path ->
      case req.method {
        http.Connect -> text(200, "tunnel to " <> req.host)
        _method -> text(404, "")
      }
  }
}

const served_file = "build/ewe_http2_served_file.bin"

@external(erlang, "ewe_http2_client_ffi", "write_file")
fn write_file(path: String, data: BitArray) -> Nil

fn text(status: Int, body: String) -> response.Response(ewe.Body) {
  response.new(status) |> response.set_body(ewe.Text(body))
}

fn filler(size: Int) -> BitArray {
  bit_array.concat(list.repeat(<<"x":utf8>>, size))
}

fn ready() -> client.Client {
  client.serve(app) |> client.handshake([])
}

fn ready_with(options: ewe.Http2Options) -> client.Client {
  client.serve_with(app, options) |> client.handshake([])
}

fn options() -> ewe.Http2Options {
  ewe.default_http2_options()
}

fn expect_goaway(client: client.Client, error: frame.ErrorCode) -> Nil {
  let #(received, client) =
    client.skip_until(client, fn(received) {
      case received {
        frame.Goaway(..) -> True
        _frame -> False
      }
    })
  let assert frame.Goaway(error: sent, ..) = received
  assert sent == error
  assert client.is_closed(client)
}

fn expect_reset(
  client: client.Client,
  stream_id: Int,
  error: frame.ErrorCode,
) -> client.Client {
  let #(received, client) = client.receive(client)
  assert received == frame.RstStream(stream_id:, error:)
  client
}

pub fn frame_before_client_settings_is_protocol_error_test() {
  client.serve(app)
  |> client.connect
  |> client.get(1, "/hello")
  |> expect_goaway(frame.ProtocolError)
}

pub fn missing_client_settings_times_out_as_protocol_error_test() {
  client.serve_with(app, ewe.Http2Options(..options(), handshake_timeout: 50))
  |> client.connect
  |> expect_goaway(frame.ProtocolError)
}

pub fn unacknowledged_settings_time_out_test() {
  let client =
    client.serve_with(app, ewe.Http2Options(..options(), handshake_timeout: 50))
    |> client.connect
    |> client.send(frame.Settings(ack: False, settings: []))

  expect_goaway(client, frame.SettingsTimeout)
}

pub fn simple_request_test() {
  let #(received, _client) =
    ready()
    |> client.get(1, "/hello")
    |> client.response(1)

  let assert Response(status: 200, headers:, body: <<"hello":utf8>>) = received
  assert list.key_find(headers, "content-length") == Ok("5")
  assert result.is_ok(list.key_find(headers, "date"))
}

pub fn response_body_respects_peer_max_frame_size_test() {
  let client = ready() |> client.get(1, "/big/40000")
  let #(_headers, client) = client.receive(client)
  let #(first, client) = client.receive(client)
  let #(second, client) = client.receive(client)
  let #(third, _client) = client.receive(client)

  let assert frame.Data(size: 16_384, end_stream: False, ..) = first
  let assert frame.Data(size: 16_384, end_stream: False, ..) = second
  let assert frame.Data(size: 7232, end_stream: True, ..) = third
}

pub fn large_response_field_block_continues_in_continuation_test() {
  let client = ready() |> client.get(1, "/large-header")
  let #(headers, client) = client.receive(client)
  let #(continuation, _client) = client.receive_any(client)

  let assert frame.Headers(end_headers: False, end_stream: True, ..) = headers
  let assert frame.Continuation(stream_id: 1, end_headers: True, ..) =
    continuation
}

pub fn discarded_field_block_still_updates_hpack_test() {
  let client =
    client.headers(ready(), 1, client.request_fields("GET", "/hang"), True)
  let client = client.headers(client, 1, [#("x-indexed", "value")], True)
  let client = expect_reset(client, 1, frame.StreamClosed)

  let #(received, _client) =
    client.headers(
      client,
      3,
      list.append(client.request_fields("GET", "/hello"), [
        #("x-indexed", "value"),
      ]),
      True,
    )
    |> client.response(3)

  let assert Response(status: 200, ..) = received
}

pub fn header_table_size_from_client_is_honoured_test() {
  let client =
    client.serve(app)
    |> client.handshake([frame.HeaderTableSize(0)])
    |> client.get(1, "/hello")
  let #(received, _client) = client.receive(client)

  let assert frame.Headers(fragment: <<0x20, _rest:bits>>, ..) = received
}

pub fn streams_beyond_the_limit_are_refused_test() {
  ready_with(ewe.Http2Options(..options(), max_concurrent_streams: Some(2)))
  |> client.get(1, "/hang")
  |> client.get(3, "/hang")
  |> client.get(5, "/hang")
  |> expect_reset(5, frame.RefusedStream)
}

pub fn handlers_still_stopping_count_toward_the_limit_test() {
  let parent = process.new_subject()
  let handler = fn(req: request.Request(ewe.Connection)) {
    process.send(parent, Nil)
    process.trap_exits(True)
    process.sleep(1000)
    app(req)
  }

  let client =
    client.serve_with(
      handler,
      ewe.Http2Options(..options(), max_concurrent_streams: Some(1)),
    )
    |> client.handshake([])
    |> client.get(1, "/hello")
  let assert Ok(Nil) = process.receive(parent, 1000)

  client
  |> client.send(frame.RstStream(1, frame.Cancel))
  |> client.get(3, "/hello")
  |> expect_reset(3, frame.RefusedStream)
}

fn reset_hanging(
  client: client.Client,
  stream_ids: List(Int),
) -> client.Client {
  use client, stream_id <- list.fold(stream_ids, client)

  client
  |> client.get(stream_id, "/hang")
  |> client.send(frame.RstStream(stream_id, frame.Cancel))
}

pub fn rapid_client_resets_are_enhance_your_calm_test() {
  ready_with(ewe.Http2Options(..options(), rapid_reset_threshold: 3))
  |> reset_hanging([1, 3, 5, 7])
  |> expect_goaway(frame.EnhanceYourCalm)
}

pub fn reset_count_starts_over_each_window_test() {
  let client =
    ready_with(
      ewe.Http2Options(
        ..options(),
        rapid_reset_window: 100,
        rapid_reset_threshold: 2,
      ),
    )
    |> reset_hanging([1, 3])
  process.sleep(150)

  let #(received, _client) =
    reset_hanging(client, [5, 7])
    |> client.get(9, "/hello")
    |> client.response(9)
  let assert Response(status: 200, ..) = received
}

pub fn resets_after_the_handler_returned_are_not_counted_test() {
  let client =
    ready_with(ewe.Http2Options(..options(), rapid_reset_threshold: 1))
    |> list.fold([1, 3], _, fn(client, stream_id) {
      let #(_headers, client) =
        client
        |> client.get(stream_id, "/big/100000")
        |> client.skip_until(fn(received) {
          case received {
            frame.Headers(stream_id: id, ..) -> id == stream_id
            _frame -> False
          }
        })
      client.send(client, frame.RstStream(stream_id, frame.Cancel))
    })

  let #(received, _client) =
    client
    |> client.send(frame.Ping(ack: False, data: <<"no-reset":utf8>>))
    |> client.skip_until(fn(received) {
      case received {
        frame.Ping(ack: True, ..) | frame.Goaway(..) -> True
        _frame -> False
      }
    })
  let assert frame.Ping(ack: True, ..) = received
}

pub fn provoked_server_resets_are_enhance_your_calm_test() {
  let client =
    ready_with(ewe.Http2Options(..options(), rapid_reset_threshold: 3))

  let client =
    [1, 3, 5]
    |> list.fold(client, fn(client, stream_id) {
      client
      |> client.get(stream_id, "/hang")
      |> client.send(frame.WindowUpdate(stream_id, 0))
      |> expect_reset(stream_id, frame.ProtocolError)
    })

  client
  |> client.get(7, "/hang")
  |> client.send(frame.WindowUpdate(7, 0))
  |> expect_goaway(frame.EnhanceYourCalm)
}

pub fn reset_kills_a_handler_that_does_not_stream_test() {
  let parent = process.new_subject()
  let handler = fn(req: request.Request(ewe.Connection)) {
    process.send(parent, process.self())
    app(req)
  }

  let client =
    client.serve(handler)
    |> client.handshake([])
    |> client.get(1, "/hang")
  let assert Ok(pid) = process.receive(parent, 1000)
  let _client = client.send(client, frame.RstStream(1, frame.Cancel))

  assert client.wait_until(fn() { !process.is_alive(pid) }, 50)
}

pub fn sse_ends_on_reset_during_a_blocked_write_test() {
  let writing = process.new_subject()
  let closed = process.new_subject()
  let handler = fn(_req: request.Request(ewe.Connection)) {
    ewe.sse(
      response.new(200),
      on_init: fn(_conn, selector) {
        let ticks = process.new_subject()
        process.send(ticks, Nil)
        #(ticks, process.select(selector, ticks))
      },
      handler: fn(conn, ticks, _tick) {
        process.send(writing, Nil)
        let _sent = ewe.send_event(conn, ewe.event(string.repeat("x", 10_000)))
        process.send(ticks, Nil)
        ewe.continue(ticks)
      },
      on_close: fn(_conn, _ticks) { process.send(closed, Nil) },
    )
  }

  let client =
    client.serve_with(
      handler,
      ewe.Http2Options(..options(), send_buffer_limit: 1000),
    )
    |> client.handshake([frame.InitialWindowSize(0)])
    |> client.get(1, "/")
  let assert Ok(Nil) = process.receive(writing, 1000)
  let _client = client.send(client, frame.RstStream(1, frame.Cancel))

  let assert Ok(Nil) = process.receive(closed, 1000)
}

pub fn streaming_writer_learns_of_reset_test() {
  let parent = process.new_subject()
  let handler = fn(_req: request.Request(ewe.Connection)) {
    use writer <- ewe.stream_response(response.new(200))
    use writer <- result.try(ewe.send_chunk(writer, <<"a":utf8>>))
    process.send(parent, Ok(Nil))
    process.sleep(100)
    let sent = ewe.send_chunk(writer, <<"b":utf8>>)
    process.send(parent, result.replace(sent, Nil))
    Ok(Nil)
  }

  let client =
    client.serve(handler)
    |> client.handshake([])
    |> client.get(1, "/")
  let assert Ok(Ok(Nil)) = process.receive(parent, 1000)
  let _client = client.send(client, frame.RstStream(1, frame.Cancel))

  assert process.receive(parent, 1000) == Ok(Error(ewe.StreamReset))
}

pub fn request_body_round_trips_test() {
  let body = filler(192_000)
  let client =
    ready() |> client.headers(1, client.request_fields("POST", "/echo"), False)
  let client =
    list.fold([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], client, fn(client, index) {
      let assert Ok(chunk) = bit_array.slice(body, index * 16_000, 16_000)
      client.data(client, 1, chunk, index == 11)
    })

  let #(received, _client) = client.response(client, 1)
  let assert Response(status: 200, body: echoed, ..) = received
  assert echoed == body
}

pub fn data_beyond_the_stream_window_is_flow_control_error_test() {
  ready_with(
    ewe.Http2Options(
      ..options(),
      initial_window_size: 16_384,
      recv_window_low_water_mark: 1,
      recv_window_high_water_mark: 16_384,
    ),
  )
  |> client.headers(1, client.request_fields("POST", "/hang"), False)
  |> client.data(1, filler(16_000), False)
  |> client.data(1, filler(1000), False)
  |> expect_reset(1, frame.FlowControlError)
}

pub fn response_waits_for_the_stream_window_test() {
  let client =
    client.serve(app)
    |> client.handshake([frame.InitialWindowSize(10)])
    |> client.get(1, "/big/25")
  let #(_headers, client) = client.receive(client)
  let #(first, client) = client.receive(client)
  let assert frame.Data(size: 10, end_stream: False, ..) = first
  assert client.is_quiet(client)

  let #(rest, _client) =
    client
    |> client.send(frame.WindowUpdate(1, 15))
    |> client.receive
  let assert frame.Data(size: 15, end_stream: True, ..) = rest
}

pub fn response_waits_for_the_connection_window_test() {
  let client =
    client.serve(app)
    |> client.handshake([frame.InitialWindowSize(1_000_000)])
    |> client.get(1, "/big/70000")
  let #(_headers, client) = client.receive(client)
  let client = drain(client, 65_535)
  assert client.is_quiet(client)

  let #(rest, _client) =
    client
    |> client.send(frame.WindowUpdate(0, 10_000))
    |> client.receive
  let assert frame.Data(size: 4465, end_stream: True, ..) = rest
}

fn drain(client: client.Client, remaining: Int) -> client.Client {
  case remaining {
    0 -> client
    _remaining -> {
      let #(received, client) = client.receive(client)
      let assert frame.Data(size:, ..) = received
      drain(client, remaining - size)
    }
  }
}

pub fn raised_initial_window_resumes_a_stalled_response_test() {
  let client =
    client.serve(app)
    |> client.handshake([frame.InitialWindowSize(10)])
    |> client.get(1, "/big/30")
  let #(_headers, client) = client.receive(client)
  let #(_first, client) = client.receive(client)

  let #(rest, _client) =
    client
    |> client.send(
      frame.Settings(ack: False, settings: [frame.InitialWindowSize(30)]),
    )
    |> client.receive
  let assert frame.Data(size: 20, end_stream: True, ..) = rest
}

pub fn content_length_without_data_is_malformed_test() {
  ready()
  |> client.headers(
    1,
    [#("content-length", "3"), ..client.request_fields("POST", "/echo")],
    True,
  )
  |> expect_reset(1, frame.ProtocolError)
}

pub fn continuation_limit_is_exact_test() {
  let client =
    ready_with(ewe.Http2Options(..options(), max_continuation_frames: 3))
  let #(block, client) =
    client.encode_fields(client, client.request_fields("GET", "/hello"))

  let #(received, _client) =
    client
    |> client.send(frame.Headers(1, True, False, None, block))
    |> client.send(frame.Continuation(1, False, <<>>))
    |> client.send(frame.Continuation(1, False, <<>>))
    |> client.send(frame.Continuation(1, True, <<>>))
    |> client.response(1)

  let assert Response(status: 200, ..) = received
}

pub fn continuation_flood_is_enhance_your_calm_test() {
  let client =
    ready_with(ewe.Http2Options(..options(), max_continuation_frames: 3))
    |> client.send(frame.Headers(1, True, False, None, <<0x82>>))

  list.fold([1, 2, 3, 4], client, fn(client, _index) {
    client.send(client, frame.Continuation(1, False, <<>>))
  })
  |> expect_goaway(frame.EnhanceYourCalm)
}

pub fn client_goaway_is_answered_and_closes_the_connection_test() {
  let #(received, client) =
    ready()
    |> client.send(frame.Goaway(0, frame.NoError, <<>>))
    |> client.receive

  let assert frame.Goaway(last_stream_id: 0, error: frame.NoError, ..) =
    received
  assert client.is_closed(client)
}

pub fn client_goaway_lets_open_streams_finish_test() {
  let #(received, client) =
    ready()
    |> client.get(1, "/big/100")
    |> client.send(frame.Goaway(0, frame.NoError, <<>>))
    |> client.response(1)

  let assert Response(status: 200, ..) = received
  assert client.is_closed(client)
}

pub fn idle_connection_is_sent_goaway_test() {
  ready_with(ewe.Http2Options(..options(), idle_timeout: 50))
  |> expect_goaway(frame.NoError)
}

pub fn early_response_asks_the_client_to_stop_sending_test() {
  let client =
    ready()
    |> client.headers(1, client.request_fields("POST", "/hello"), False)
  let #(received, client) = client.response(client, 1)
  let assert Response(status: 200, ..) = received

  let client = expect_reset(client, 1, frame.NoError)
  assert client
    |> client.data(1, <<"late":utf8>>, True)
    |> client.is_quiet
}

pub fn trailers_reach_the_handler_test() {
  let #(received, _client) =
    ready()
    |> client.headers(1, client.request_fields("POST", "/trailer"), False)
    |> client.data(1, <<"body":utf8>>, False)
    |> client.headers(1, [#("x-trailer", "present")], True)
    |> client.response(1)

  let assert Response(status: 200, body: <<"present":utf8>>, ..) = received
}

pub fn informational_final_status_is_internal_error_test() {
  ready()
  |> client.get(1, "/informational")
  |> expect_reset(1, frame.InternalError)
}

pub fn streamed_out_of_range_status_is_internal_error_test() {
  ready()
  |> client.get(1, "/streamed-out-of-range")
  |> expect_reset(1, frame.InternalError)
}

fn serve_file() -> Int {
  client.serve_with(app, ewe.Http2Options(..options(), file_read_threshold: 0))
}

fn write_served_file() -> BitArray {
  let data = counting(100_000, <<>>)
  write_file(served_file, data)
  data
}

fn counting(size: Int, acc: BitArray) -> BitArray {
  case size {
    0 -> acc
    _size -> counting(size - 1, <<acc:bits, { size % 251 }>>)
  }
}

pub fn file_is_sent_from_memory_with_small_frames_test() {
  let data = write_served_file()

  let #(received, _client) =
    serve_file()
    |> client.handshake([])
    |> client.get(1, "/file")
    |> client.response(1)

  let assert Response(status: 200, body:, ..) = received
  assert body == data
}

pub fn file_is_sent_with_sendfile_with_large_frames_test() {
  let data = write_served_file()

  let client =
    serve_file()
    |> client.handshake([
      frame.MaxFrameSize(1_048_576),
      frame.InitialWindowSize(1_048_576),
    ])
    |> client.send(frame.WindowUpdate(0, 1_048_576))
    |> client.get(1, "/file")
  let #(_headers, client) = client.receive(client)
  let #(received, _client) = client.receive(client)

  assert received == frame.Data(1, True, data, 100_000)
}

pub fn streamed_response_test() {
  let #(received, _client) =
    ready()
    |> client.get(1, "/stream")
    |> client.response(1)

  let assert Response(status: 200, headers:, body: <<"abc":utf8>>) = received
  assert list.key_find(headers, "content-length") == Error(Nil)
}

pub fn unsafe_response_header_is_answered_with_500_test() {
  let #(received, _client) =
    ready()
    |> client.get(1, "/unsafe")
    |> client.response(1)

  let assert Response(status: 500, headers:, ..) = received
  assert list.key_find(headers, "x-a") == Error(Nil)
}

pub fn unsafe_streamed_response_header_resets_the_stream_test() {
  ready()
  |> client.get(1, "/unsafe-stream")
  |> expect_reset(1, frame.InternalError)
}

pub fn handler_crash_is_answered_with_on_crash_test() {
  let #(received, _client) =
    ready()
    |> client.get(1, "/crash")
    |> client.response(1)

  let assert Response(status: 500, ..) = received
}

pub fn head_response_has_length_but_no_body_test() {
  let #(received, client) =
    ready()
    |> client.headers(1, client.request_fields("HEAD", "/big/1234"), True)
    |> client.response(1)

  let assert Response(status: 200, headers:, body: <<>>) = received
  assert list.key_find(headers, "content-length") == Ok("1234")
  assert client.is_quiet(client)
}

pub fn no_content_response_drops_body_and_length_test() {
  let #(received, _client) =
    ready()
    |> client.get(1, "/no-content")
    |> client.response(1)

  let assert Response(status: 204, headers:, body: <<>>) = received
  assert list.key_find(headers, "content-length") == Error(Nil)
}

pub fn streamed_no_content_response_sends_no_body_test() {
  let #(received, _client) =
    ready()
    |> client.get(1, "/streamed-no-content")
    |> client.response(1)

  let assert Response(status: 204, body: <<>>, ..) = received
}

pub fn connect_reaches_the_handler_test() {
  let #(received, _client) =
    ready()
    |> client.headers(
      1,
      [#(":method", "CONNECT"), #(":authority", "example.com:443")],
      True,
    )
    |> client.response(1)

  let assert Response(
    status: 200,
    headers:,
    body: <<"tunnel to example.com":utf8>>,
  ) = received
  assert list.key_find(headers, "content-length") == Error(Nil)
}

pub fn protocol_is_refused_when_not_advertised_test() {
  let _client =
    ready_with(ewe.Http2Options(..options(), websocket: False))
    |> client.headers(
      1,
      [#(":protocol", "websocket"), ..client.request_fields("CONNECT", "/")],
      True,
    )
    |> expect_reset(1, frame.ProtocolError)
  Nil
}

pub fn oversized_header_list_is_answered_with_431_test() {
  let #(received, _client) =
    ready_with(ewe.Http2Options(..options(), max_header_list_size: Some(200)))
    |> client.headers(
      1,
      [#("x-big", string.repeat("a", 300)), ..client.request_fields("GET", "/")],
      True,
    )
    |> client.response(1)

  let assert Response(status: 431, ..) = received
}

pub fn oversized_request_beyond_the_stream_limit_is_refused_test() {
  ready_with(
    ewe.Http2Options(
      ..options(),
      max_concurrent_streams: Some(1),
      max_header_list_size: Some(200),
    ),
  )
  |> client.get(1, "/hang")
  |> client.headers(
    3,
    [#("x-big", string.repeat("a", 300)), ..client.request_fields("GET", "/")],
    True,
  )
  |> expect_reset(3, frame.RefusedStream)
}

pub fn response_to_a_closed_connection_does_not_leak_test() {
  let parent = process.new_subject()
  let handler = fn(req: request.Request(ewe.Connection)) {
    process.send(parent, process.self())
    app(req)
  }

  let client =
    client.serve(handler)
    |> client.handshake([])
    |> client.get(1, "/hang")
  let assert Ok(pid) = process.receive(parent, 1000)
  client.close(client)

  assert client.wait_until(fn() { !process.is_alive(pid) }, 50)
}

pub fn goaway_error_from_client_closes_at_once_test() {
  let client =
    ready()
    |> client.get(1, "/hang")
    |> client.send(frame.Goaway(0, frame.InternalError, <<>>))

  assert client.is_closed(client)
}

pub fn handler_reads_the_request_after_responding_test() {
  let parent = process.new_subject()
  let handler = fn(req: request.Request(ewe.Connection)) {
    use writer <- ewe.stream_response(response.new(200))
    let assert Ok(Nil) = ewe.finish_response(writer)
    process.send(
      parent,
      ewe.read_body(req, 100) |> result.map(fn(req) { req.body }),
    )
    Ok(Nil)
  }

  let client =
    client.serve(handler)
    |> client.handshake([])
    |> client.headers(1, client.request_fields("POST", "/"), False)
  let #(received, client) = client.response(client, 1)
  let assert Response(status: 200, ..) = received

  let _client = client.data(client, 1, <<"late body":utf8>>, True)
  assert process.receive(parent, 1000) == Ok(Ok(<<"late body":utf8>>))
}

fn websocket_request() -> List(#(String, String)) {
  [
    #(":method", "CONNECT"),
    #(":protocol", "websocket"),
    #(":scheme", "http"),
    #(":authority", "localhost"),
    #(":path", "/"),
    #("sec-websocket-version", "13"),
  ]
}

pub fn websocket_over_extended_connect_test() {
  let handler = fn(req: request.Request(ewe.Connection)) {
    ewe.websocket(
      request: req,
      on_init: fn(_conn, selector) { #(Nil, selector) },
      handler: fn(conn, state, message) {
        case message {
          ewe.TextFrame(text) -> {
            let assert Ok(Nil) = ewe.send_text_frame(conn, text)
            ewe.continue(state)
          }
          ewe.BinaryFrame(_data) | ewe.UserMessage(_message) ->
            ewe.continue(state)
        }
      },
      on_close: fn(_conn, _state) { Nil },
    )
  }

  let client =
    client.serve(handler)
    |> client.handshake([])
    |> client.headers(1, websocket_request(), False)
  let #(headers, client) = client.receive(client)
  let assert frame.Headers(stream_id: 1, end_stream: False, ..) = headers

  let #(echoed, client) =
    client
    |> client.data(1, <<0x81, 0x82, 0:32, "hi":utf8>>, False)
    |> client.receive
  assert echoed == frame.Data(1, False, <<0x81, 0x02, "hi":utf8>>, 4)

  let #(closed, _client) =
    client
    |> client.data(1, <<0x88, 0x82, 0:32, 1000:16>>, False)
    |> client.receive
  let assert frame.Data(
    stream_id: 1,
    end_stream: True,
    data: <<0x88, _rest:bits>>,
    ..,
  ) = closed
}

pub fn write_after_the_response_ended_fails_at_once_test() {
  let parent = process.new_subject()
  let handler = fn(_req: request.Request(ewe.Connection)) {
    use writer <- ewe.stream_response(response.new(200))
    let assert Ok(Nil) = ewe.finish_response(writer)
    process.send(parent, ewe.send_chunk(writer, <<"late":utf8>>))
    Ok(Nil)
  }

  let #(received, _client) =
    client.serve(handler)
    |> client.handshake([])
    |> client.get(1, "/")
    |> client.response(1)
  let assert Response(status: 200, body: <<>>, ..) = received

  let assert Ok(Error(ewe.ConnectionClosed)) = process.receive(parent, 1000)
}

pub fn reading_the_body_again_after_the_stream_ended_returns_at_once_test() {
  let parent = process.new_subject()
  let handler = fn(req: request.Request(ewe.Connection)) {
    let assert Ok(_read) = ewe.read_body(req, 100)
    use writer <- ewe.stream_response(response.new(200))
    let assert Ok(Nil) = ewe.finish_response(writer)
    process.send(
      parent,
      ewe.read_body(req, 100) |> result.map(fn(req) { req.body }),
    )
    Ok(Nil)
  }

  let _client =
    client.serve(handler)
    |> client.handshake([])
    |> client.headers(1, client.request_fields("POST", "/"), False)
    |> client.data(1, <<"body":utf8>>, True)
  assert process.receive(parent, 1000) == Ok(Ok(<<>>))
}

pub fn websocket_on_close_can_still_send_test() {
  let handler = fn(req: request.Request(ewe.Connection)) {
    ewe.websocket(
      request: req,
      on_init: fn(_conn, selector) { #(Nil, selector) },
      handler: fn(_conn, _state, _message) { ewe.stop() },
      on_close: fn(conn, _state) {
        let assert Ok(Nil) = ewe.send_text_frame(conn, "bye")
        Nil
      },
    )
  }

  let client =
    client.serve(handler)
    |> client.handshake([])
    |> client.headers(1, websocket_request(), False)
  let #(_headers, client) = client.receive(client)

  let #(goodbye, client) =
    client
    |> client.data(1, <<0x81, 0x82, 0:32, "hi":utf8>>, False)
    |> client.receive
  assert goodbye == frame.Data(1, False, <<0x81, 0x03, "bye":utf8>>, 5)

  let #(ended, _client) = client.receive(client)
  assert ended == frame.Data(1, True, <<>>, 0)
}
