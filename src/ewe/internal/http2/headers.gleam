//// Turns the header fields HPACK decodes for a stream into a `Request` and a
//// handler's response headers back into fields to encode.

import alpacki
import gleam/dict.{type Dict}
import gleam/http
import gleam/http/request.{type Request, Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

type Pattern

pub opaque type HeaderPatterns {
  HeaderPatterns(
    name: Pattern,
    forbidden: Pattern,
    query: Pattern,
    colon: Pattern,
  )
}

@external(erlang, "ewe_http2_ffi", "name_pattern")
fn name_pattern() -> Pattern

@external(erlang, "ewe_http2_ffi", "forbidden_header_pattern")
fn forbidden_header_pattern() -> Pattern

@external(erlang, "ewe_http2_ffi", "query_pattern")
fn query_pattern() -> Pattern

@external(erlang, "ewe_http2_ffi", "colon_pattern")
fn colon_pattern() -> Pattern

@internal
pub fn header_patterns() -> HeaderPatterns {
  HeaderPatterns(
    name: name_pattern(),
    forbidden: forbidden_header_pattern(),
    query: query_pattern(),
    colon: colon_pattern(),
  )
}

@internal
pub type RequestError {
  InvalidUtf8
  EmptyHeaderName
  UppercaseHeaderName
  MalformedHeaderBytes
  PseudoHeaderAfterRegular
  UnknownPseudoHeader
  MissingPseudoHeader
  DuplicatePseudoHeader
  ConnectionSpecificHeader
  InvalidMethod
  InvalidScheme
  InvalidAuthority
  InvalidPath
  InvalidContentLength
  InvalidProtocol
  ProtocolWithoutConnect
  ProtocolWithContentLength
}

fn validate_protocol(
  method: http.Method,
  protocol: Option(String),
  content_length: Option(Int),
) -> Result(Nil, RequestError) {
  case protocol, method, content_length {
    None, _method, _length -> Ok(Nil)
    Some(_protocol), http.Connect, None -> Ok(Nil)
    Some(_protocol), http.Connect, Some(_length) ->
      Error(ProtocolWithContentLength)
    Some(_protocol), _method, _length -> Error(ProtocolWithoutConnect)
  }
}

type PseudoHeaders {
  PseudoHeaders(
    method: Option(http.Method),
    scheme: Option(http.Scheme),
    authority: Option(String),
    path: Option(String),
    protocol: Option(String),
  )
}

@internal
pub type DecodedRequest(body) {
  DecodedRequest(
    request: Request(body),
    content_length: Option(Int),
    protocol: Option(String),
  )
}

type HeaderAccumulated {
  HeaderAccumulated(
    pseudo: PseudoHeaders,
    regular: Dict(String, String),
    seen_regular: Bool,
    content_length: Option(Int),
  )
}

fn new_accumulator() -> HeaderAccumulated {
  HeaderAccumulated(
    pseudo: PseudoHeaders(
      method: None,
      scheme: None,
      authority: None,
      path: None,
      protocol: None,
    ),
    regular: dict.new(),
    seen_regular: False,
    content_length: None,
  )
}

@internal
pub fn build_request(
  headers: List(#(BitArray, BitArray)),
  body: body,
  patterns: HeaderPatterns,
) -> Result(DecodedRequest(body), RequestError) {
  use acc <- result.try(
    list.try_fold(headers, new_accumulator(), fn(acc, header) {
      add_header(patterns, acc, header)
    }),
  )

  case
    acc.pseudo.method,
    acc.pseudo.scheme,
    acc.pseudo.authority,
    acc.pseudo.path
  {
    Some(method), Some(scheme), Some(authority), Some(path) -> {
      use Nil <- result.try(validate_protocol(
        method,
        acc.pseudo.protocol,
        acc.content_length,
      ))
      use #(host, port) <- result.try(split_authority(patterns, authority))
      let #(path, query) = case split_once(path, patterns.query) {
        Ok(#(path, query)) -> #(path, Some(query))
        Error(Nil) -> #(path, None)
      }

      Ok(DecodedRequest(
        request: Request(
          method:,
          headers: dict.to_list(acc.regular),
          body:,
          scheme:,
          host:,
          port:,
          path:,
          query:,
        ),
        content_length: acc.content_length,
        protocol: acc.pseudo.protocol,
      ))
    }
    _method, _scheme, _authority, _path -> Error(MissingPseudoHeader)
  }
}

fn add_header(
  patterns: HeaderPatterns,
  acc: HeaderAccumulated,
  header: #(BitArray, BitArray),
) -> Result(HeaderAccumulated, RequestError) {
  let #(name, value) = header

  case name {
    <<>> -> Error(EmptyHeaderName)
    <<":method":utf8>> -> {
      use <- once(acc, acc.pseudo.method)
      use method <- result.map(parse_method(patterns, value))
      set_pseudo(acc, PseudoHeaders(..acc.pseudo, method: Some(method)))
    }
    <<":scheme":utf8>> -> {
      use <- once(acc, acc.pseudo.scheme)
      use scheme <- result.map(parse_scheme(value))
      set_pseudo(acc, PseudoHeaders(..acc.pseudo, scheme: Some(scheme)))
    }
    <<":authority":utf8>> -> {
      use <- once(acc, acc.pseudo.authority)
      use authority <- result.map(validate_header_value(
        patterns.forbidden,
        value,
      ))
      set_pseudo(acc, PseudoHeaders(..acc.pseudo, authority: Some(authority)))
    }
    <<":path":utf8>> -> {
      use <- once(acc, acc.pseudo.path)
      use path <- result.try(validate_header_value(patterns.forbidden, value))
      use path <- result.map(non_empty(path, InvalidPath))
      set_pseudo(acc, PseudoHeaders(..acc.pseudo, path: Some(path)))
    }
    <<":protocol":utf8>> -> {
      use <- once(acc, acc.pseudo.protocol)
      use protocol <- result.try(validate_header_value(
        patterns.forbidden,
        value,
      ))
      use protocol <- result.map(non_empty(protocol, InvalidProtocol))
      set_pseudo(acc, PseudoHeaders(..acc.pseudo, protocol: Some(protocol)))
    }
    <<58, _rest:bits>> ->
      case acc.seen_regular {
        True -> Error(PseudoHeaderAfterRegular)
        False -> Error(UnknownPseudoHeader)
      }
    <<"connection":utf8>>
    | <<"keep-alive":utf8>>
    | <<"proxy-connection":utf8>>
    | <<"transfer-encoding":utf8>>
    | <<"upgrade":utf8>> -> Error(ConnectionSpecificHeader)
    <<"content-length":utf8>> -> {
      case acc.content_length {
        Some(_prior) -> Error(InvalidContentLength)
        None -> {
          use value <- result.try(validate_header_value(
            patterns.forbidden,
            value,
          ))

          case int.parse(value) {
            Ok(n) if n >= 0 -> {
              let regular = dict.insert(acc.regular, "content-length", value)

              HeaderAccumulated(
                ..acc,
                regular:,
                seen_regular: True,
                content_length: Some(n),
              )
              |> Ok
            }
            _value -> Error(InvalidContentLength)
          }
        }
      }
    }
    <<"te":utf8>> ->
      case value {
        <<"trailers":utf8>> -> {
          let regular = dict.insert(acc.regular, "te", "trailers")
          Ok(HeaderAccumulated(..acc, regular:))
        }
        _name -> Error(ConnectionSpecificHeader)
      }
    _name -> add_regular(patterns, acc, name, value)
  }
}

fn once(
  acc: HeaderAccumulated,
  seen: Option(a),
  parse: fn() -> Result(HeaderAccumulated, RequestError),
) -> Result(HeaderAccumulated, RequestError) {
  case acc.seen_regular, seen {
    True, _seen -> Error(PseudoHeaderAfterRegular)
    False, Some(_seen) -> Error(DuplicatePseudoHeader)
    False, None -> parse()
  }
}

fn set_pseudo(
  acc: HeaderAccumulated,
  pseudo: PseudoHeaders,
) -> HeaderAccumulated {
  HeaderAccumulated(..acc, pseudo:)
}

fn non_empty(
  value: String,
  error: RequestError,
) -> Result(String, RequestError) {
  case value {
    "" -> Error(error)
    _value -> Ok(value)
  }
}

fn parse_method(
  patterns: HeaderPatterns,
  value: BitArray,
) -> Result(http.Method, RequestError) {
  case value {
    <<"GET":utf8>> -> Ok(http.Get)
    <<"POST":utf8>> -> Ok(http.Post)
    <<"PUT":utf8>> -> Ok(http.Put)
    <<"DELETE":utf8>> -> Ok(http.Delete)
    <<"HEAD":utf8>> -> Ok(http.Head)
    <<"OPTIONS":utf8>> -> Ok(http.Options)
    <<"PATCH":utf8>> -> Ok(http.Patch)
    <<"CONNECT":utf8>> -> Ok(http.Connect)
    <<"TRACE":utf8>> -> Ok(http.Trace)
    _method -> {
      use method <- result.try(validate_header_value(patterns.forbidden, value))
      http.parse_method(method) |> result.replace_error(InvalidMethod)
    }
  }
}

fn parse_scheme(value: BitArray) -> Result(http.Scheme, RequestError) {
  case value {
    <<"https":utf8>> -> Ok(http.Https)
    <<"http":utf8>> -> Ok(http.Http)
    _scheme -> Error(InvalidScheme)
  }
}

@external(erlang, "ewe_http2_ffi", "validate_header_name")
fn validate_header_name(
  pattern: Pattern,
  name: BitArray,
) -> Result(String, RequestError)

@external(erlang, "ewe_http2_ffi", "validate_header_value")
fn validate_header_value(
  pattern: Pattern,
  value: BitArray,
) -> Result(String, RequestError)

fn add_regular(
  patterns: HeaderPatterns,
  acc: HeaderAccumulated,
  name: BitArray,
  value: BitArray,
) -> Result(HeaderAccumulated, RequestError) {
  use name <- result.try(validate_header_name(patterns.name, name))
  use value <- result.try(validate_header_value(patterns.forbidden, value))

  let separator = case name {
    "cookie" -> "; "
    _existing -> ", "
  }

  let regular =
    dict_upsert(
      name,
      fn(prior) { prior <> separator <> value },
      value,
      acc.regular,
    )

  Ok(HeaderAccumulated(..acc, regular:, seen_regular: True))
}

@external(erlang, "maps", "update_with")
fn dict_upsert(
  key: String,
  with: fn(String) -> String,
  init: String,
  map: Dict(String, String),
) -> Dict(String, String)

fn split_authority(
  patterns: HeaderPatterns,
  authority: String,
) -> Result(#(String, Option(Int)), RequestError) {
  case split_once(authority, patterns.colon) {
    Ok(#(host, port_str)) ->
      case int.parse(port_str) {
        Ok(port) -> Ok(#(host, Some(port)))
        Error(Nil) -> Error(InvalidAuthority)
      }
    Error(Nil) -> Ok(#(authority, None))
  }
}

@external(erlang, "ewe_http2_ffi", "split_once")
fn split_once(
  string: String,
  on pattern: Pattern,
) -> Result(#(String, String), Nil)

pub fn is_pseudo_header(header: #(BitArray, BitArray)) -> Bool {
  case header.0 {
    <<":":utf8, _rest:bits>> -> True
    _name -> False
  }
}

pub fn decode_trailers(
  patterns: HeaderPatterns,
  headers: List(#(BitArray, BitArray)),
) -> Result(List(#(String, String)), RequestError) {
  use acc <- result.map(
    list.try_fold(headers, new_accumulator(), fn(acc, header) {
      let #(name, value) = header
      add_regular(patterns, acc, name, value)
    }),
  )

  dict.to_list(acc.regular)
}

pub fn build_response_headers(
  headers: List(#(String, String)),
  patterns: HeaderPatterns,
) -> List(alpacki.HeaderField) {
  list.fold(headers, [], fn(fields, header) {
    let #(name, value) = header
    case name {
      "connection"
      | "keep-alive"
      | "proxy-connection"
      | "transfer-encoding"
      | "upgrade"
      | "date"
      | "content-length"
      | "" -> fields
      _name ->
        case
          has_forbidden_header_bytes(patterns.forbidden, name)
          || has_forbidden_header_bytes(patterns.forbidden, value)
        {
          True -> fields
          False -> [
            alpacki.HeaderField(
              <<name:utf8>>,
              <<value:utf8>>,
              alpacki.WithoutIndexing,
            ),
            ..fields
          ]
        }
    }
  })
}

@external(erlang, "ewe_http2_ffi", "has_forbidden_header_bytes")
fn has_forbidden_header_bytes(pattern: Pattern, value: String) -> Bool
