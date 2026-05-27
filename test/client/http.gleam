import gleam/bit_array
import gleam/http/response.{type Response, Response}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type ParseError {
  InvalidStatus
  InvalidHeaders
  MalformedResponse
}

pub fn parse(data: BitArray) -> Result(Response(String), ParseError) {
  case bit_array.to_string(data) {
    Ok(data) ->
      case string.split_once(data, "\r\n\r\n") {
        Ok(#(lines, body)) -> do_parse(lines, body)
        Error(Nil) -> do_parse(data, "")
      }

    Error(Nil) -> Error(MalformedResponse)
  }
}

fn do_parse(
  lines: String,
  body: String,
) -> Result(Response(String), ParseError) {
  case string.split(lines, "\r\n") {
    [status, ..headers] -> {
      use status <- result.try(parse_status(status))
      use headers <- result.try(parse_headers(headers, []))

      Ok(Response(status:, headers:, body:))
    }
    _ -> Error(MalformedResponse)
  }
}

fn parse_status(status: String) -> Result(Int, ParseError) {
  case string.split(status, " ") {
    [_version, status, ..] ->
      int.parse(status)
      |> result.replace_error(InvalidStatus)
    _ -> Error(InvalidStatus)
  }
}

fn parse_headers(
  headers: List(String),
  acc: List(#(String, String)),
) -> Result(List(#(String, String)), ParseError) {
  case headers {
    [] -> Ok(list.reverse(acc))
    [header, ..remaining] -> {
      case string.split_once(header, ": "), string.split_once(header, ":") {
        Ok(#(name, value)), _ ->
          parse_headers(remaining, [#(string.lowercase(name), value), ..acc])
        Error(Nil), Ok(#(name, value)) ->
          [#(string.lowercase(name), string.trim(value)), ..acc]
          |> parse_headers(remaining, _)
        Error(Nil), Error(Nil) -> Error(InvalidHeaders)
      }
    }
  }
}
