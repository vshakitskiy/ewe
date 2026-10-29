import ewe/internal/connection
import ewe/internal/http1/connection as http1
import ewe/internal/http1/encoder
import ewe/internal/http1/parser
import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/http/response
import gleam/list
import gleam/string

fn head(headers: List(#(String, String)), body: connection.Body) -> String {
  encode(200, headers, body).0
}

fn encode(
  status: Int,
  headers: List(#(String, String)),
  body: connection.Body,
) -> #(String, encoder.Remainder) {
  let response = response.Response(status:, headers:, body:)
  let assert Ok(encoded) =
    encoder.encode_response(
      response,
      http.Get,
      parser.Http11,
      http1.KeepAlive,
      current_date_line(),
    )

  let assert Ok(text) =
    bytes_tree.to_bit_array(encoded.head)
    |> bit_array.to_string

  #(text, encoded.remainder)
}

fn current_date_line() -> BitArray {
  encoder.date_line(encoder.no_date_line).1
}

fn occurrences(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

pub fn handler_content_length_is_dropped_test() {
  let out = head([#("content-length", "999")], connection.Text("hello"))

  assert occurrences(out, "content-length:") == 1
  assert string.contains(out, "content-length: 5")
}

pub fn date_is_the_current_time_test() {
  let assert Ok(date) =
    head([], connection.Text("hello"))
    |> string.split("\r\n")
    |> list.find_map(fn(line) {
      case line {
        "date: " <> value -> Ok(value)
        _line -> Error(Nil)
      }
    })

  let assert Ok(age) = date_age(date)
  assert age >= 0 && age <= 2
}

pub fn date_line_is_kept_within_its_second_test() {
  let fresh = encoder.date_line(encoder.no_date_line)
  let cached = #(fresh.0, <<"date: cached\r\n">>)
  let kept = encoder.date_line(cached)

  assert kept == cached || kept.0 != fresh.0
    as "the line is rebuilt only when gnomon's clock moves to another second"
}

pub fn date_line_from_another_second_is_rebuilt_test() {
  let stale = #(0, <<"date: stale\r\n">>)

  assert encoder.date_line(stale).1 != stale.1
}

pub fn no_content_carries_no_framing_or_body_test() {
  let #(out, remainder) = encode(204, [], connection.Text("hi"))

  assert occurrences(out, "content-length:") == 0
    as "content-length is forbidden on 204, and a client that reads one waits for a body that never comes"
  assert remainder == encoder.NoRemainder
}

pub fn not_modified_carries_no_body_test() {
  let #(out, remainder) = encode(304, [], connection.Text("hi"))

  assert occurrences(out, "content-length:") == 0
  assert remainder == encoder.NoRemainder
}

fn encode_status(status: Int) -> Result(encoder.Encoded, encoder.EncodeError) {
  response.Response(status:, headers: [], body: connection.Empty)
  |> encoder.encode_response(
    http.Get,
    parser.Http11,
    http1.KeepAlive,
    current_date_line(),
  )
}

pub fn informational_status_refused_test() {
  assert encode_status(100) == Error(encoder.InvalidStatus(100))
    as "a 1xx is interim, so the client would keep waiting for the real response"
}

pub fn status_outside_valid_range_refused_test() {
  assert encode_status(42) == Error(encoder.InvalidStatus(42))
  assert encode_status(600) == Error(encoder.InvalidStatus(600))
}

fn frame(chunk: BitArray) -> BitArray {
  encoder.frame(bytes_tree.from_bit_array(chunk), http1.ChunkedStream)
  |> bytes_tree.to_bit_array
}

pub fn chunk_is_framed_with_its_size_test() {
  assert frame(<<"hello world!">>) == <<"C\r\nhello world!\r\n">>
}

pub fn empty_chunk_is_not_framed_test() {
  assert frame(<<>>) == <<>>
    as "a zero-size chunk is the last-chunk marker and would end the body"
}

@external(erlang, "ewe_test_ffi", "date_age")
fn date_age(date: String) -> Result(Int, Nil)
