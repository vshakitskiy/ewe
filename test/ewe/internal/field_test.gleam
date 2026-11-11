import ewe/internal/field
import gleam/int
import gleam/list
import gleam/string

pub fn field_values_validate_bytes_after_ascii_chunks_test() -> Nil {
  list.each([0, 27, 28, 29, 55, 56, 57], fn(position) {
    let prefix = string.repeat("a", position)

    int.range(from: 0, to: 128, with: Nil, run: fn(_state, byte) {
      let value = <<prefix:utf8, "a", byte, "z">>

      assert field.is_value(value) == { byte != 0 && byte != 10 && byte != 13 }
    })
  })
}

pub fn field_values_require_utf8_and_trimmed_edges_test() -> Nil {
  assert field.is_value(<<>>)
  assert field.is_value(<<"café">>)
  assert field.is_value(<<"a\tb">>)
  assert !field.is_value(<<" leading">>)
  assert !field.is_value(<<"trailing\t">>)
  assert !field.is_value(<<195>>)
  assert !field.is_value(<<255>>)
}

pub fn field_names_are_nonempty_lowercase_ascii_test() -> Nil {
  assert field.is_name(<<"content-type">>)
  assert !field.is_name(<<>>)
  assert !field.is_name(<<"Content-Type">>)
  assert !field.is_name(<<"bad name">>)
  assert !field.is_name(<<"bad:name">>)
  assert !field.is_name(<<"é">>)
}

pub fn field_normalization_preserves_non_ascii_bytes_test() -> Nil {
  assert field.lowercase_ascii(<<"AbC-é">>) == <<"abc-é">>
  assert field.trim_whitespace(<<" \tvalue\t ">>) == <<"value">>
  assert field.trim_whitespace(<<" \t ">>) == <<>>
  assert field.find_unsafe_byte("safe") == Error(Nil)
  assert field.find_unsafe_byte("é\rvalue") == Ok(2)
}

pub fn ascii_chunks_check_every_byte_lane_test() -> Nil {
  let assert <<safe_word:56>> = <<"aaaaaaa">>

  int.range(from: 0, to: 7, with: Nil, run: fn(_state, position) {
    let before = string.repeat("a", position)
    let after = string.repeat("a", 6 - position)

    int.range(from: 0, to: 256, with: Nil, run: fn(_state, byte) {
      let assert <<word:56>> = <<before:utf8, byte, after:utf8>>

      // The block check selects bytes in 14..127 for scanning together. Other
      // bytes go through individual inspection, including valid internal tabs.
      let can_skip = byte >= 14 && byte < 128

      assert field.is_ascii_chunk(word, safe_word, safe_word, safe_word)
        == can_skip
      assert field.is_ascii_chunk(safe_word, word, safe_word, safe_word)
        == can_skip
      assert field.is_ascii_chunk(safe_word, safe_word, word, safe_word)
        == can_skip
      assert field.is_ascii_chunk(safe_word, safe_word, safe_word, word)
        == can_skip
    })
  })
}
