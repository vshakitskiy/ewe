import gleam/bytes_tree
import gleam/int
import gleam/list
import gleam/option

pub type Event {
  Event(
    comment: option.Option(String),
    name: option.Option(String),
    id: option.Option(String),
    retry: option.Option(Int),
    data: option.Option(String),
  )
}

pub fn new() -> Event {
  Event(
    comment: option.None,
    name: option.None,
    id: option.None,
    retry: option.None,
    data: option.None,
  )
}

pub fn encode(event: Event) -> bytes_tree.BytesTree {
  bytes_tree.new()
  |> append_lines(": ", event.comment)
  |> append_field("event: ", event.name)
  |> append_field("id: ", event.id)
  |> append_field("retry: ", option.map(event.retry, int.to_string))
  |> append_lines("data: ", event.data)
  |> bytes_tree.append(newline)
}

const newline = <<"\n":utf8>>

fn append_field(
  tree: bytes_tree.BytesTree,
  prefix: String,
  value: option.Option(String),
) -> bytes_tree.BytesTree {
  case value {
    option.None -> tree
    option.Some(value) ->
      bytes_tree.append_string(tree, prefix)
      |> bytes_tree.append_string(strip_breaks(value))
      |> bytes_tree.append(newline)
  }
}

fn append_lines(
  tree: bytes_tree.BytesTree,
  prefix: String,
  value: option.Option(String),
) -> bytes_tree.BytesTree {
  case value {
    option.None -> tree
    option.Some(value) -> {
      use tree, line <- list.fold(split_breaks(value), tree)
      bytes_tree.append_string(tree, prefix)
      |> bytes_tree.append_string(line)
      |> bytes_tree.append(newline)
    }
  }
}

@external(erlang, "ewe_sse_ffi", "split_breaks")
fn split_breaks(value: String) -> List(String)

@external(erlang, "ewe_sse_ffi", "strip_breaks")
fn strip_breaks(value: String) -> String
