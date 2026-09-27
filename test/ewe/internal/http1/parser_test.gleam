import ewe/internal/http1/connection as http1
import ewe/internal/http1/parser
import gleam/http
import gleam/option.{None, Some}

fn parse(buffer: BitArray) -> Result(parser.Parsed, parser.ParseError) {
  parser.parse(buffer, http1.default_options())
}

pub fn simple_get_test() {
  let buffer = <<
    "GET /foo?a=1 HTTP/1.1\r\nHost: example.com\r\nConnection: keep-alive\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(head, metadata, remaining)) = parse(buffer)

  assert head.method == http.Get
  assert head.host == "example.com"
  assert head.port == None
  assert head.path == "/foo"
  assert head.query == Some("a=1")
  assert head.version == parser.Http11
  assert head.headers
    == [#("host", "example.com"), #("connection", "keep-alive")]
  assert metadata.keep_alive == http1.KeepAlive
  assert metadata.framing == http1.NoBody
  assert remaining == <<>>
}

pub fn host_ipv6_with_port_test() {
  let buffer = <<"GET / HTTP/1.1\r\nHost: [::1]:8080\r\n\r\n":utf8>>
  let assert Ok(parser.Complete(head, _metadata, _remaining)) = parse(buffer)

  assert head.host == "[::1]"
  assert head.port == Some(8080)
}

pub fn missing_host_on_http11_rejected_test() {
  let buffer = <<"GET / HTTP/1.1\r\n\r\n":utf8>>
  assert parse(buffer) == Error(parser.MissingHost)
}

pub fn missing_host_on_http10_allowed_test() {
  let buffer = <<"GET / HTTP/1.0\r\n\r\n":utf8>>
  let assert Ok(parser.Complete(head, _metadata, _remaining)) = parse(buffer)

  assert head.host == ""
  assert head.port == None
}

pub fn duplicate_host_rejected_test() {
  let buffer = <<"GET / HTTP/1.1\r\nHost: a.com\r\nHost: b.com\r\n\r\n":utf8>>
  assert parse(buffer) == Error(parser.DuplicateHost)
}

pub fn relative_path_rejected_test() {
  let buffer = <<"GET foo HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8>>
  assert parse(buffer) == Error(parser.BadTarget)
}

pub fn asterisk_form_allowed_for_options_test() {
  let buffer = <<"OPTIONS * HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8>>
  let assert Ok(parser.Complete(head, _metadata, _remaining)) = parse(buffer)

  assert head.path == "*"
}

pub fn asterisk_form_rejected_for_get_test() {
  let buffer = <<"GET * HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8>>
  assert parse(buffer) == Error(parser.BadTarget)
}

pub fn connect_authority_form_test() {
  let buffer = <<"CONNECT example.com:443 HTTP/1.1\r\n\r\n":utf8>>
  let assert Ok(parser.Complete(head, _metadata, _remaining)) = parse(buffer)

  assert head.host == "example.com"
  assert head.port == Some(443)
  assert head.path == ""
  assert head.query == None
}

pub fn connect_without_port_rejected_test() {
  let buffer = <<"CONNECT example.com HTTP/1.1\r\n\r\n":utf8>>
  assert parse(buffer) == Error(parser.BadTarget)
}

pub fn mixed_case_and_ows_headers_test() {
  let buffer = <<
    "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length:  13  \r\nConnection: close\r\n\r\nHELLO WORLD!!":utf8,
  >>

  let assert Ok(parser.Complete(head, metadata, remaining)) = parse(buffer)

  assert head.headers
    == [
      #("host", "example.com"),
      #("content-length", "13"),
      #("connection", "close"),
    ]
  assert metadata.framing == http1.Fixed(13)
  assert metadata.keep_alive == http1.CloseAfterResponse
  assert remaining == <<"HELLO WORLD!!":utf8>>
}

pub fn tab_ows_trimmed_test() {
  let buffer = <<
    "GET / HTTP/1.1\r\nHost: example.com\r\nX-Name:\t\tvalue\t\t\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(head, _metadata, _remaining)) = parse(buffer)

  assert head.headers == [#("host", "example.com"), #("x-name", "value")]
}

pub fn chunked_transfer_encoding_test() {
  let buffer = <<
    "PUT /x HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert metadata.framing == http1.Chunked
}

pub fn transfer_encoding_alongside_another_coding_rejected_test() {
  let buffer = <<
    "PUT /x HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: gzip, chunked\r\n\r\n":utf8,
  >>

  assert parse(buffer) == Error(parser.UnsupportedTransferEncoding)
    as "chunked is the only coding decoded here, so a body wrapped in another one cannot be handed on"
}

pub fn transfer_encoding_without_chunked_rejected_test() {
  let buffer = <<
    "PUT /x HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: gzip\r\n\r\nhello":utf8,
  >>

  assert parse(buffer) == Error(parser.UnsupportedTransferEncoding)
    as "treating an undelimited body as no body at all leaves it on the socket to be read as the next request"
}

pub fn chunked_not_final_across_repeated_headers_rejected_test() {
  let buffer = <<
    "PUT /x HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: gzip\r\n\r\n":utf8,
  >>

  assert parse(buffer) == Error(parser.UnsupportedTransferEncoding)
}

pub fn chunked_rejected_on_http_1_0_test() {
  let buffer = <<
    "PUT /x HTTP/1.0\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n":utf8,
  >>

  assert parse(buffer) == Error(parser.AmbiguousFraming)
    as "HTTP/1.0 has no chunked coding, so the body has no framing"
}

pub fn configured_max_headers_is_applied_test() {
  let buffer = <<
    "GET / HTTP/1.1\r\nHost: example.com\r\nX-A: 1\r\nX-B: 2\r\n\r\n":utf8,
  >>
  let options = http1.Options(..http1.default_options(), max_headers: 2)

  assert parser.parse(buffer, options) == Error(parser.TooManyHeaders)
  let assert Ok(parser.Complete(..)) = parse(buffer)
    as "the same request is fine under the default limit"
}

pub fn configured_max_request_line_is_applied_test() {
  let buffer = <<
    "GET /a/fairly/long/path HTTP/1.1\r\nHost: example.com\r\n":utf8,
  >>
  let options = http1.Options(..http1.default_options(), max_request_line: 8)

  assert parser.parse(buffer, options) == Error(parser.RequestLineTooLong)
}

pub fn configured_max_header_line_is_applied_test() {
  let buffer = <<"GET / HTTP/1.1\r\nHost: example.com\r\n":utf8>>
  let options = http1.Options(..http1.default_options(), max_header_line: 4)

  assert parser.parse(buffer, options) == Error(parser.HeaderLineTooLong)
}

pub fn conflicting_content_length_and_chunked_rejected_test() {
  let buffer = <<
    "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello":utf8,
  >>

  assert parse(buffer) == Error(parser.AmbiguousFraming)
}

pub fn conflicting_transfer_encoding_and_content_length_reversed_order_rejected_test() {
  let buffer = <<
    "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\nhello":utf8,
  >>

  assert parse(buffer) == Error(parser.AmbiguousFraming)
}

pub fn connection_close_lookalike_is_not_close_test() {
  let buffer = <<
    "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close-enough\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert metadata.keep_alive == http1.KeepAlive
    as "\"close-enough\" is not the \"close\" token"
}

pub fn connection_close_among_multiple_tokens_test() {
  let buffer = <<
    "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: Upgrade, Close\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert metadata.keep_alive == http1.CloseAfterResponse
}

pub fn http11_defaults_to_keep_alive_test() {
  let buffer = <<"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8>>
  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert metadata.keep_alive == http1.KeepAlive
    as "HTTP/1.1 without Connection defaults to keep-alive"
}

pub fn http10_defaults_to_close_test() {
  let buffer = <<"GET / HTTP/1.0\r\n\r\n":utf8>>
  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert metadata.keep_alive == http1.CloseAfterResponse
    as "HTTP/1.0 without Connection defaults to close"
}

pub fn http10_explicit_keep_alive_test() {
  let buffer = <<"GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n":utf8>>
  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert metadata.keep_alive == http1.KeepAlive
}

pub fn incomplete_headers_test() {
  let buffer = <<"GET /foo HTTP/1.1\r\nHost: example.com\r\n":utf8>>
  assert parse(buffer) == Ok(parser.Incomplete)
}

pub fn split_across_reads_test() {
  let first = <<"GET / HTTP/1.1\r\nHo":utf8>>
  assert parse(first) == Ok(parser.Incomplete)

  let second = <<"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8>>
  let assert Ok(parser.Complete(head, _metadata, _remaining)) = parse(second)

  assert head.path == "/"
}

pub fn unsupported_version_test() {
  let buffer = <<"GET /foo HTTP/9.9\r\n\r\n":utf8>>
  assert parse(buffer) == Error(parser.UnsupportedVersion)
}

pub fn malformed_version_test() {
  let buffer = <<"INVALID CONNECTION PREFACE\r\n\r\n":utf8>>
  assert parse(buffer) == Error(parser.BadVersion)
}

pub fn duplicate_content_length_test() {
  let buffer = <<
    "GET / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n":utf8,
  >>
  assert parse(buffer) == Error(parser.DuplicateContentLength)
}

pub fn multibyte_utf8_header_value_test() {
  let buffer = <<
    "GET / HTTP/1.1\r\nHost: example.com\r\nX-Name: caf\u{00E9}\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(head, _metadata, _remaining)) = parse(buffer)

  assert head.headers == [#("host", "example.com"), #("x-name", "café")]
}

pub fn invalid_utf8_header_value_rejected_test() {
  let buffer = <<
    "GET / HTTP/1.1\r\nHost: example.com\r\nX-Name: caf":utf8,
    255,
    "\r\n\r\n":utf8,
  >>

  assert parse(buffer) == Error(parser.BadHeader)
}

pub fn bare_lf_rejected_test() {
  let buffer = <<"GET / HTTP/1.1\nHost: example.com\r\n\r\n":utf8>>
  assert parse(buffer) == Error(parser.BadRequestLine)
}

pub fn websocket_upgrade_requested_test() {
  let buffer = <<
    "GET /ws HTTP/1.1\r\nHost: example.com\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert metadata.upgrade
    == Some(http1.WebsocketUpgrade(key: None, version: None, extensions: None))
}

pub fn upgrade_token_case_insensitive_test() {
  let buffer = <<
    "GET /ws HTTP/1.1\r\nHost: example.com\r\nConnection: Upgrade\r\nUpgrade: WebSocket\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert metadata.upgrade
    == Some(http1.WebsocketUpgrade(key: None, version: None, extensions: None))
}

pub fn upgrade_among_multiple_connection_tokens_test() {
  let buffer = <<
    "GET /h2c HTTP/1.1\r\nHost: example.com\r\nConnection: keep-alive, Upgrade\r\nUpgrade: h2c\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert metadata.upgrade == Some(http1.OtherUpgrade("h2c"))
}

pub fn upgrade_header_without_connection_token_ignored_test() {
  let buffer = <<
    "GET /ws HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert metadata.upgrade == None
    as "Upgrade requires Connection: upgrade to be honored (RFC 9110 §7.8)"
}

pub fn upgrade_header_before_connection_header_test() {
  let buffer = <<
    "GET /ws HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert metadata.upgrade
    == Some(http1.WebsocketUpgrade(key: None, version: None, extensions: None))
    as "order of Upgrade vs. Connection headers shouldn't matter"
}

pub fn websocket_handshake_fields_collected_test() {
  let buffer = <<
    "GET /ws HTTP/1.1\r\nHost: example.com\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Extensions: Permessage-Deflate; client_max_window_bits\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert metadata.upgrade
    == Some(http1.WebsocketUpgrade(
      key: Some("dGhlIHNhbXBsZSBub25jZQ=="),
      version: Some("13"),
      extensions: Some("permessage-deflate; client_max_window_bits"),
    ))
}

pub fn websocket_headers_without_an_upgrade_are_ignored_test() {
  let buffer = <<
    "GET /ws HTTP/1.1\r\nHost: example.com\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert metadata.upgrade == None
}

pub fn whitespace_before_header_colon_rejected_test() {
  let buffer = <<
    "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length : 5\r\n\r\nhello":utf8,
  >>

  assert parse(buffer) == Error(parser.BadHeader)
    as "a name of `content-length ` would leave the body to be read as the next request"
}

pub fn empty_header_name_rejected_test() {
  let buffer = <<"GET / HTTP/1.1\r\nHost: example.com\r\n: value\r\n\r\n":utf8>>
  assert parse(buffer) == Error(parser.BadHeader)
}

pub fn nul_in_header_value_rejected_test() {
  let buffer = <<
    "GET / HTTP/1.1\r\nHost: example.com\r\nX-Name: a":utf8,
    0,
    "b\r\n\r\n":utf8,
  >>

  assert parse(buffer) == Error(parser.BadHeader)
}

pub fn bare_cr_in_header_value_rejected_test() {
  let buffer = <<
    "GET / HTTP/1.1\r\nHost: example.com\r\nX-Name: a\rb\r\n\r\n":utf8,
  >>

  assert parse(buffer) == Error(parser.BadHeader)
}

pub fn absolute_form_authority_replaces_host_test() {
  let buffer = <<
    "GET HTTP://api.example.com:8080/users?id=1 HTTP/1.1\r\nHost: other.com\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(head, _metadata, _remaining)) = parse(buffer)

  assert head.host == "api.example.com"
  assert head.port == Some(8080)
  assert head.path == "/users"
  assert head.query == Some("id=1")
}

pub fn absolute_form_without_path_test() {
  let buffer = <<
    "GET https://example.com?id=1 HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(head, _metadata, _remaining)) = parse(buffer)

  assert head.host == "example.com"
  assert head.port == None
  assert head.path == "/"
  assert head.query == Some("id=1")
}

pub fn absolute_form_with_userinfo_rejected_test() {
  let buffer = <<
    "GET http://user@example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8,
  >>

  assert parse(buffer) == Error(parser.BadTarget)
}

pub fn absolute_form_with_empty_host_rejected_test() {
  let buffer = <<"GET http:///path HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8>>
  assert parse(buffer) == Error(parser.BadTarget)
}

pub fn absolute_form_with_other_scheme_rejected_test() {
  let buffer = <<
    "GET wss://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8,
  >>
  assert parse(buffer) == Error(parser.BadTarget)
}

pub fn absolute_form_still_requires_host_on_http11_test() {
  let buffer = <<"GET http://example.com/ HTTP/1.1\r\n\r\n":utf8>>
  assert parse(buffer) == Error(parser.MissingHost)
}

pub fn empty_line_before_request_line_ignored_test() {
  let buffer = <<"\r\nGET / HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8>>
  let assert Ok(parser.Complete(head, _metadata, remaining)) = parse(buffer)

  assert head.path == "/"
  assert remaining == <<>>
}

pub fn lone_empty_line_waits_for_more_test() {
  assert parse(<<"\r\n":utf8>>) == Ok(parser.Incomplete)
}

pub fn chunked_after_another_coding_across_headers_rejected_test() {
  let buffer = <<
    "PUT /x HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n":utf8,
  >>

  assert parse(buffer) == Error(parser.UnsupportedTransferEncoding)
    as "repeated headers combine into `gzip, chunked`, the same as one header"
}

pub fn chunked_twice_across_headers_rejected_test() {
  let buffer = <<
    "PUT /x HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n":utf8,
  >>

  assert parse(buffer) == Error(parser.UnsupportedTransferEncoding)
}

pub fn expect_continue_with_body_test() {
  let buffer = <<
    "POST / HTTP/1.1\r\nHost: example.com\r\nExpect: 100-Continue\r\nContent-Length: 5\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert metadata.expect_continue
}

pub fn expect_continue_without_body_ignored_test() {
  let buffer = <<
    "GET / HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert !metadata.expect_continue
}

pub fn expect_continue_on_http10_ignored_test() {
  let buffer = <<
    "POST / HTTP/1.0\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n":utf8,
  >>

  let assert Ok(parser.Complete(_head, metadata, _remaining)) = parse(buffer)

  assert !metadata.expect_continue
    as "RFC 9110 §10.1.1 requires ignoring the expectation in HTTP/1.0"
}
