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
  let response = response.Response(status: 200, headers:, body:)
  let assert Ok(encoded) =
    encoder.encode_response(response, http.Get, parser.Http11, http1.KeepAlive)

  let assert Ok(text) =
    bytes_tree.to_bit_array(encoded.head)
    |> bit_array.to_string

  text
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

pub fn uppercase_content_length_is_dropped_test() {
  let out = head([#("Content-Length", "999")], connection.Text("hello"))

  assert occurrences(out, "999") == 0
    as "a differently cased content-length is still a content-length, and two on one response is a framing bug"
}

pub fn mixed_case_transfer_encoding_is_dropped_test() {
  let out = head([#("Transfer-Encoding", "chunked")], connection.Text("hi"))

  assert occurrences(out, "chunked") == 0
}

pub fn uppercase_connection_close_is_honoured_test() {
  let out = head([#("Connection", "close")], connection.Text("hi"))

  assert string.contains(out, "connection: close")
  assert occurrences(out, "connection:") == 1
    as "the handler's connection header must drive the real one, not sit beside it"
}

pub fn header_names_are_normalised_to_lowercase_test() {
  let out = head([#("X-Request-Id", "abc")], connection.Text("hi"))

  assert string.contains(out, "x-request-id: abc")
  assert occurrences(out, "X-Request-Id") == 0
}

pub fn ordinary_headers_are_kept_test() {
  let out = head([#("x-trace", "1")], connection.Text("hi"))

  assert string.contains(out, "x-trace: 1")
}
