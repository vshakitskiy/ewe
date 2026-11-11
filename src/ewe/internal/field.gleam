//// Shared HTTP field validation and byte operations.
////
//// HTTP/1 trims and normalises fields while scanning a request head. HTTP/2
//// checks fields already decoded from HPACK. Both use these helpers to check
//// field names and values, trim whitespace, and lowercase ASCII letters.

import gleam/bit_array
import gleam/int

pub const null_byte = 0

pub const horizontal_tab = 9

pub const carriage_return = 13

pub const line_feed = 10

pub const space = 32

const colon = 58

const lowercase_offset = 32

pub const uppercase_a = 65

pub const uppercase_z = 90

pub const delete = 127

pub const non_ascii_start = 128

pub const line_ending_size = 2

/// Width of a packed word in `is_ascii_chunk`.
///
pub const ascii_word_bits = 56

/// Size of the four-word block checked by `is_ascii_chunk`.
///
pub const ascii_chunk_size = 28

/// Low-bit mask used to repeat the lower bound across a packed word.
///
pub const byte_low_bits = 0x01_01_01_01_01_01_01

/// High-bit mask used to collect range-check signals from a packed word.
///
pub const byte_high_bits = 0x80_80_80_80_80_80_80

/// Inclusive lower bound for eligibility to skip byte-by-byte scanning.
///
pub const first_chunk_byte = 14

/// Returns whether all 28 bytes are in 14..127, allowing the value scanner to
/// skip byte-by-byte inspection of this block.
///
/// Each argument must be an unsigned 56-bit integer holding seven bytes. On the
/// 64-bit BEAM these words fit in immediate integers, so the range check uses
/// integer arithmetic without allocating large integers.
///
/// ```txt
/// | first: 7 bytes | second: 7 bytes | third: 7 bytes | fourth: 7 bytes |
///  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ 28 bytes ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
/// ```
///
/// The lower bound puts NUL, tab, LF, and CR on the byte-scanning path. Bytes
/// above 127 also take that path for UTF-8 checks. `False` asks the caller to
/// inspect the block; field validity is decided by the caller's validation.
///
pub fn is_ascii_chunk(
  first first: Int,
  second second: Int,
  third third: Int,
  fourth fourth: Int,
) -> Bool {
  // Use each byte's high bit to signal a byte outside 14..127. Multiplying
  // `byte_low_bits` by 14 produces 0E in every byte. Subtract that packed lower
  // bound from each word, then OR with the original to include bytes >= 128.
  // For individual bytes, the low eight result bits look like this:
  //
  // ```txt
  //   Input      Input - 14   Input OR result   High bit
  //   0D (CR)    FF           FF                set
  //   0E         00           0E                clear
  //   61 ('a')   53           73                clear
  //   80         72           F2                set
  // ```
  //
  // This is one integer subtraction per word, so borrowing can cross bytes.
  // If every byte is in 14..127, each subtraction needs no borrow and leaves
  // its high bit clear. Otherwise, either an input byte already has its high
  // bit set (>= 128), or the least significant byte below 14 underflows. The
  // latter sets a high bit before any borrow propagates to more significant
  // bytes. OR preserves that signal as the four words are combined.
  //
  // AND with `byte_high_bits` selects all seven high bits in the combined
  // word. The result is zero exactly when all 28 bytes are in range.
  let first_pair =
    int.bitwise_or(
      int.bitwise_or(first - first_chunk_byte * byte_low_bits, first),
      int.bitwise_or(second - first_chunk_byte * byte_low_bits, second),
    )
  let second_pair =
    int.bitwise_or(
      int.bitwise_or(third - first_chunk_byte * byte_low_bits, third),
      int.bitwise_or(fourth - first_chunk_byte * byte_low_bits, fourth),
    )

  int.bitwise_and(int.bitwise_or(first_pair, second_pair), byte_high_bits) == 0
}

/// Returns whether a field name is nonempty, lowercase ASCII with no spaces,
/// control bytes, DEL, or colon. Other visible punctuation is accepted.
///
/// ```gleam
/// field.is_name(<<"content-type">>) // True
/// field.is_name(<<"Content-Type">>) // False
/// field.is_name(<<"bad:name">>)     // False
/// field.is_name(<<>>)               // False
/// ```
///
pub fn is_name(name: BitArray) -> Bool {
  case name {
    <<>> -> False
    _name -> is_lowercase_name(name)
  }
}

fn is_lowercase_name(bits: BitArray) -> Bool {
  case bits {
    <<byte, remaining:bits>>
      if byte > space
      && byte < delete
      && byte != colon
      && { byte < uppercase_a || byte > uppercase_z }
    -> is_lowercase_name(remaining)
    <<>> -> True
    _bits -> False
  }
}

/// Returns whether a field value is valid UTF-8 with no NUL, CR, or LF, and no
/// leading or trailing space or tab. Empty values and internal tabs are valid.
/// Other control bytes are accepted.
///
/// ```gleam
/// field.is_value(<<"café">>)   // True
/// field.is_value(<<"a\tb">>)   // True
/// field.is_value(<<" value">>) // False
/// field.is_value(<<"a\r\nb">>) // False
/// field.is_value(<<195>>)      // False
/// ```
///
pub fn is_value(value: BitArray) -> Bool {
  let size = bit_array.byte_size(value)

  case size {
    0 -> True
    _size -> {
      let first = byte_at(value, 0)
      let last = byte_at(value, size - 1)
      let has_outer_whitespace =
        first == space
        || first == horizontal_tab
        || last == space
        || last == horizontal_tab

      case has_outer_whitespace {
        True -> False
        False -> scan_value(value, value)
      }
    }
  }
}

// `remaining` advances through the value; `original` supplies the complete byte
// sequence for UTF-8 validation when scanning finishes.
fn scan_value(remaining: BitArray, original: BitArray) -> Bool {
  case remaining {
    <<
      first:size(ascii_word_bits),
      second:size(ascii_word_bits),
      third:size(ascii_word_bits),
      fourth:size(ascii_word_bits),
      rest:bits,
    >> ->
      case is_ascii_chunk(first:, second:, third:, fourth:) {
        True -> scan_value(rest, original)
        False -> scan_value_bytes(remaining, original, False)
      }
    _remaining -> scan_value_bytes(remaining, original, False)
  }
}

fn scan_value_bytes(
  remaining: BitArray,
  original: BitArray,
  has_unicode: Bool,
) -> Bool {
  case remaining {
    <<"\u{0}", _rest:bits>> | <<"\n", _rest:bits>> | <<"\r", _rest:bits>> ->
      False
    <<byte, rest:bits>> ->
      scan_value_bytes(rest, original, has_unicode || byte >= non_ascii_start)
    <<>> -> !has_unicode || bit_array.is_utf8(original)
    _remaining -> False
  }
}

/// Removes leading and trailing spaces and tabs, preserving the interior.
///
/// ```txt
///   Input:   [SP][TAB][v][a][l][u][e][TAB][SP]
///   Bounds:          start = 2      end = 7
///   Slice:           [v][a][l][u][e]
/// ```
///
/// ```gleam
/// field.trim_whitespace(<<" \tvalue\t ">>) // <<"value">>
/// field.trim_whitespace(<<" \t ">>)        // <<>>
/// ```
///
pub fn trim_whitespace(bits: BitArray) -> BitArray {
  let size = bit_array.byte_size(bits)
  let start = skip_leading_whitespace(bits, 0, size)
  let end = skip_trailing_whitespace(bits, start, size)

  binary_part(bits, start, end - start)
}

/// Returns the first byte offset at or after `position` that is not a space or
/// tab, or the exclusive `end` if the entire range is whitespace.
/// The caller supplies byte offsets with `0 <= position <= end <= byte_size`.
///
pub fn skip_leading_whitespace(bits: BitArray, position: Int, end: Int) -> Int {
  case position < end {
    True ->
      case byte_at(bits, position) {
        byte if byte == space || byte == horizontal_tab ->
          skip_leading_whitespace(bits, position + 1, end)
        _byte -> position
      }
    False -> position
  }
}

/// Moves the exclusive `end` back past spaces and tabs, stopping at `start`.
/// The caller supplies byte offsets with `0 <= start <= end <= byte_size`.
///
pub fn skip_trailing_whitespace(bits: BitArray, start: Int, end: Int) -> Int {
  case end > start {
    True ->
      case byte_at(bits, end - 1) {
        byte if byte == space || byte == horizontal_tab ->
          skip_trailing_whitespace(bits, start, end - 1)
        _byte -> end
      }
    False -> end
  }
}

/// Converts ASCII uppercase letters to lowercase, preserving all other bytes.
/// Returns the original binary if there are no uppercase ASCII letters.
///
/// ```gleam
/// field.lowercase_ascii(<<"AbC-é">>) // <<"abc-é">>
/// ```
///
pub fn lowercase_ascii(bits: BitArray) -> BitArray {
  case has_uppercase(bits) {
    False -> bits
    True -> lowercase_bytes(bits, <<>>)
  }
}

fn has_uppercase(bits: BitArray) -> Bool {
  case bits {
    <<byte, _remaining:bits>> if byte >= uppercase_a && byte <= uppercase_z ->
      True
    <<_byte, remaining:bits>> -> has_uppercase(remaining)
    _bits -> False
  }
}

fn lowercase_bytes(bits: BitArray, lowered: BitArray) -> BitArray {
  case bits {
    <<byte, remaining:bits>> if byte >= uppercase_a && byte <= uppercase_z ->
      lowercase_bytes(remaining, <<lowered:bits, { byte + lowercase_offset }>>)
    <<byte, remaining:bits>> ->
      lowercase_bytes(remaining, <<lowered:bits, byte>>)
    _bits -> lowered
  }
}

/// Finds the first NUL, CR, or LF in a response header name or value.
/// Returns its offset in UTF-8 bytes, or `Error(Nil)` if none is present.
///
/// ```gleam
/// field.find_unsafe_byte("safe")     // Error(Nil)
/// field.find_unsafe_byte("é\rvalue") // Ok(2)
/// ```
///
pub fn find_unsafe_byte(value: String) -> Result(Int, Nil) {
  find_unsafe_byte_at(<<value:utf8>>, 0)
}

fn find_unsafe_byte_at(bits: BitArray, position: Int) -> Result(Int, Nil) {
  case bits {
    <<byte, _remaining:bits>>
      if byte == null_byte || byte == line_feed || byte == carriage_return
    -> Ok(position)
    <<_byte, remaining:bits>> -> find_unsafe_byte_at(remaining, position + 1)
    _bits -> Error(Nil)
  }
}

@external(erlang, "binary", "at")
fn byte_at(bits: BitArray, position: Int) -> Int

@external(erlang, "binary", "part")
fn binary_part(bits: BitArray, position: Int, size: Int) -> BitArray
