import ewe/internal/http2/parser.{DecodedRequest}
import gleam/http
import gleam/http/request.{Request}
import gleam/list
import gleam/option.{None, Some}
import gleam/result

fn fields(fields: List(#(String, String))) -> List(#(BitArray, BitArray)) {
  list.map(fields, fn(field) { #(<<field.0:utf8>>, <<field.1:utf8>>) })
}

fn build(
  list: List(#(String, String)),
) -> Result(parser.DecodedRequest, parser.Malformed) {
  parser.request(fields(list), http.Https, True)
}

fn get(path: String) -> List(#(String, String)) {
  [
    #(":method", "GET"),
    #(":scheme", "https"),
    #(":authority", "example.com"),
    #(":path", path),
  ]
}

pub fn request_test() {
  assert build(list.append(get("/a/b?x=1"), [#("accept", "*/*")]))
    == Ok(DecodedRequest(
      request: Request(
        method: http.Get,
        headers: [#("accept", "*/*")],
        body: Nil,
        scheme: http.Https,
        host: "example.com",
        port: None,
        path: "/a/b",
        query: Some("x=1"),
      ),
      content_length: None,
      protocol: None,
    ))
}

pub fn ipv6_authority_test() {
  let assert Ok(DecodedRequest(request:, ..)) =
    build([
      #(":method", "GET"),
      #(":scheme", "https"),
      #(":authority", "[2001:db8::1]:8443"),
      #(":path", "/"),
    ])
  assert request.host == "[2001:db8::1]"
  assert request.port == Some(8443)
}

pub fn host_field_without_authority_test() {
  let assert Ok(DecodedRequest(request:, ..)) =
    build([
      #(":method", "GET"),
      #(":scheme", "https"),
      #(":path", "/"),
      #("host", "example.com"),
    ])
  assert request.host == "example.com"
}

pub fn host_and_authority_must_agree_test() {
  assert build(list.append(get("/"), [#("host", "EXAMPLE.com:443")]))
    |> result.is_ok
  assert build(list.append(get("/"), [#("host", "example.com:80")]))
    == Error(parser.InvalidAuthority)
}

pub fn duplicate_host_is_malformed_test() {
  assert build([
      #(":method", "GET"),
      #(":scheme", "https"),
      #(":path", "/"),
      #("host", "example.com"),
      #("host", "other.com"),
    ])
    == Error(parser.InvalidAuthority)
}

pub fn missing_authority_and_host_is_malformed_test() {
  assert build([#(":method", "GET"), #(":scheme", "https"), #(":path", "/")])
    == Error(parser.InvalidAuthority)
}

pub fn userinfo_is_malformed_test() {
  assert build([
      #(":method", "GET"),
      #(":scheme", "https"),
      #(":authority", "user:pass@example.com"),
      #(":path", "/"),
    ])
    == Error(parser.InvalidAuthority)
}

pub fn bad_port_is_malformed_test() {
  assert build([
      #(":method", "GET"),
      #(":scheme", "https"),
      #(":authority", "example.com:99999"),
      #(":path", "/"),
    ])
    == Error(parser.InvalidAuthority)
}

pub fn path_must_be_origin_form_test() {
  assert build(get("relative")) == Error(parser.InvalidPath)
  assert build(get("*")) == Error(parser.InvalidPath)
}

pub fn asterisk_path_for_options_test() {
  let assert Ok(DecodedRequest(request:, ..)) =
    build([
      #(":method", "OPTIONS"),
      #(":scheme", "https"),
      #(":authority", "example.com"),
      #(":path", "*"),
    ])
  assert request.path == "*"
}

pub fn empty_path_is_malformed_test() {
  assert build(get("")) == Error(parser.MissingPseudoHeader)
}

pub fn unsupported_scheme_is_malformed_test() {
  assert build([
      #(":method", "GET"),
      #(":scheme", "ftp"),
      #(":authority", "example.com"),
      #(":path", "/"),
    ])
    == Error(parser.UnsupportedScheme)
}

pub fn method_that_is_not_a_token_is_malformed_test() {
  assert build([
      #(":method", "GE T"),
      #(":scheme", "https"),
      #(":authority", "example.com"),
      #(":path", "/"),
    ])
    == Error(parser.InvalidMethod)
}

pub fn pseudo_header_after_regular_is_malformed_test() {
  assert build([#("accept", "*/*"), ..get("/")])
    == Error(parser.PseudoHeaderAfterRegular)
}

pub fn duplicate_pseudo_header_is_malformed_test() {
  assert build([#(":method", "GET"), ..get("/")])
    == Error(parser.DuplicatePseudoHeader)
}

pub fn unknown_pseudo_header_is_malformed_test() {
  assert build([#(":status", "200"), ..get("/")])
    == Error(parser.UnknownPseudoHeader)
}

pub fn field_name_rules_test() {
  assert build(list.append(get("/"), [#("Upper", "v")]))
    == Error(parser.InvalidFieldName)
  assert build(list.append(get("/"), [#("with space", "v")]))
    == Error(parser.InvalidFieldName)
  assert build(list.append(get("/"), [#("colon:name", "v")]))
    == Error(parser.InvalidFieldName)
  assert build(list.append(get("/"), [#("", "v")]))
    == Error(parser.InvalidFieldName)
  assert build(list.append(get("/"), [#("déjà", "v")]))
    == Error(parser.InvalidFieldName)
}

pub fn field_value_rules_test() {
  assert build(list.append(get("/"), [#("x", "a\r\nb")]))
    == Error(parser.InvalidFieldValue)
  assert build(list.append(get("/"), [#("x", "a\u{0}b")]))
    == Error(parser.InvalidFieldValue)
  assert build(list.append(get("/"), [#("x", " a")]))
    == Error(parser.InvalidFieldValue)
  assert build(list.append(get("/"), [#("x", "a\t")]))
    == Error(parser.InvalidFieldValue)
  assert build(list.append(get("/"), [#("x", "inner space")]))
    |> result.is_ok
  assert build(list.append(get("/"), [#("x", "")]))
    |> result.is_ok
}

pub fn invalid_utf8_value_is_malformed_test() {
  assert parser.request(
      list.append(fields(get("/")), [#(<<"x":utf8>>, <<0xff>>)]),
      http.Https,
      True,
    )
    == Error(parser.InvalidFieldValue)
}

pub fn connection_specific_fields_are_malformed_test() {
  list.each(
    [
      "connection",
      "keep-alive",
      "proxy-connection",
      "transfer-encoding",
      "upgrade",
    ],
    fn(name) {
      assert build(list.append(get("/"), [#(name, "x")]))
        == Error(parser.ConnectionSpecificField)
    },
  )
}

pub fn te_is_only_trailers_test() {
  assert build(list.append(get("/"), [#("te", "trailers")])) |> result.is_ok
  assert build(list.append(get("/"), [#("te", "gzip")]))
    == Error(parser.ConnectionSpecificField)
}

pub fn cookies_are_joined_test() {
  let assert Ok(DecodedRequest(request:, ..)) =
    build(
      list.append(get("/"), [
        #("cookie", "a=1"),
        #("accept", "*/*"),
        #("cookie", "b=2"),
      ]),
    )
  assert request.headers == [#("accept", "*/*"), #("cookie", "a=1; b=2")]
}

pub fn repeated_fields_are_kept_in_order_test() {
  let assert Ok(DecodedRequest(request:, ..)) =
    build(list.append(get("/"), [#("x", "1"), #("y", "2"), #("x", "3")]))
  assert request.headers == [#("x", "1"), #("y", "2"), #("x", "3")]
}

pub fn content_length_test() {
  let assert Ok(DecodedRequest(content_length:, ..)) =
    build(list.append(get("/"), [#("content-length", "42")]))
  assert content_length == Some(42)
  assert build(list.append(get("/"), [#("content-length", "-1")]))
    == Error(parser.InvalidContentLength)
  assert build(list.append(get("/"), [#("content-length", "+1")]))
    == Error(parser.InvalidContentLength)
  assert build(
      list.append(get("/"), [#("content-length", "1"), #("content-length", "1")]),
    )
    == Error(parser.InvalidContentLength)
}

pub fn connect_test() {
  let assert Ok(DecodedRequest(request:, ..)) =
    build([#(":method", "CONNECT"), #(":authority", "example.com:443")])
  assert request.method == http.Connect
  assert request.host == "example.com"
  assert request.port == Some(443)
  assert request.path == ""
}

pub fn connect_needs_a_port_test() {
  assert build([#(":method", "CONNECT"), #(":authority", "example.com")])
    == Error(parser.InvalidAuthority)
}

pub fn connect_must_omit_scheme_and_path_test() {
  assert build([
      #(":method", "CONNECT"),
      #(":scheme", "https"),
      #(":authority", "example.com:443"),
    ])
    == Error(parser.UnexpectedPseudoHeader)
}

pub fn connect_has_no_content_test() {
  assert build([
      #(":method", "CONNECT"),
      #(":authority", "example.com:443"),
      #("content-length", "0"),
    ])
    == Error(parser.ContentOnConnect)
}

pub fn extended_connect_test() {
  let assert Ok(DecodedRequest(request:, protocol:, ..)) =
    build([
      #(":method", "CONNECT"),
      #(":protocol", "websocket"),
      #(":scheme", "https"),
      #(":authority", "example.com"),
      #(":path", "/chat"),
    ])
  assert protocol == Some("websocket")
  assert request.path == "/chat"
}

pub fn extended_connect_needs_scheme_and_path_test() {
  assert build([
      #(":method", "CONNECT"),
      #(":protocol", "websocket"),
      #(":authority", "example.com"),
    ])
    == Error(parser.MissingPseudoHeader)
}

pub fn protocol_needs_connect_test() {
  assert build([#(":protocol", "websocket"), ..get("/")])
    == Error(parser.UnexpectedProtocol)
}

pub fn protocol_needs_the_setting_test() {
  assert parser.request(
      fields([
        #(":method", "CONNECT"),
        #(":protocol", "websocket"),
        #(":scheme", "https"),
        #(":authority", "example.com"),
        #(":path", "/chat"),
      ]),
      http.Https,
      False,
    )
    == Error(parser.UnexpectedProtocol)
}

pub fn trailers_test() {
  assert parser.trailers(fields([#("x-checksum", "abc")]))
    == Ok([#("x-checksum", "abc")])
}

pub fn trailers_with_pseudo_header_are_malformed_test() {
  assert parser.trailers(fields([#(":path", "/")]))
    == Error(parser.UnknownPseudoHeader)
}
