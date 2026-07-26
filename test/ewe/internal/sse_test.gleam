import ewe/internal/sse
import gleam/bit_array
import gleam/bytes_tree
import gleam/option.{None, Some}

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

pub fn plain_data_test() {
  assert encode(data("hello")) == "data: hello\n\n"
}

pub fn empty_event_is_just_the_terminator_test() {
  assert encode(sse.new()) == "\n"
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

pub fn trailing_break_leaves_an_empty_field_test() {
  assert encode(data("one\n")) == "data: one\ndata: \n\n"
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

pub fn field_order_test() {
  let event =
    sse.Event(
      comment: Some("why"),
      name: Some("tick"),
      id: Some("7"),
      retry: Some(3000),
      data: Some("body"),
    )

  assert encode(event)
    == ": why\nevent: tick\nid: 7\nretry: 3000\ndata: body\n\n"
}

pub fn comment_only_is_a_valid_keep_alive_test() {
  assert encode(sse.Event(..sse.new(), comment: Some(""))) == ": \n\n"
}

pub fn absent_fields_are_omitted_test() {
  assert encode(sse.Event(..sse.new(), id: Some("9"), retry: None))
    == "id: 9\n\n"
}
