import gleam/bit_array
import gleam/http
import gleam/option.{None, Some}

const colon = 58

const closing_bracket = 93

const question_mark = 63

pub fn split_host_port(
  value: BitArray,
) -> Result(#(BitArray, option.Option(Int)), Nil) {
  case value {
    <<"[", _remaining:bits>> -> split_bracketed_host(value)
    _value ->
      case find_colon(value) {
        Error(Nil) -> Ok(#(value, None))
        Ok(position) -> {
          let size = bit_array.byte_size(value)
          let assert <<
            host:bytes-size(position),
            ":",
            port:bytes-size(size - position - 1),
          >> = value

          case parse_port(port) {
            Ok(port) -> Ok(#(host, Some(port)))
            Error(Nil) -> Error(Nil)
          }
        }
      }
  }
}

pub fn parse_authority(
  authority: BitArray,
) -> Result(#(BitArray, option.Option(Int)), Nil) {
  case has_userinfo(authority), split_host_port(authority) {
    False, Ok(#(host, port)) if host != <<>> -> Ok(#(host, port))
    _userinfo, _split -> Error(Nil)
  }
}

fn split_bracketed_host(
  value: BitArray,
) -> Result(#(BitArray, option.Option(Int)), Nil) {
  case find_close_bracket(value) {
    Error(Nil) -> Error(Nil)
    Ok(position) -> {
      let size = bit_array.byte_size(value)
      let assert <<
        host:bytes-size(position + 1),
        remaining:bytes-size(size - position - 1),
      >> = value

      case remaining {
        <<>> -> Ok(#(host, None))
        <<":", port:bits>> ->
          case parse_port(port) {
            Ok(port) -> Ok(#(host, Some(port)))
            Error(Nil) -> Error(Nil)
          }
        _remaining -> Error(Nil)
      }
    }
  }
}

fn parse_port(bits: BitArray) -> Result(Int, Nil) {
  case parse_decimal(bits) {
    Ok(port) if port <= 65_535 -> Ok(port)
    Ok(_port) | Error(Nil) -> Error(Nil)
  }
}

pub fn parse_decimal(bits: BitArray) -> Result(Int, Nil) {
  case bits {
    <<byte, remaining:bits>> if byte >= 48 && byte <= 57 ->
      parse_decimal_digits(remaining, byte - 48)
    _bits -> Error(Nil)
  }
}

fn parse_decimal_digits(bits: BitArray, acc: Int) -> Result(Int, Nil) {
  case bits {
    <<byte, remaining:bits>> if byte >= 48 && byte <= 57 ->
      parse_decimal_digits(remaining, acc * 10 + { byte - 48 })
    <<>> -> Ok(acc)
    _bits -> Error(Nil)
  }
}

pub fn is_valid_path(method: http.Method, path: String) -> Bool {
  case path, method {
    "*", http.Options -> True
    "/" <> _remaining, _method -> True
    _path, _method -> False
  }
}

fn find_colon(bits: BitArray) -> Result(Int, Nil) {
  find_byte(bits, colon, 0)
}

fn find_close_bracket(bits: BitArray) -> Result(Int, Nil) {
  find_byte(bits, closing_bracket, 0)
}

fn find_byte(bits: BitArray, needle: Int, position: Int) -> Result(Int, Nil) {
  case bits {
    <<byte, _rest:bits>> if byte == needle -> Ok(position)
    <<_byte, rest:bits>> -> find_byte(rest, needle, position + 1)
    _bits -> Error(Nil)
  }
}

fn has_userinfo(bits: BitArray) -> Bool {
  case bits {
    <<"@", _rest:bits>> -> True
    <<_byte, rest:bits>> -> has_userinfo(rest)
    _bits -> False
  }
}

pub fn split_query(path: String) -> Result(#(String, String), Nil) {
  let bits = <<path:utf8>>

  case find_byte(bits, question_mark, 0) {
    Error(Nil) -> Error(Nil)
    Ok(position) ->
      case bits {
        <<before:bytes-size(position), "?", after:bits>> ->
          Ok(#(unsafe_to_string(before), unsafe_to_string(after)))
        _bits -> Error(Nil)
      }
  }
}

@external(erlang, "ewe_ffi", "identity")
fn unsafe_to_string(bits: BitArray) -> String
