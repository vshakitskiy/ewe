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
    encoder.encode_response(response, http.Get, parser.Http11, http1.KeepAlive)

  let assert Ok(text) =
    bytes_tree.to_bit_array(encoded.head)
    |> bit_array.to_string

  #(text, encoded.remainder)
}

fn occurrences(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

pub fn computed_content_length_is_the_only_one_test() {
  let out = head([], connection.Text("hello"))

  assert occurrences(out, "content-length:") == 1
  assert string.contains(out, "content-length: 5")
}

pub fn handler_content_length_is_dropped_test() {
  let out = head([#("content-length", "999")], connection.Text("hello"))

  assert occurrences(out, "content-length:") == 1
  assert string.contains(out, "content-length: 5")
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
  |> encoder.encode_response(http.Get, parser.Http11, http1.KeepAlive)
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
  assert frame(<<"hello world!":utf8>>) == <<"C\r\nhello world!\r\n":utf8>>
}

pub fn empty_chunk_is_not_framed_test() {
  assert frame(<<>>) == <<>>
    as "a zero-size chunk is the last-chunk marker and would end the body"
}
