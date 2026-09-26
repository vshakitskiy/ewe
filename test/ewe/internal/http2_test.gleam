import alpacki
import ewe/internal/http2
import gleam/bit_array
import gleam/list

pub fn response_fields_test() {
  let assert Ok(fields) =
    http2.response_fields(
      200,
      [
        #("content-type", "text/plain"),
        #("connection", "close"),
        #("keep-alive", "5"),
        #("transfer-encoding", "chunked"),
        #("te", "trailers"),
        #("upgrade", "h2c"),
        #(":path", "/"),
        #("date", "stale"),
        #("content-length", "999"),
        #("x-ok", "v"),
      ],
      http2.Length(5),
      <<"now":utf8>>,
    )

  assert list.map(fields, fn(field) {
      let assert Ok(name) = bit_array.to_string(field.name)
      let assert Ok(value) = bit_array.to_string(field.value)
      #(name, value)
    })
    == [
      #(":status", "200"),
      #("date", "now"),
      #("content-length", "5"),
      #("content-type", "text/plain"),
      #("x-ok", "v"),
    ]
}

pub fn unknown_length_keeps_the_handlers_test() {
  let assert Ok(fields) =
    http2.response_fields(200, [#("content-length", "10")], http2.Unknown, <<
      "now":utf8,
    >>)
  assert list.any(fields, fn(field) {
    field.name == <<"content-length":utf8>> && field.value == <<"10":utf8>>
  })
}

pub fn omitted_length_drops_the_handlers_test() {
  let assert Ok(fields) =
    http2.response_fields(204, [#("content-length", "10")], http2.Omitted, <<
      "now":utf8,
    >>)
  assert !list.any(fields, fn(field) { field.name == <<"content-length":utf8>> })
}

pub fn indexing_policy_test() {
  let assert Ok(fields) =
    http2.response_fields(
      200,
      [
        #("set-cookie", "secret"),
        #("content-type", "text/plain"),
        #("x-id", "1"),
      ],
      http2.Length(1),
      <<"now":utf8>>,
    )

  let indexing = fn(name) {
    let assert Ok(field) = list.find(fields, fn(field) { field.name == name })
    field.indexing
  }
  assert indexing(<<"set-cookie":utf8>>) == alpacki.NeverIndexed
  assert indexing(<<"content-type":utf8>>) == alpacki.WithIndexing
  assert indexing(<<"content-length":utf8>>) == alpacki.WithoutIndexing
  assert indexing(<<"date":utf8>>) == alpacki.WithIndexing
  assert indexing(<<"x-id":utf8>>) == alpacki.WithoutIndexing
}

pub fn unsafe_header_is_refused_test() {
  let refused = fn(name, value) {
    http2.response_fields(200, [#(name, value)], http2.Length(0), <<"now":utf8>>)
    == Error(http2.UnsafeHeader(name))
  }
  assert refused("x-a", "a\r\nb")
  assert refused("x-a", "a\u{0}b")
  assert refused("x-a\n", "b")
}
