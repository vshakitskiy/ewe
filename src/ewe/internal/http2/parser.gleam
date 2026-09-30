import ewe/internal/target
import gleam/http
import gleam/http/request.{Request}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub type Malformed {
  InvalidFieldName
  InvalidFieldValue
  PseudoHeaderAfterRegular
  UnknownPseudoHeader
  DuplicatePseudoHeader
  MissingPseudoHeader
  UnexpectedPseudoHeader
  ConnectionSpecificField
  InvalidMethod
  UnsupportedScheme
  InvalidAuthority
  InvalidPath
  InvalidContentLength
  UnexpectedProtocol
  ContentOnConnect
}

pub type DecodedRequest {
  DecodedRequest(
    request: request.Request(Nil),
    content_length: option.Option(Int),
    protocol: option.Option(String),
  )
}

type Section {
  Section(
    method: option.Option(BitArray),
    scheme: option.Option(BitArray),
    authority: option.Option(BitArray),
    path: option.Option(BitArray),
    protocol: option.Option(BitArray),
    seen_regular: Bool,
    headers: List(#(String, String)),
    cookies: List(String),
    host: option.Option(String),
    content_length: option.Option(Int),
  )
}

pub fn request(
  fields: List(#(BitArray, BitArray)),
  scheme: http.Scheme,
  extended_connect: Bool,
) -> Result(DecodedRequest, Malformed) {
  use section <- result.try(list.try_fold(fields, empty_section(), add_field))
  use method <- result.try(required(section.method))
  use method <- result.try(parse_method(method))
  let protocol = option.map(section.protocol, unsafe_to_string)

  case method, protocol {
    http.Connect, None -> {
      use Nil <- result.try(case section.scheme, section.path {
        None, None -> Ok(Nil)
        _scheme, _path -> Error(UnexpectedPseudoHeader)
      })
      use authority <- result.try(required(section.authority))
      use #(host, port) <- result.try(parse_authority(authority))
      use Nil <- result.try(no_content_length(section.content_length))

      case port {
        None -> Error(InvalidAuthority)
        Some(_port) ->
          Request(
            method:,
            headers: headers(section),
            body: Nil,
            scheme:,
            host:,
            port:,
            path: "",
            query: None,
          )
          |> DecodedRequest(content_length: None, protocol: None)
          |> Ok
      }
    }
    http.Connect, Some(_protocol) if extended_connect -> {
      use Nil <- result.try(no_content_length(section.content_length))
      use request <- result.map(target_request(section, method))
      DecodedRequest(request:, content_length: None, protocol:)
    }
    _method, Some(_protocol) -> Error(UnexpectedProtocol)
    _method, None -> {
      use request <- result.map(target_request(section, method))
      DecodedRequest(
        request:,
        content_length: section.content_length,
        protocol:,
      )
    }
  }
}

fn empty_section() -> Section {
  Section(
    method: None,
    scheme: None,
    authority: None,
    path: None,
    protocol: None,
    seen_regular: False,
    headers: [],
    cookies: [],
    host: None,
    content_length: None,
  )
}

fn target_request(
  section: Section,
  method: http.Method,
) -> Result(request.Request(Nil), Malformed) {
  use scheme <- result.try(required(section.scheme))
  use scheme <- result.try(case scheme {
    <<"https":utf8>> -> Ok(http.Https)
    <<"http":utf8>> -> Ok(http.Http)
    _scheme -> Error(UnsupportedScheme)
  })
  use path <- result.try(required(section.path))
  let #(path, query) = case split_query(unsafe_to_string(path)) {
    Ok(#(path, query)) -> #(path, Some(query))
    Error(Nil) -> #(unsafe_to_string(path), None)
  }
  use Nil <- result.try(case target.is_valid_path(method, path) {
    True -> Ok(Nil)
    False -> Error(InvalidPath)
  })
  use #(host, port) <- result.map(resolve_authority(section, scheme))

  Request(
    method:,
    headers: headers(section),
    body: Nil,
    scheme:,
    host:,
    port:,
    path:,
    query:,
  )
}

fn resolve_authority(
  section: Section,
  scheme: http.Scheme,
) -> Result(#(String, option.Option(Int)), Malformed) {
  case section.authority, section.host {
    Some(authority), None -> parse_authority(authority)
    None, Some(host) -> parse_authority(<<host:utf8>>)
    Some(authority), Some(host_header) -> {
      use #(host, port) <- result.try(parse_authority(authority))
      use #(header_host, header_port) <- result.try(
        parse_authority(<<host_header:utf8>>),
      )
      let default_port = default_port(scheme)

      case
        string.lowercase(host) == string.lowercase(header_host)
        && option.unwrap(port, default_port)
        == option.unwrap(header_port, default_port)
      {
        True -> Ok(#(host, port))
        False -> Error(InvalidAuthority)
      }
    }
    None, None -> Error(InvalidAuthority)
  }
}

fn default_port(scheme: http.Scheme) -> Int {
  case scheme {
    http.Https -> 443
    http.Http -> 80
  }
}

fn parse_authority(
  authority: BitArray,
) -> Result(#(String, option.Option(Int)), Malformed) {
  case target.parse_authority(authority) {
    Ok(#(host, port)) -> Ok(#(unsafe_to_string(host), port))
    Error(Nil) -> Error(InvalidAuthority)
  }
}

fn no_content_length(
  content_length: option.Option(Int),
) -> Result(Nil, Malformed) {
  case content_length {
    None -> Ok(Nil)
    Some(_length) -> Error(ContentOnConnect)
  }
}

fn required(value: option.Option(a)) -> Result(a, Malformed) {
  option.to_result(value, MissingPseudoHeader)
}

fn headers(section: Section) -> List(#(String, String)) {
  case section.cookies {
    [] -> list.reverse(section.headers)
    cookies ->
      list.reverse([
        #("cookie", string.join(list.reverse(cookies), "; ")),
        ..section.headers
      ])
  }
}

fn add_field(
  section: Section,
  field: #(BitArray, BitArray),
) -> Result(Section, Malformed) {
  let #(name, value) = field

  case name {
    <<":":utf8, _pseudo:bits>> -> add_pseudo(section, name, value)
    _regular -> add_regular(section, name, value)
  }
}

fn add_pseudo(
  section: Section,
  name: BitArray,
  value: BitArray,
) -> Result(Section, Malformed) {
  case section.seen_regular, name {
    True, _name -> Error(PseudoHeaderAfterRegular)
    False, <<":method":utf8>> -> {
      use method <- once(section.method, value, False)
      Ok(Section(..section, method:))
    }
    False, <<":scheme":utf8>> -> {
      use scheme <- once(section.scheme, value, False)
      Ok(Section(..section, scheme:))
    }
    False, <<":authority":utf8>> -> {
      use authority <- once(section.authority, value, True)
      Ok(Section(..section, authority:))
    }
    False, <<":path":utf8>> -> {
      use path <- once(section.path, value, True)
      Ok(Section(..section, path:))
    }
    False, <<":protocol":utf8>> -> {
      use protocol <- once(section.protocol, value, True)
      Ok(Section(..section, protocol:))
    }
    False, _unknown -> Error(UnknownPseudoHeader)
  }
}

fn once(
  current: option.Option(BitArray),
  value: BitArray,
  validate: Bool,
  set: fn(option.Option(BitArray)) -> Result(Section, Malformed),
) -> Result(Section, Malformed) {
  case current, value {
    Some(_current), _value -> Error(DuplicatePseudoHeader)
    None, <<>> -> Error(MissingPseudoHeader)
    None, _value ->
      case !validate || is_field_value(value) {
        True -> set(Some(value))
        False -> Error(InvalidFieldValue)
      }
  }
}

fn add_regular(
  section: Section,
  name: BitArray,
  value: BitArray,
) -> Result(Section, Malformed) {
  use #(name, value) <- result.try(validate_field(name, value))
  let section = Section(..section, seen_regular: True)

  case name {
    "connection"
    | "keep-alive"
    | "proxy-connection"
    | "transfer-encoding"
    | "upgrade" -> Error(ConnectionSpecificField)
    "te" if value != "trailers" -> Error(ConnectionSpecificField)
    "cookie" -> Ok(Section(..section, cookies: [value, ..section.cookies]))
    "content-length" ->
      case section.content_length, target.parse_decimal(<<value:utf8>>) {
        None, Ok(length) ->
          Section(..section, content_length: Some(length))
          |> push_header(name, value)
          |> Ok
        _duplicate, _parsed -> Error(InvalidContentLength)
      }
    "host" ->
      case section.host {
        None ->
          Ok(push_header(Section(..section, host: Some(value)), name, value))
        Some(_host) -> Error(InvalidAuthority)
      }
    _name -> Ok(push_header(section, name, value))
  }
}

fn push_header(section: Section, name: String, value: String) -> Section {
  Section(..section, headers: [#(name, value), ..section.headers])
}

pub fn trailers(
  fields: List(#(BitArray, BitArray)),
) -> Result(List(#(String, String)), Malformed) {
  use section <- result.map(
    list.try_fold(fields, empty_section(), fn(section, field) {
      case field {
        #(<<":":utf8, _pseudo:bits>>, _value) -> Error(UnknownPseudoHeader)
        #(name, value) -> add_regular(section, name, value)
      }
    }),
  )

  headers(section)
}

fn validate_field(
  name: BitArray,
  value: BitArray,
) -> Result(#(String, String), Malformed) {
  case is_field_name(name), is_field_value(value) {
    True, True -> Ok(#(unsafe_to_string(name), unsafe_to_string(value)))
    False, _value -> Error(InvalidFieldName)
    True, False -> Error(InvalidFieldValue)
  }
}

fn parse_method(value: BitArray) -> Result(http.Method, Malformed) {
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
    _method ->
      unsafe_to_string(value)
      |> http.parse_method
      |> result.replace_error(InvalidMethod)
  }
}

@external(erlang, "ewe_ffi", "split_query")
fn split_query(path: String) -> Result(#(String, String), Nil)

@external(erlang, "ewe_ffi", "identity")
fn unsafe_to_string(bytes: BitArray) -> String

@external(erlang, "ewe_ffi", "is_field_name")
fn is_field_name(name: BitArray) -> Bool

@external(erlang, "ewe_ffi", "is_field_value")
fn is_field_value(value: BitArray) -> Bool
