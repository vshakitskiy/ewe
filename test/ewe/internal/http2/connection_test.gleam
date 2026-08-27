import alpacki
import ewe/internal/http2 as connection
import ewe/internal/http2/connection as http2
import ewe/internal/http2/frame
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/list
import gleam/option.{None, Some}

fn pending_stream(send_window: Int, pending: BitArray) -> connection.Stream {
  connection.Stream(
    status: connection.Flushing,
    send_window:,
    pending: connection.closed_chunks(pending),
    writer: None,
    recv_window: 65_535,
    recv_buffer: bytes_tree.new(),
    request_half_closed: False,
    parked_reader: None,
    content_length: None,
    body_bytes_received: 0,
    trailers: [],
    method: http.Get,
  )
}

fn inbound_stream(
  recv_window: Int,
  parked_reader: option.Option(process.Subject(http2.BodyEvent)),
) -> connection.Stream {
  connection.Stream(
    status: connection.Flushing,
    send_window: 65_535,
    pending: connection.no_chunks(),
    writer: None,
    recv_window:,
    recv_buffer: bytes_tree.new(),
    request_half_closed: False,
    parked_reader:,
    content_length: None,
    body_bytes_received: 0,
    trailers: [],
    method: http.Get,
  )
}

fn encode(fields: List(alpacki.HeaderField)) -> BitArray {
  let #(payload, _) =
    alpacki.encode_header_block(fields, alpacki.new_dynamic(4096), False)
  payload
}

fn method_get() -> alpacki.HeaderField {
  alpacki.HeaderField(
    <<":method":utf8>>,
    <<"GET":utf8>>,
    alpacki.WithoutIndexing,
  )
}

fn minimal_headers() -> List(alpacki.HeaderField) {
  [
    method_get(),
    alpacki.HeaderField(
      <<":scheme":utf8>>,
      <<"https":utf8>>,
      alpacki.WithoutIndexing,
    ),
    alpacki.HeaderField(
      <<":authority":utf8>>,
      <<"example.com":utf8>>,
      alpacki.WithoutIndexing,
    ),
    alpacki.HeaderField(<<":path":utf8>>, <<"/":utf8>>, alpacki.WithoutIndexing),
  ]
}

fn custom_field() -> alpacki.HeaderField {
  alpacki.HeaderField(
    <<"x-custom":utf8>>,
    <<"some-longer-header-value-here":utf8>>,
    alpacki.WithoutIndexing,
  )
}

fn headers_with_content_length(length: String) -> List(alpacki.HeaderField) {
  list.append(minimal_headers(), [
    alpacki.HeaderField(
      <<"content-length":utf8>>,
      <<length:utf8>>,
      alpacki.WithoutIndexing,
    ),
  ])
}

pub fn headers_single_frame_completes_test() {
  let payload = encode(minimal_headers())
  let result =
    connection.handle_headers(connection.test_state(), 1, True, True, payload)
  let assert connection.Proceed(state) = result
  assert state.header_assembly == None
  assert state.highest_client_stream_id_seen == 1
}

pub fn headers_end_stream_marks_new_stream_half_closed_test() {
  let payload = encode(minimal_headers())
  let result =
    connection.handle_headers(connection.test_state(), 1, True, True, payload)
  let assert connection.Proceed(state) = result
  let assert Ok(entry) = dict.get(state.streams, 1)
  assert entry.request_half_closed == True
}

pub fn headers_without_end_stream_leaves_stream_open_test() {
  let payload = encode(minimal_headers())
  let result =
    connection.handle_headers(connection.test_state(), 1, False, True, payload)
  let assert connection.Proceed(state) = result
  let assert Ok(entry) = dict.get(state.streams, 1)
  assert entry.request_half_closed == False
}

pub fn headers_even_stream_id_is_protocol_error_test() {
  let payload = encode(minimal_headers())
  let result =
    connection.handle_headers(connection.test_state(), 2, True, True, payload)
  assert result == connection.Terminate(Some(frame.ProtocolError))
}

pub fn headers_reused_stream_id_on_half_closed_remote_is_stream_error_test() {
  let payload = encode(minimal_headers())
  let assert connection.Proceed(state) =
    connection.handle_headers(connection.test_state(), 3, True, True, payload)

  let result = connection.handle_headers(state, 3, True, True, payload)
  let assert connection.RejectStream(_, 3, frame.StreamClosed) = result
}

pub fn headers_decreasing_stream_id_is_protocol_error_test() {
  let payload = encode(minimal_headers())
  let assert connection.Proceed(state) =
    connection.handle_headers(connection.test_state(), 5, True, True, payload)

  let result = connection.handle_headers(state, 3, True, True, payload)
  assert result == connection.Terminate(Some(frame.ProtocolError))
}

pub fn headers_increasing_stream_id_after_reject_still_advances_test() {
  let malformed = encode([method_get()])
  let assert connection.RejectStream(state, 1, _) =
    connection.handle_headers(connection.test_state(), 1, True, True, malformed)

  let payload = encode(minimal_headers())
  let result = connection.handle_headers(state, 1, True, True, payload)
  assert result == connection.Terminate(Some(frame.ProtocolError))
}

pub fn headers_while_draining_refuses_new_stream_test() {
  let state = connection.State(..connection.test_state(), draining: True)
  let payload = encode(minimal_headers())

  let result = connection.handle_headers(state, 1, True, True, payload)

  let assert connection.RejectStream(state, 1, frame.RefusedStream) = result
  assert dict.get(state.streams, 1) == Error(Nil)
}

pub fn headers_without_end_headers_starts_assembly_test() {
  let payload = encode([method_get()])
  let result =
    connection.handle_headers(connection.test_state(), 1, True, False, payload)
  let assert connection.Proceed(state) = result
  assert state.header_assembly
    == Some(connection.HeaderAssembly(1, True, 1, payload, False))
}

pub fn oversized_headers_frame_is_enhance_your_calm_test() {
  let huge = <<0:size({ 65_537 * 8 })>>
  let result =
    connection.handle_headers(connection.test_state(), 1, True, True, huge)
  assert result == connection.Terminate(Some(frame.EnhanceYourCalm))
}

pub fn continuation_completes_split_block_test() {
  let payload = encode(list.append(minimal_headers(), [custom_field()]))
  let assert <<first:bytes-size(5), second:bits>> = payload

  let assert connection.Proceed(state) =
    connection.handle_headers(connection.test_state(), 1, True, False, first)
  let assert Some(assembly) = state.header_assembly

  let result =
    connection.handle_continuation(
      state,
      assembly,
      frame.Continuation(1, True, second),
    )
  let assert connection.Proceed(final_state) = result
  assert final_state.header_assembly == None
}

pub fn continuation_wrong_stream_is_protocol_error_test() {
  let assembly = connection.HeaderAssembly(1, True, 1, <<>>, False)
  let result =
    connection.handle_continuation(
      connection.test_state(),
      assembly,
      frame.Continuation(2, True, <<>>),
    )
  assert result == connection.Terminate(Some(frame.ProtocolError))
}

pub fn non_continuation_mid_assembly_is_protocol_error_test() {
  let assembly = connection.HeaderAssembly(1, True, 1, <<>>, False)
  let result =
    connection.handle_continuation(
      connection.test_state(),
      assembly,
      frame.Ping(0, False, <<0, 0, 0, 0, 0, 0, 0, 0>>),
    )
  assert result == connection.Terminate(Some(frame.ProtocolError))
}

pub fn add_fragment_within_limits_test() {
  let assembly = connection.HeaderAssembly(1, True, 1, <<"a":utf8>>, False)
  let assert Ok(updated) =
    connection.add_fragment(assembly, <<"b":utf8>>, http2.default_options())
  assert updated == connection.HeaderAssembly(1, True, 2, <<"ab":utf8>>, False)
}

pub fn add_fragment_over_count_cap_is_enhance_your_calm_test() {
  let assembly = connection.HeaderAssembly(1, True, 100, <<>>, False)
  let result = connection.add_fragment(assembly, <<>>, http2.default_options())
  assert result == Error(frame.EnhanceYourCalm)
}

pub fn add_fragment_over_byte_cap_is_enhance_your_calm_test() {
  let assembly =
    connection.HeaderAssembly(1, True, 1, <<0:size({ 65_536 * 8 })>>, False)
  let result =
    connection.add_fragment(assembly, <<"x":utf8>>, http2.default_options())
  assert result == Error(frame.EnhanceYourCalm)
}

pub fn complete_header_block_invalid_hpack_is_compression_error_test() {
  let assembly = connection.HeaderAssembly(1, True, 1, <<0xff, 0xff>>, False)
  let result =
    connection.complete_header_block(connection.test_state(), assembly)
  assert result == connection.Terminate(Some(frame.CompressionError))
}

pub fn complete_header_block_oversized_list_is_enhance_your_calm_test() {
  let big_value = <<0:size({ 20_000 * 8 })>>
  let field =
    alpacki.HeaderField(<<"x":utf8>>, big_value, alpacki.WithoutIndexing)
  let assembly = connection.HeaderAssembly(1, True, 1, encode([field]), False)
  let options =
    http2.Options(..http2.default_options(), max_header_list_size: Some(16_384))
  let state = connection.State(..connection.test_state(), options:)
  let result = connection.complete_header_block(state, assembly)
  assert result == connection.Terminate(Some(frame.EnhanceYourCalm))
}

pub fn complete_header_block_oversized_list_unlimited_by_default_test() {
  let big_value = <<0:size({ 20_000 * 8 })>>
  let field =
    alpacki.HeaderField(<<"x":utf8>>, big_value, alpacki.WithoutIndexing)
  let assembly = connection.HeaderAssembly(1, True, 1, encode([field]), False)
  let result =
    connection.complete_header_block(connection.test_state(), assembly)
  assert result != connection.Terminate(Some(frame.EnhanceYourCalm))
}

pub fn build_request_minimal_valid_test() {
  let headers = [
    #(<<":method":utf8>>, <<"GET":utf8>>),
    #(<<":scheme":utf8>>, <<"https":utf8>>),
    #(<<":authority":utf8>>, <<"example.com":utf8>>),
    #(<<":path":utf8>>, <<"/":utf8>>),
  ]
  let assert Ok(connection.DecodedRequest(
    request:,
    content_length: None,
    protocol: None,
  )) = connection.build_request(headers, Nil, connection.header_patterns())
  assert request.method == http.Get
  assert request.scheme == http.Https
  assert request.host == "example.com"
  assert request.port == None
  assert request.path == "/"
  assert request.query == None
  assert request.headers == []
}

pub fn build_request_with_query_and_port_test() {
  let headers = [
    #(<<":method":utf8>>, <<"POST":utf8>>),
    #(<<":scheme":utf8>>, <<"http":utf8>>),
    #(<<":authority":utf8>>, <<"example.com:8080":utf8>>),
    #(<<":path":utf8>>, <<"/search?q=1":utf8>>),
    #(<<"x-custom":utf8>>, <<"value":utf8>>),
  ]
  let assert Ok(connection.DecodedRequest(
    request:,
    content_length: None,
    protocol: None,
  )) = connection.build_request(headers, Nil, connection.header_patterns())
  assert request.method == http.Post
  assert request.host == "example.com"
  assert request.port == Some(8080)
  assert request.path == "/search"
  assert request.query == Some("q=1")
  assert request.headers == [#("x-custom", "value")]
}

pub fn build_request_missing_pseudo_header_test() {
  let headers = [#(<<":method":utf8>>, <<"GET":utf8>>)]
  assert connection.build_request(headers, Nil, connection.header_patterns())
    == Error(connection.MissingPseudoHeader)
}

pub fn build_request_duplicate_pseudo_header_test() {
  let headers = [
    #(<<":method":utf8>>, <<"GET":utf8>>),
    #(<<":method":utf8>>, <<"POST":utf8>>),
    #(<<":scheme":utf8>>, <<"https":utf8>>),
    #(<<":authority":utf8>>, <<"example.com":utf8>>),
    #(<<":path":utf8>>, <<"/":utf8>>),
  ]
  assert connection.build_request(headers, Nil, connection.header_patterns())
    == Error(connection.DuplicatePseudoHeader)
}

pub fn build_request_pseudo_after_regular_test() {
  let headers = [
    #(<<":method":utf8>>, <<"GET":utf8>>),
    #(<<"x-custom":utf8>>, <<"value":utf8>>),
    #(<<":scheme":utf8>>, <<"https":utf8>>),
    #(<<":authority":utf8>>, <<"example.com":utf8>>),
    #(<<":path":utf8>>, <<"/":utf8>>),
  ]
  assert connection.build_request(headers, Nil, connection.header_patterns())
    == Error(connection.PseudoHeaderAfterRegular)
}

pub fn build_request_unknown_pseudo_header_test() {
  let headers = [
    #(<<":bogus":utf8>>, <<"x":utf8>>),
    #(<<":method":utf8>>, <<"GET":utf8>>),
    #(<<":scheme":utf8>>, <<"https":utf8>>),
    #(<<":authority":utf8>>, <<"example.com":utf8>>),
    #(<<":path":utf8>>, <<"/":utf8>>),
  ]
  assert connection.build_request(headers, Nil, connection.header_patterns())
    == Error(connection.UnknownPseudoHeader)
}

pub fn build_request_invalid_scheme_test() {
  let headers = [
    #(<<":method":utf8>>, <<"GET":utf8>>),
    #(<<":scheme":utf8>>, <<"ftp":utf8>>),
    #(<<":authority":utf8>>, <<"example.com":utf8>>),
    #(<<":path":utf8>>, <<"/":utf8>>),
  ]
  assert connection.build_request(headers, Nil, connection.header_patterns())
    == Error(connection.InvalidScheme)
}

pub fn build_request_invalid_authority_port_test() {
  let headers = [
    #(<<":method":utf8>>, <<"GET":utf8>>),
    #(<<":scheme":utf8>>, <<"https":utf8>>),
    #(<<":authority":utf8>>, <<"example.com:abc":utf8>>),
    #(<<":path":utf8>>, <<"/":utf8>>),
  ]
  assert connection.build_request(headers, Nil, connection.header_patterns())
    == Error(connection.InvalidAuthority)
}

pub fn build_request_empty_path_test() {
  let headers = [
    #(<<":method":utf8>>, <<"GET":utf8>>),
    #(<<":scheme":utf8>>, <<"https":utf8>>),
    #(<<":authority":utf8>>, <<"example.com":utf8>>),
    #(<<":path":utf8>>, <<"":utf8>>),
  ]
  assert connection.build_request(headers, Nil, connection.header_patterns())
    == Error(connection.InvalidPath)
}

pub fn build_request_empty_header_name_test() {
  let headers = [
    #(<<":method":utf8>>, <<"GET":utf8>>),
    #(<<":scheme":utf8>>, <<"https":utf8>>),
    #(<<":authority":utf8>>, <<"example.com":utf8>>),
    #(<<":path":utf8>>, <<"/":utf8>>),
    #(<<>>, <<"value":utf8>>),
  ]
  assert connection.build_request(headers, Nil, connection.header_patterns())
    == Error(connection.EmptyHeaderName)
}

pub fn build_request_uppercase_header_name_test() {
  let headers = [
    #(<<":method":utf8>>, <<"GET":utf8>>),
    #(<<":scheme":utf8>>, <<"https":utf8>>),
    #(<<":authority":utf8>>, <<"example.com":utf8>>),
    #(<<":path":utf8>>, <<"/":utf8>>),
    #(<<"X-Custom":utf8>>, <<"value":utf8>>),
  ]
  assert connection.build_request(headers, Nil, connection.header_patterns())
    == Error(connection.UppercaseHeaderName)
}

pub fn build_request_connection_specific_header_test() {
  let headers = [
    #(<<":method":utf8>>, <<"GET":utf8>>),
    #(<<":scheme":utf8>>, <<"https":utf8>>),
    #(<<":authority":utf8>>, <<"example.com":utf8>>),
    #(<<":path":utf8>>, <<"/":utf8>>),
    #(<<"connection":utf8>>, <<"keep-alive":utf8>>),
  ]
  assert connection.build_request(headers, Nil, connection.header_patterns())
    == Error(connection.ConnectionSpecificHeader)
}

pub fn build_request_te_trailers_allowed_test() {
  let headers = [
    #(<<":method":utf8>>, <<"GET":utf8>>),
    #(<<":scheme":utf8>>, <<"https":utf8>>),
    #(<<":authority":utf8>>, <<"example.com":utf8>>),
    #(<<":path":utf8>>, <<"/":utf8>>),
    #(<<"te":utf8>>, <<"trailers":utf8>>),
  ]
  let assert Ok(connection.DecodedRequest(
    request:,
    content_length: None,
    protocol: None,
  )) = connection.build_request(headers, Nil, connection.header_patterns())
  assert request.headers == [#("te", "trailers")]
}

pub fn build_request_te_non_trailers_rejected_test() {
  let headers = [
    #(<<":method":utf8>>, <<"GET":utf8>>),
    #(<<":scheme":utf8>>, <<"https":utf8>>),
    #(<<":authority":utf8>>, <<"example.com":utf8>>),
    #(<<":path":utf8>>, <<"/":utf8>>),
    #(<<"te":utf8>>, <<"gzip":utf8>>),
  ]
  assert connection.build_request(headers, Nil, connection.header_patterns())
    == Error(connection.ConnectionSpecificHeader)
}

pub fn build_request_invalid_utf8_header_value_test() {
  let headers = [
    #(<<":method":utf8>>, <<"GET":utf8>>),
    #(<<":scheme":utf8>>, <<"https":utf8>>),
    #(<<":authority":utf8>>, <<"example.com":utf8>>),
    #(<<":path":utf8>>, <<"/":utf8>>),
    #(<<"x-custom":utf8>>, <<0xff, 0xfe>>),
  ]
  assert connection.build_request(headers, Nil, connection.header_patterns())
    == Error(connection.InvalidUtf8)
}

pub fn build_request_invalid_method_test() {
  let headers = [
    #(<<":method":utf8>>, <<"bad method":utf8>>),
    #(<<":scheme":utf8>>, <<"https":utf8>>),
    #(<<":authority":utf8>>, <<"example.com":utf8>>),
    #(<<":path":utf8>>, <<"/":utf8>>),
  ]
  assert connection.build_request(headers, Nil, connection.header_patterns())
    == Error(connection.InvalidMethod)
}

pub fn complete_header_block_updates_dynamic_table_test() {
  let field =
    alpacki.HeaderField(
      <<"x-custom":utf8>>,
      <<"value":utf8>>,
      alpacki.WithIndexing,
    )
  let payload = encode(list.append(minimal_headers(), [field]))
  let assembly = connection.HeaderAssembly(1, True, 1, payload, False)
  let result =
    connection.complete_header_block(connection.test_state(), assembly)
  let assert connection.Proceed(state) = result
  assert alpacki.dynamic_length(state.hpack_decoder) == 1
}

pub fn complete_header_block_invalid_request_rejects_stream_test() {
  let assembly =
    connection.HeaderAssembly(1, True, 1, encode([method_get()]), False)
  let result =
    connection.complete_header_block(connection.test_state(), assembly)
  let assert connection.RejectStream(_, stream_id, code) = result
  assert stream_id == 1
  assert code == frame.ProtocolError
}

pub fn client_reset_under_threshold_continues_test() {
  let state =
    connection.State(
      ..connection.test_state(),
      highest_client_stream_id_seen: 1,
    )
  let result = connection.handle_client_reset(state, 1)
  let assert connection.Proceed(_) = result
}

pub fn client_reset_on_idle_stream_is_protocol_error_test() {
  let result = connection.handle_client_reset(connection.test_state(), 1)
  assert result == connection.Terminate(Some(frame.ProtocolError))
}

pub fn rapid_reset_trips_enhance_your_calm_test() {
  let state =
    int.range(
      from: 1,
      to: 101,
      with: connection.test_state(),
      run: fn(state, stream_id) {
        let state =
          connection.State(..state, highest_client_stream_id_seen: stream_id)
        let assert connection.Proceed(state) =
          connection.handle_client_reset(state, stream_id)
        state
      },
    )

  let result = connection.handle_client_reset(state, 101)
  let assert connection.Terminate(Some(frame.EnhanceYourCalm)) = result
}

pub fn append_header_frames_splits_into_continuation_test() {
  let block = <<0:size(120)>>
  let out =
    connection.append_header_frames(bytes_tree.new(), 1, True, block, 10)
    |> bytes_tree.to_bit_array

  let assert Ok(#(frame.Headers(1, True, False, first_chunk), rest)) =
    frame.decode(out, 16_384)
  let assert Ok(#(frame.Continuation(1, True, second_chunk), rest)) =
    frame.decode(rest, 16_384)

  assert bit_array.byte_size(first_chunk) == 10
  assert bit_array.byte_size(second_chunk) == 5
  assert rest == <<>>
}

pub fn flush_stream_full_drain_test() {
  let state = connection.test_state()
  let entry = pending_stream(100, <<"hello":utf8>>)

  let assert connection.FlushAccumulated(state, out, wrote) =
    connection.do_flush_stream(state, 1, entry, bytes_tree.new(), False)

  assert wrote == True
  let assert Ok(#(frame.Data(1, True, <<"hello":utf8>>, 5), rest)) =
    frame.decode(bytes_tree.to_bit_array(out), 16_384)
  assert rest == <<>>
  assert dict.get(state.streams, 1) == Error(Nil)
  assert state.conn_send_window == 65_535 - 5
}

pub fn flush_stream_partial_drain_blocks_on_stream_window_test() {
  let state = connection.test_state()
  let entry = pending_stream(3, <<"hello":utf8>>)

  let assert connection.FlushAccumulated(state, out, wrote) =
    connection.do_flush_stream(state, 1, entry, bytes_tree.new(), False)

  assert wrote == True
  let assert Ok(#(frame.Data(1, False, <<"hel":utf8>>, 3), rest)) =
    frame.decode(bytes_tree.to_bit_array(out), 16_384)
  assert rest == <<>>
  let assert Ok(remaining) = dict.get(state.streams, 1)
  assert remaining.status == connection.Flushing
  assert remaining.send_window == 0
  assert remaining.pending == connection.closed_chunks(<<"lo":utf8>>)
  assert state.conn_send_window == 65_535 - 3
}

pub fn flush_stream_zero_window_defers_everything_test() {
  let state = connection.State(..connection.test_state(), conn_send_window: 0)
  let entry = pending_stream(100, <<"hello":utf8>>)

  let assert connection.FlushAccumulated(state, out, wrote) =
    connection.do_flush_stream(state, 1, entry, bytes_tree.new(), False)

  assert wrote == False
  assert out == bytes_tree.new()
  let assert Ok(unchanged) = dict.get(state.streams, 1)
  assert unchanged == entry
}

pub fn flush_stream_sends_multiple_frames_in_one_call_when_window_allows_test() {
  let state = connection.test_state()
  let body = <<0:size({ 40_000 * 8 })>>
  let entry = pending_stream(100_000, body)

  let assert connection.FlushAccumulated(state, out, wrote) =
    connection.do_flush_stream(state, 1, entry, bytes_tree.new(), False)

  assert wrote == True
  let bytes = bytes_tree.to_bit_array(out)

  let assert Ok(#(frame.Data(1, False, chunk_1, _), rest)) =
    frame.decode(bytes, 16_384)
  assert bit_array.byte_size(chunk_1) == 16_384

  let assert Ok(#(frame.Data(1, False, chunk_2, _), rest)) =
    frame.decode(rest, 16_384)
  assert bit_array.byte_size(chunk_2) == 16_384

  let assert Ok(#(frame.Data(1, True, chunk_3, _), rest)) =
    frame.decode(rest, 16_384)
  assert bit_array.byte_size(chunk_3) == 40_000 - 16_384 - 16_384

  assert rest == <<>>
  assert dict.get(state.streams, 1) == Error(Nil)
  assert state.conn_send_window == 65_535 - 40_000
}

pub fn adjust_stream_windows_applies_delta_to_all_streams_test() {
  let entry_a = pending_stream(100, <<"a":utf8>>)
  let entry_b = pending_stream(200, <<"b":utf8>>)
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry_a), #(3, entry_b)]),
    )

  let state = connection.adjust_stream_windows(state, -50)

  let assert Ok(a) = dict.get(state.streams, 1)
  let assert Ok(b) = dict.get(state.streams, 3)
  assert a.send_window == 50
  assert b.send_window == 150
}

pub fn client_reset_on_flushing_stream_removes_it_test() {
  let entry = pending_stream(10, <<"tail":utf8>>)
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry)]),
    )

  let result = connection.handle_client_reset(state, 1)
  let assert connection.Proceed(state) = result
  assert dict.get(state.streams, 1) == Error(Nil)
}

pub fn client_reset_on_computing_stream_keeps_stream_pids_test() {
  let pid = process.spawn_unlinked(fn() { process.sleep_forever() })
  let entry =
    connection.Stream(
      ..pending_stream(65_535, <<>>),
      status: connection.Computing(pid),
    )
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry)]),
      stream_pids: dict.from_list([#(pid, 1)]),
      highest_client_stream_id_seen: 1,
    )

  let result = connection.handle_client_reset(state, 1)
  let assert connection.Proceed(state) = result

  assert dict.get(state.streams, 1) == Error(Nil)
  assert dict.get(state.stream_pids, pid) == Ok(1)
}

pub fn handle_data_accumulates_into_buffer_test() {
  let entry = inbound_stream(65_535, None)
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry)]),
      highest_client_stream_id_seen: 1,
      conn_recv_window: 2_097_152,
    )

  let assert connection.Proceed(state) =
    connection.handle_data(state, 1, False, <<"abc":utf8>>, 3)

  let assert Ok(updated) = dict.get(state.streams, 1)
  assert bytes_tree.to_bit_array(updated.recv_buffer) == <<"abc":utf8>>
  assert updated.recv_window == 65_535 - 3
  assert updated.request_half_closed == False
  assert state.conn_recv_window == 2_097_152 - 3
}

pub fn handle_data_padded_frame_counts_full_wire_size_test() {
  let entry = inbound_stream(65_535, None)
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry)]),
      highest_client_stream_id_seen: 1,
      conn_recv_window: 2_097_152,
    )

  let assert connection.Proceed(state) =
    connection.handle_data(state, 1, False, <<"abc":utf8>>, 10)

  let assert Ok(updated) = dict.get(state.streams, 1)
  assert bytes_tree.to_bit_array(updated.recv_buffer) == <<"abc":utf8>>
  assert updated.recv_window == 65_535 - 10
  assert state.conn_recv_window == 2_097_152 - 10
}

pub fn handle_data_end_stream_sets_half_closed_test() {
  let entry = inbound_stream(65_535, None)
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry)]),
      highest_client_stream_id_seen: 1,
      conn_recv_window: 2_097_152,
    )

  let assert connection.Proceed(state) =
    connection.handle_data(state, 1, True, <<>>, 0)

  let assert Ok(updated) = dict.get(state.streams, 1)
  assert updated.request_half_closed == True
}

pub fn handle_data_delivers_directly_to_parked_reader_test() {
  let reply_to = process.new_subject()
  let entry = inbound_stream(2_097_152, Some(reply_to))
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry)]),
      highest_client_stream_id_seen: 1,
      conn_recv_window: 2_097_152,
    )

  let assert connection.Proceed(state) =
    connection.handle_data(state, 1, False, <<"hi":utf8>>, 2)

  let assert Ok(http2.ChunkEvent(<<"hi":utf8>>)) =
    process.receive(reply_to, 100)
  let assert Ok(updated) = dict.get(state.streams, 1)
  assert updated.parked_reader == None
  assert bytes_tree.to_bit_array(updated.recv_buffer) == <<>>
}

pub fn handle_data_delivered_to_parked_reader_grants_credit_test() {
  let reply_to = process.new_subject()
  let entry = inbound_stream(100_000, Some(reply_to))
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry)]),
      highest_client_stream_id_seen: 1,
    )
  let chunk = <<0:size({ 40_000 * 8 })>>

  let result = connection.handle_data(state, 1, False, chunk, 40_000)

  let assert connection.ProceedWithOutbound(state, out) = result
  let assert Ok(http2.ChunkEvent(delivered)) = process.receive(reply_to, 100)
  assert delivered == chunk

  let bytes = bytes_tree.to_bit_array(out)
  let assert Ok(#(frame.WindowUpdate(1, 2_037_152), rest)) =
    frame.decode(bytes, 16_384)
  let assert Ok(#(frame.WindowUpdate(0, 2_071_617), rest)) =
    frame.decode(rest, 16_384)
  assert rest == <<>>

  let assert Ok(updated) = dict.get(state.streams, 1)
  assert updated.recv_window == 2_097_152
}

pub fn handle_data_delivers_last_chunk_to_parked_reader_test() {
  let reply_to = process.new_subject()
  let entry = inbound_stream(2_097_152, Some(reply_to))
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry)]),
      highest_client_stream_id_seen: 1,
      conn_recv_window: 2_097_152,
    )

  let assert connection.Proceed(_state) =
    connection.handle_data(state, 1, True, <<"hi":utf8>>, 2)

  let assert Ok(http2.LastChunkEvent(<<"hi":utf8>>, [])) =
    process.receive(reply_to, 100)
}

pub fn handle_data_sends_done_to_parked_reader_on_empty_end_stream_test() {
  let reply_to = process.new_subject()
  let entry = inbound_stream(2_097_152, Some(reply_to))
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry)]),
      highest_client_stream_id_seen: 1,
      conn_recv_window: 2_097_152,
    )

  let assert connection.Proceed(_state) =
    connection.handle_data(state, 1, True, <<>>, 0)

  let assert Ok(http2.DoneEvent([])) = process.receive(reply_to, 100)
}

pub fn handle_data_keeps_reader_parked_on_empty_open_frame_test() {
  let reply_to = process.new_subject()
  let entry = inbound_stream(2_097_152, Some(reply_to))
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry)]),
      highest_client_stream_id_seen: 1,
      conn_recv_window: 2_097_152,
    )

  let assert connection.Proceed(state) =
    connection.handle_data(state, 1, False, <<>>, 0)

  assert process.receive(reply_to, 0) == Error(Nil)

  let assert Ok(updated) = dict.get(state.streams, 1)
  assert updated.parked_reader == Some(reply_to)
  assert updated.request_half_closed == False
}

pub fn handle_data_keeps_trailers_left_by_an_earlier_block_test() {
  let entry =
    connection.Stream(..inbound_stream(2_097_152, None), trailers: [
      #("x-checksum", "deadbeef"),
    ])
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry)]),
      highest_client_stream_id_seen: 1,
      conn_recv_window: 2_097_152,
    )

  let assert connection.Proceed(state) =
    connection.handle_data(state, 1, False, <<"abc":utf8>>, 3)

  let assert Ok(updated) = dict.get(state.streams, 1)
  assert updated.trailers == [#("x-checksum", "deadbeef")]
}

pub fn handle_data_stream_window_violation_rejects_stream_test() {
  let entry = inbound_stream(5, None)
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry)]),
      highest_client_stream_id_seen: 1,
    )

  let result = connection.handle_data(state, 1, False, <<0:size(80)>>, 10)

  let assert connection.RejectStream(state, 1, frame.FlowControlError) = result
  assert state.conn_recv_window == 65_535 - 10
}

pub fn handle_data_conn_window_violation_terminates_test() {
  let entry = inbound_stream(65_535, None)
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry)]),
      conn_recv_window: 5,
      highest_client_stream_id_seen: 1,
    )

  let result = connection.handle_data(state, 1, False, <<0:size(80)>>, 10)

  let assert connection.Terminate(Some(frame.FlowControlError)) = result
}

pub fn handle_data_on_idle_stream_is_protocol_error_test() {
  let state = connection.test_state()

  let result = connection.handle_data(state, 3, False, <<"x":utf8>>, 1)

  let assert connection.Terminate(Some(frame.ProtocolError)) = result
}

pub fn handle_data_on_already_closed_stream_is_connection_error_test() {
  let state =
    connection.State(
      ..connection.test_state(),
      highest_client_stream_id_seen: 5,
    )

  let result = connection.handle_data(state, 3, False, <<"x":utf8>>, 1)

  assert result == connection.Terminate(Some(frame.StreamClosed))
}

pub fn handle_data_buffered_without_reader_still_credits_conn_window_test() {
  let entry = inbound_stream(100_000, None)
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry)]),
      highest_client_stream_id_seen: 1,
    )
  let chunk = <<0:size({ 40_000 * 8 })>>

  let result = connection.handle_data(state, 1, False, chunk, 40_000)

  let assert connection.ProceedWithOutbound(state, out) = result
  let bytes = bytes_tree.to_bit_array(out)
  let assert Ok(#(frame.WindowUpdate(0, 2_071_617), rest)) =
    frame.decode(bytes, 16_384)
  assert rest == <<>>
  assert state.conn_recv_window == 2_097_152

  let assert Ok(updated) = dict.get(state.streams, 1)
  assert updated.recv_window == 100_000 - 40_000
}

pub fn handle_data_on_already_closed_stream_with_large_chunk_is_connection_error_test() {
  let state =
    connection.State(
      ..connection.test_state(),
      highest_client_stream_id_seen: 5,
    )
  let chunk = <<0:size({ 40_000 * 8 })>>

  let result = connection.handle_data(state, 3, False, chunk, 40_000)

  assert result == connection.Terminate(Some(frame.StreamClosed))
}

pub fn handle_data_on_already_closed_stream_can_exceed_conn_window_test() {
  let state =
    connection.State(
      ..connection.test_state(),
      highest_client_stream_id_seen: 5,
      conn_recv_window: 5,
    )

  let result = connection.handle_data(state, 3, False, <<0:size(80)>>, 10)

  assert result == connection.Terminate(Some(frame.FlowControlError))
}

pub fn handle_data_with_stream_id_zero_is_protocol_error_test() {
  let state = connection.test_state()

  let result = connection.handle_data(state, 0, False, <<"x":utf8>>, 1)

  assert result == connection.Terminate(Some(frame.ProtocolError))
}

pub fn handle_data_after_half_closed_remote_rejects_stream_test() {
  let entry =
    connection.Stream(..inbound_stream(65_535, None), request_half_closed: True)
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, entry)]),
      highest_client_stream_id_seen: 1,
    )

  let result = connection.handle_data(state, 1, False, <<"x":utf8>>, 1)

  let assert connection.RejectStream(state, 1, frame.StreamClosed) = result
  assert state.conn_recv_window == 65_535 - 1
}

pub fn stream_recv_credit_above_low_water_mark_does_not_emit_test() {
  let entry = inbound_stream(300_000, None)

  let #(entry, increment) =
    connection.stream_recv_credit(entry, http2.default_options())

  assert increment == 0
  assert entry.recv_window == 300_000
}

pub fn stream_recv_credit_at_low_water_mark_refills_to_high_test() {
  let entry = inbound_stream(262_144, None)

  let #(entry, increment) =
    connection.stream_recv_credit(entry, http2.default_options())

  assert increment == 2_097_152 - 262_144
  assert entry.recv_window == 2_097_152
}

pub fn stream_recv_credit_below_low_water_mark_refills_to_high_test() {
  let entry = inbound_stream(1000, None)

  let #(entry, increment) =
    connection.stream_recv_credit(entry, http2.default_options())

  assert increment == 2_097_152 - 1000
  assert entry.recv_window == 2_097_152
}

pub fn conn_recv_credit_above_low_water_mark_does_not_emit_test() {
  let state =
    connection.State(..connection.test_state(), conn_recv_window: 300_000)

  let #(state, increment) = connection.conn_recv_credit(state)

  assert increment == 0
  assert state.conn_recv_window == 300_000
}

pub fn conn_recv_credit_below_low_water_mark_refills_to_high_test() {
  let state =
    connection.State(..connection.test_state(), conn_recv_window: 1000)

  let #(state, increment) = connection.conn_recv_credit(state)

  assert increment == 2_097_152 - 1000
  assert state.conn_recv_window == 2_097_152
}

pub fn trailers_after_data_marks_half_closed_test() {
  let payload = encode(minimal_headers())
  let assert connection.Proceed(state) =
    connection.handle_headers(connection.test_state(), 1, False, True, payload)

  let trailer_payload = encode([custom_field()])
  let result = connection.handle_headers(state, 1, True, True, trailer_payload)

  let assert connection.Proceed(state) = result
  let assert Ok(entry) = dict.get(state.streams, 1)
  assert entry.request_half_closed == True
}

pub fn trailers_with_pseudo_header_is_protocol_error_test() {
  let payload = encode(minimal_headers())
  let assert connection.Proceed(state) =
    connection.handle_headers(connection.test_state(), 1, False, True, payload)

  let trailer_payload = encode([method_get()])
  let result = connection.handle_headers(state, 1, True, True, trailer_payload)

  let assert connection.RejectStream(_, 1, frame.ProtocolError) = result
}

pub fn trailers_without_end_stream_is_protocol_error_test() {
  let payload = encode(minimal_headers())
  let assert connection.Proceed(state) =
    connection.handle_headers(connection.test_state(), 1, False, True, payload)

  let trailer_payload = encode([custom_field()])
  let result = connection.handle_headers(state, 1, False, True, trailer_payload)

  let assert connection.RejectStream(_, 1, frame.ProtocolError) = result
}

pub fn trailers_are_delivered_to_parked_reader_test() {
  let payload = encode(minimal_headers())
  let assert connection.Proceed(state) =
    connection.handle_headers(connection.test_state(), 1, False, True, payload)

  let reply_to = process.new_subject()
  let assert Ok(entry) = dict.get(state.streams, 1)
  let state =
    connection.State(
      ..state,
      streams: dict.insert(
        state.streams,
        1,
        connection.Stream(..entry, parked_reader: Some(reply_to)),
      ),
    )

  let trailer_payload = encode([custom_field()])
  let result = connection.handle_headers(state, 1, True, True, trailer_payload)
  let assert connection.Proceed(_state) = result

  let assert Ok(http2.DoneEvent(trailers)) = process.receive(reply_to, 100)
  assert trailers == [#("x-custom", "some-longer-header-value-here")]
}

pub fn trailers_with_invalid_header_is_protocol_error_test() {
  let payload = encode(minimal_headers())
  let assert connection.Proceed(state) =
    connection.handle_headers(connection.test_state(), 1, False, True, payload)

  let bad_trailer =
    encode([
      alpacki.HeaderField(
        <<"X-Bad":utf8>>,
        <<"v":utf8>>,
        alpacki.WithoutIndexing,
      ),
    ])
  let result = connection.handle_headers(state, 1, True, True, bad_trailer)

  let assert connection.RejectStream(_, 1, frame.ProtocolError) = result
}

pub fn content_length_exceeded_rejects_stream_test() {
  let payload = encode(headers_with_content_length("5"))
  let assert connection.Proceed(state) =
    connection.handle_headers(connection.test_state(), 1, False, True, payload)

  let result = connection.handle_data(state, 1, False, <<"toolong":utf8>>, 7)

  let assert connection.RejectStream(_, 1, frame.ProtocolError) = result
}

pub fn content_length_short_at_end_stream_rejects_stream_test() {
  let payload = encode(headers_with_content_length("5"))
  let assert connection.Proceed(state) =
    connection.handle_headers(connection.test_state(), 1, False, True, payload)

  let result = connection.handle_data(state, 1, True, <<"abc":utf8>>, 3)

  let assert connection.RejectStream(_, 1, frame.ProtocolError) = result
}

pub fn content_length_matching_body_is_accepted_test() {
  let payload = encode(headers_with_content_length("5"))
  let assert connection.Proceed(state) =
    connection.handle_headers(connection.test_state(), 1, False, True, payload)

  let result = connection.handle_data(state, 1, True, <<"abcde":utf8>>, 5)

  assert result != connection.RejectStream(state, 1, frame.ProtocolError)
}

pub fn content_length_nonzero_with_no_body_rejects_before_spawn_test() {
  let payload = encode(headers_with_content_length("5"))

  let result =
    connection.handle_headers(connection.test_state(), 1, True, True, payload)

  let assert connection.RejectStream(state, 1, frame.ProtocolError) = result
  assert dict.get(state.streams, 1) == Error(Nil)
}

fn queued_stream(
  send_window: Int,
  chunks: List(http2.Chunk),
) -> connection.Stream {
  let pending =
    list.fold(chunks, connection.no_chunks(), fn(pending, chunk) {
      let assert Ok(pending) = connection.push_chunk(pending, chunk)
      pending
    })

  connection.Stream(..pending_stream(send_window, <<>>), pending:)
}

pub fn queued_chunks_acknowledge_each_on_full_delivery_test() {
  let first = process.new_subject()
  let second = process.new_subject()
  let entry =
    queued_stream(65_535, [
      http2.Chunk(<<"one":utf8>>, Some(first)),
      http2.Finish(<<"two":utf8>>, Some(second)),
    ])

  let assert connection.FlushAccumulated(state, out, True) =
    connection.do_flush_stream(
      connection.test_state(),
      1,
      entry,
      bytes_tree.new(),
      False,
    )

  let assert Ok(#(frame.Data(1, False, <<"one":utf8>>, 3), rest)) =
    frame.decode(bytes_tree.to_bit_array(out), 16_384)
  let assert Ok(#(frame.Data(1, True, <<"two":utf8>>, 3), <<>>)) =
    frame.decode(rest, 16_384)

  assert process.receive(first, 0) == Ok(http2.WriteAck)
  assert process.receive(second, 0) == Ok(http2.WriteAck)
  assert dict.get(state.streams, 1) == Error(Nil)
  assert state.conn_send_window == 65_535 - 6
}

pub fn queue_preserves_order_across_the_reversal_test() {
  let entry =
    queued_stream(65_535, [
      http2.Chunk(<<"a":utf8>>, None),
      http2.Chunk(<<"b":utf8>>, None),
      http2.Finish(<<"c":utf8>>, None),
    ])

  let assert connection.FlushAccumulated(state, out, True) =
    connection.do_flush_stream(
      connection.test_state(),
      1,
      entry,
      bytes_tree.new(),
      False,
    )

  let assert Ok(#(frame.Data(1, False, <<"a":utf8>>, 1), rest)) =
    frame.decode(bytes_tree.to_bit_array(out), 16_384)
  let assert Ok(#(frame.Data(1, False, <<"b":utf8>>, 1), rest)) =
    frame.decode(rest, 16_384)
  let assert Ok(#(frame.Data(1, True, <<"c":utf8>>, 1), <<>>)) =
    frame.decode(rest, 16_384)

  assert dict.get(state.streams, 1) == Error(Nil)
  assert state.conn_send_window == 65_535 - 3
}

pub fn partial_drain_withholds_acknowledgement_until_complete_test() {
  let ack = process.new_subject()
  let entry = queued_stream(3, [http2.Chunk(<<"hello":utf8>>, Some(ack))])

  let assert connection.FlushAccumulated(state, _blocked_out, True) =
    connection.do_flush_stream(
      connection.test_state(),
      1,
      entry,
      bytes_tree.new(),
      False,
    )

  assert process.receive(ack, 0) == Error(Nil)
  let assert Ok(blocked) = dict.get(state.streams, 1)

  let assert connection.FlushAccumulated(state, out, True) =
    connection.do_flush_stream(
      state,
      1,
      connection.Stream(..blocked, send_window: 10),
      bytes_tree.new(),
      False,
    )

  let assert Ok(#(frame.Data(1, False, <<"lo":utf8>>, 2), <<>>)) =
    frame.decode(bytes_tree.to_bit_array(out), 16_384)
  assert process.receive(ack, 0) == Ok(http2.WriteAck)

  let assert Ok(drained) = dict.get(state.streams, 1)
  assert drained.pending == connection.no_chunks()
}

pub fn empty_terminator_closes_stream_with_the_window_shut_test() {
  let ack = process.new_subject()
  let state = connection.State(..connection.test_state(), conn_send_window: 0)
  let entry = queued_stream(0, [http2.Finish(<<>>, Some(ack))])

  let assert connection.FlushAccumulated(state, out, True) =
    connection.do_flush_stream(state, 1, entry, bytes_tree.new(), False)

  let assert Ok(#(frame.Data(1, True, <<>>, 0), <<>>)) =
    frame.decode(bytes_tree.to_bit_array(out), 16_384)
  assert process.receive(ack, 0) == Ok(http2.WriteAck)
  assert dict.get(state.streams, 1) == Error(Nil)
}

fn writing_stream(queued: Int) -> connection.Stream {
  connection.Stream(
    ..queued_stream(0, [http2.Chunk(<<0:size(queued)>>, None)]),
    writer: Some(process.new_subject()),
  )
}

pub fn a_writer_already_over_the_limit_is_stopped_test() {
  let options = http2.Options(..http2.default_options(), send_buffer_limit: 8)

  assert connection.over_send_buffer_limit(writing_stream(80), options)
}

pub fn a_writer_within_the_limit_carries_on_test() {
  let options = http2.Options(..http2.default_options(), send_buffer_limit: 64)

  assert !connection.over_send_buffer_limit(writing_stream(80), options)
}

// One huge message is a single legitimate send: the queue it is measured
// against is the one before it, which is empty.
pub fn one_message_larger_than_the_limit_is_allowed_test() {
  let options = http2.Options(..http2.default_options(), send_buffer_limit: 8)
  let empty =
    connection.Stream(
      ..queued_stream(0, []),
      writer: Some(process.new_subject()),
    )

  assert !connection.over_send_buffer_limit(empty, options)
}

pub fn a_waiting_caller_is_never_capped_test() {
  let options = http2.Options(..http2.default_options(), send_buffer_limit: 8)
  let entry = queued_stream(0, [http2.Chunk(<<0:size(80)>>, None)])

  assert !connection.over_send_buffer_limit(entry, options)
}

fn pending_ids(state: connection.State, cursor: Int) -> List(Int) {
  connection.State(..state, flush_cursor: cursor)
  |> connection.rotated_pending
  |> list.map(fn(entry) { entry.0 })
}

pub fn pending_streams_take_turns_at_the_connection_window_test() {
  let queued = queued_stream(0, [http2.Chunk(<<"x":utf8>>, None)])
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(5, queued), #(1, queued), #(3, queued)]),
    )

  assert pending_ids(state, 0) == [1, 3, 5]
  assert pending_ids(state, 1) == [3, 5, 1]
  assert pending_ids(state, 3) == [5, 1, 3]
  assert pending_ids(state, 5) == [1, 3, 5]
}

pub fn streams_with_nothing_queued_are_not_flushed_test() {
  let queued = queued_stream(0, [http2.Chunk(<<"x":utf8>>, None)])
  let idle = queued_stream(0, [])
  let state =
    connection.State(
      ..connection.test_state(),
      streams: dict.from_list([#(1, idle), #(3, queued), #(5, idle)]),
    )

  assert pending_ids(state, 0) == [3]
}
