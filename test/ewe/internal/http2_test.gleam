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
      <<"now">>,
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
      "now",
    >>)
  assert list.any(fields, fn(field) {
    field.name == <<"content-length">> && field.value == <<"10">>
  })
}

pub fn omitted_length_drops_the_handlers_test() {
  let assert Ok(fields) =
    http2.response_fields(204, [#("content-length", "10")], http2.Omitted, <<
      "now",
    >>)
  assert !list.any(fields, fn(field) { field.name == <<"content-length">> })
}

pub fn set_cookie_is_never_indexed_test() {
  let assert Ok(fields) =
    http2.response_fields(200, [#("set-cookie", "secret")], http2.Length(1), <<
      "now",
    >>)

  let assert Ok(field) =
    list.find(fields, fn(field) { field.name == <<"set-cookie">> })
  assert field.indexing == alpacki.NeverIndexed
}

pub fn unsafe_header_is_refused_test() {
  let refused = fn(name, value) {
    http2.response_fields(200, [#(name, value)], http2.Length(0), <<"now">>)
    == Error(http2.UnsafeHeader(name))
  }
  assert refused("x-a", "a\r\nb")
  assert refused("x-a", "a\u{0}b")
  assert refused("x-a\n", "b")
}
