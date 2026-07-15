import ewe/internal/http1
import gleam/http
import gleam/option.{None, Some}

pub fn simple_get_test() {
  let buffer = <<
    "GET /foo?a=1 HTTP/1.1\r\nHost: example.com\r\nConnection: keep-alive\r\n\r\n":utf8,
  >>

  let assert http1.Complete(head, metadata, remaining) = http1.parse(buffer)

  assert head.method == http.Get
  assert head.host == "example.com"
  assert head.port == None
  assert head.path == "/foo"
  assert head.query == Some("a=1")
  assert head.version == http1.Http11
  assert head.headers
    == [#("host", "example.com"), #("connection", "keep-alive")]
  assert metadata.keep_alive
  assert !metadata.chunked
  assert metadata.content_length == None
  assert remaining == <<>>
}

pub fn host_with_port_test() {
  let buffer = <<"GET / HTTP/1.1\r\nHost: example.com:8080\r\n\r\n":utf8>>
  let assert http1.Complete(head, _metadata, _remaining) = http1.parse(buffer)

  assert head.host == "example.com"
  assert head.port == Some(8080)
}

pub fn host_ipv6_with_port_test() {
  let buffer = <<"GET / HTTP/1.1\r\nHost: [::1]:8080\r\n\r\n":utf8>>
  let assert http1.Complete(head, _metadata, _remaining) = http1.parse(buffer)

  assert head.host == "[::1]"
  assert head.port == Some(8080)
}

pub fn missing_host_on_http11_rejected_test() {
  let buffer = <<"GET / HTTP/1.1\r\n\r\n":utf8>>
  assert http1.parse(buffer) == http1.Failed(http1.MissingHost)
}

pub fn missing_host_on_http10_allowed_test() {
  let buffer = <<"GET / HTTP/1.0\r\n\r\n":utf8>>
  let assert http1.Complete(head, _metadata, _remaining) = http1.parse(buffer)

  assert head.host == ""
  assert head.port == None
}

pub fn duplicate_host_rejected_test() {
  let buffer = <<"GET / HTTP/1.1\r\nHost: a.com\r\nHost: b.com\r\n\r\n":utf8>>
  assert http1.parse(buffer) == http1.Failed(http1.DuplicateHost)
}

pub fn relative_path_rejected_test() {
  let buffer = <<"GET foo HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8>>
  assert http1.parse(buffer) == http1.Failed(http1.BadTarget)
}

pub fn asterisk_form_allowed_for_options_test() {
  let buffer = <<"OPTIONS * HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8>>
  let assert http1.Complete(head, _metadata, _remaining) = http1.parse(buffer)

  assert head.path == "*"
}

pub fn asterisk_form_rejected_for_get_test() {
  let buffer = <<"GET * HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8>>
  assert http1.parse(buffer) == http1.Failed(http1.BadTarget)
}

pub fn connect_authority_form_test() {
  let buffer = <<"CONNECT example.com:443 HTTP/1.1\r\n\r\n":utf8>>
  let assert http1.Complete(head, _metadata, _remaining) = http1.parse(buffer)

  assert head.host == "example.com"
  assert head.port == Some(443)
  assert head.path == ""
  assert head.query == None
}

pub fn connect_without_port_rejected_test() {
  let buffer = <<"CONNECT example.com HTTP/1.1\r\n\r\n":utf8>>
  assert http1.parse(buffer) == http1.Failed(http1.BadTarget)
}

pub fn mixed_case_and_ows_headers_test() {
  let buffer = <<
    "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length:  13  \r\nConnection: close\r\n\r\nHELLO WORLD!!":utf8,
  >>

  let assert http1.Complete(head, metadata, remaining) = http1.parse(buffer)

  assert head.headers
    == [
      #("host", "example.com"),
      #("content-length", "13"),
      #("connection", "close"),
    ]
  assert metadata.content_length == Some(13)
  assert !metadata.keep_alive
  assert remaining == <<"HELLO WORLD!!":utf8>>
}

pub fn chunked_transfer_encoding_test() {
  let buffer = <<
    "PUT /x HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n":utf8,
  >>

  let assert http1.Complete(_head, metadata, _remaining) = http1.parse(buffer)

  assert metadata.chunked
}

pub fn connection_close_lookalike_is_not_close_test() {
  let buffer = <<
    "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close-enough\r\n\r\n":utf8,
  >>

  let assert http1.Complete(_head, metadata, _remaining) = http1.parse(buffer)

  assert metadata.keep_alive as "\"close-enough\" is not the \"close\" token"
}

pub fn connection_close_among_multiple_tokens_test() {
  let buffer = <<
    "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: Upgrade, Close\r\n\r\n":utf8,
  >>

  let assert http1.Complete(_head, metadata, _remaining) = http1.parse(buffer)

  assert !metadata.keep_alive
}

pub fn custom_method_test() {
  let buffer = <<"PROPFIND /dav HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8>>
  let assert http1.Complete(head, _metadata, _remaining) = http1.parse(buffer)

  assert head.method == http.Other("PROPFIND")
}

pub fn incomplete_request_line_test() {
  let buffer = <<"GET /foo HTTP/1.1\r\n":utf8>>
  assert http1.parse(buffer) == http1.Incomplete
}

pub fn incomplete_headers_test() {
  let buffer = <<"GET /foo HTTP/1.1\r\nHost: example.com\r\n":utf8>>
  assert http1.parse(buffer) == http1.Incomplete
}

pub fn split_across_reads_test() {
  let first = <<"GET / HTTP/1.1\r\nHo":utf8>>
  assert http1.parse(first) == http1.Incomplete

  let second = <<"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8>>
  let assert http1.Complete(head, _metadata, _remaining) = http1.parse(second)

  assert head.path == "/"
}

pub fn bad_request_line_test() {
  let buffer = <<"GET /foo HTTP/9.9\r\n\r\n":utf8>>
  assert http1.parse(buffer) == http1.Failed(http1.BadVersion)
}

pub fn duplicate_content_length_test() {
  let buffer = <<
    "GET / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n":utf8,
  >>
  assert http1.parse(buffer) == http1.Failed(http1.DuplicateContentLength)
}

pub fn multibyte_utf8_header_value_test() {
  let buffer = <<
    "GET / HTTP/1.1\r\nHost: example.com\r\nX-Name: caf\u{00E9}\r\n\r\n":utf8,
  >>

  let assert http1.Complete(head, _metadata, _remaining) = http1.parse(buffer)

  assert head.headers == [#("host", "example.com"), #("x-name", "café")]
}

pub fn invalid_utf8_header_value_rejected_test() {
  let buffer = <<
    "GET / HTTP/1.1\r\nHost: example.com\r\nX-Name: caf":utf8,
    255,
    "\r\n\r\n":utf8,
  >>

  assert http1.parse(buffer) == http1.Failed(http1.BadHeader)
}

pub fn bare_lf_rejected_test() {
  let buffer = <<"GET / HTTP/1.1\nHost: example.com\r\n\r\n":utf8>>
  assert http1.parse(buffer) == http1.Failed(http1.BadRequestLine)
}

pub fn no_query_string_test() {
  let buffer = <<"GET /plain HTTP/1.1\r\nHost: example.com\r\n\r\n":utf8>>

  assert http1.parse(buffer)
    == http1.Complete(
      http1.Head(
        method: http.Get,
        host: "example.com",
        port: None,
        path: "/plain",
        query: None,
        version: http1.Http11,
        headers: [#("host", "example.com")],
      ),
      http1.Metadata(content_length: None, chunked: False, keep_alive: True),
      <<>>,
    )
}
