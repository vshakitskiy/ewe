import ewe/internal/handler

pub fn full_preface_in_one_read_test() {
  let buffer = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8>>
  assert handler.sniff_preface(buffer) == handler.Http2Preface(<<>>)
}

pub fn preface_with_trailing_settings_frame_test() {
  let buffer = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8, 0, 0, 0, 4, 0>>
  let assert handler.Http2Preface(remaining) = handler.sniff_preface(buffer)

  assert remaining == <<0, 0, 0, 4, 0>>
}

pub fn preface_split_across_reads_test() {
  let first = <<"PRI * HTTP/2":utf8>>
  assert handler.sniff_preface(first) == handler.NeedMoreData

  let second = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8>>
  assert handler.sniff_preface(second) == handler.Http2Preface(<<>>)
}

pub fn empty_buffer_needs_more_data_test() {
  assert handler.sniff_preface(<<>>) == handler.NeedMoreData
}

pub fn ordinary_http1_request_diverges_immediately_test() {
  let buffer = <<"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8>>
  assert handler.sniff_preface(buffer) == handler.NotHttp2(buffer)
}

pub fn preface_lookalike_diverging_partway_test() {
  let buffer = <<"PRI / HTTP/1.1\r\n\r\n":utf8>>
  assert handler.sniff_preface(buffer) == handler.NotHttp2(buffer)
}
