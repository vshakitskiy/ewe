import gleam/bit_array
import gleam/http
import gleam/option.{type Option, None, Some}

pub fn split_host_port(
  value: BitArray,
) -> Result(#(BitArray, Option(Int)), Nil) {
  case value {
    <<"[":utf8, _remaining:bits>> -> split_bracketed_host(value)
    _value ->
      case find_colon(value) {
        Error(Nil) -> Ok(#(value, None))
        Ok(position) -> {
          let size = bit_array.byte_size(value)
          let assert <<
            host:bytes-size(position),
            ":":utf8,
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
) -> Result(#(BitArray, Option(Int)), Nil) {
  case has_userinfo(authority), split_host_port(authority) {
    False, Ok(#(host, port)) if host != <<>> -> Ok(#(host, port))
    _userinfo, _split -> Error(Nil)
  }
}

fn split_bracketed_host(
  value: BitArray,
) -> Result(#(BitArray, Option(Int)), Nil) {
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
        <<":":utf8, port:bits>> ->
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

@external(erlang, "ewe_ffi", "find_colon")
fn find_colon(bits: BitArray) -> Result(Int, Nil)

@external(erlang, "ewe_ffi", "has_userinfo")
fn has_userinfo(authority: BitArray) -> Bool

@external(erlang, "ewe_ffi", "find_close_bracket")
fn find_close_bracket(bits: BitArray) -> Result(Int, Nil)
