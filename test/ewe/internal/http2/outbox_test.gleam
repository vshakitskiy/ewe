import ewe/internal/file
import ewe/internal/http2/outbox
import gleam/bytes_tree

fn take(
  box: outbox.Outbox,
  limit: Int,
) -> #(BitArray, Int, Bool, outbox.Outbox) {
  let assert Ok(#(outbox.Bytes(bytes:, size:), last, rest)) =
    outbox.take(box, limit, file.read)
  #(bytes_tree.to_bit_array(bytes), size, last, rest)
}

pub fn empty_pieces_are_dropped_test() {
  let box = outbox.new() |> outbox.push(outbox.bytes(<<>>))
  assert outbox.size(box) == 0
  let #(bytes, size, _last, _rest) = take(box, 10)
  assert bytes == <<>>
  assert size == 0
}

pub fn small_pieces_are_joined_into_one_frame_test() {
  let box =
    outbox.new()
    |> outbox.push(outbox.bytes(<<"ab":utf8>>))
    |> outbox.push(outbox.bytes(<<"cd":utf8>>))
    |> outbox.push(outbox.bytes(<<"ef":utf8>>))

  let #(bytes, size, last, rest) = take(box, 5)
  assert bytes == <<"abcde":utf8>>
  assert size == 5
  assert !last
  assert outbox.size(rest) == 1

  let #(bytes, _size, _last, rest) = take(rest, 5)
  assert bytes == <<"f":utf8>>
  assert outbox.size(rest) == 0
}

pub fn the_last_piece_of_a_finished_body_ends_it_test() {
  let box =
    outbox.new()
    |> outbox.push(outbox.bytes(<<"abcdef":utf8>>))
    |> outbox.finish

  let #(_bytes, _size, last, rest) = take(box, 4)
  assert !last
  let #(bytes, _size, last, _rest) = take(rest, 4)
  assert bytes == <<"ef":utf8>>
  assert last
}

pub fn an_unfinished_body_never_ends_test() {
  let box = outbox.new() |> outbox.push(outbox.bytes(<<"ab":utf8>>))
  let #(_bytes, _size, last, _rest) = take(box, 10)
  assert !last
}

pub fn a_file_is_read_into_memory_for_small_frames_test() {
  let assert Ok(handle) = file.open("gleam.toml")
  let assert Ok(expected) = file.read_range("gleam.toml", 5, 20)
  let box =
    outbox.new()
    |> outbox.push(outbox.File(handle, offset: 5, length: 20))
    |> outbox.finish

  let #(first, _size, last, rest) = take(box, 12)
  assert !last
  let #(second, _size, last, rest) = take(rest, 12)
  assert last
  assert outbox.size(rest) == 0
  assert <<first:bits, second:bits>> == expected

  file.close(handle)
}

pub fn a_file_is_sent_from_disk_for_large_frames_test() {
  let assert Ok(handle) = file.open("gleam.toml")
  let box =
    outbox.new()
    |> outbox.push(outbox.File(handle, offset: 5, length: 100_000))

  let assert Ok(#(outbox.File(offset: 5, length: 65_536, ..), False, rest)) =
    outbox.take(box, 65_536, file.read)
  assert outbox.size(rest) == 100_000 - 65_536

  file.close(handle)
}
