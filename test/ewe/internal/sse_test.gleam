import ewe/internal/sse
import gleam/bit_array
import gleam/bytes_tree
import gleam/option.{Some}

fn encode(event: sse.Event) -> String {
  let assert Ok(encoded) =
    sse.encode(event)
    |> bytes_tree.to_bit_array
    |> bit_array.to_string

  encoded
}

fn data(value: String) -> sse.Event {
  sse.Event(..sse.new(), data: Some(value))
}

pub fn multiline_data_becomes_repeated_fields_test() {
  assert encode(data("one\ntwo\nthree"))
    == "data: one\ndata: two\ndata: three\n\n"
}

pub fn crlf_counts_as_one_break_test() {
  assert encode(data("one\r\ntwo")) == "data: one\ndata: two\n\n"
    as "CRLF must match before the bare CR, or it would split twice"
}

pub fn lone_cr_counts_as_a_break_test() {
  assert encode(data("one\rtwo")) == "data: one\ndata: two\n\n"
}

pub fn breaks_are_stripped_from_single_line_fields_test() {
  let event =
    sse.Event(
      ..data("payload"),
      name: Some("up\ndata: forged"),
      id: Some("a\rb"),
    )

  assert encode(event) == "event: updata: forged\nid: ab\ndata: payload\n\n"
    as "a break in a single-line field could otherwise forge another field"
}
