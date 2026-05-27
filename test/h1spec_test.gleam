import client/http
import client/tcp as client
import gleam/bytes_tree
import gleam/http/response.{type Response}
import gleam/list
import glisten/socket.{type Socket}
import glisten/tcp
import server

fn expect_timeout(req: String) -> Nil {
  let socket_address = server.start(server.echoer())
  use socket <- client.with_socket(socket_address.port, active: False)

  let assert Ok(Nil) = tcp.send(socket, bytes_tree.from_string(req))

  assert tcp.receive_timeout(socket, 0, 500) == Error(socket.Timeout)
}

fn run_request(socket: Socket, req: String) -> Response(String) {
  let assert Ok(Nil) = tcp.send(socket, bytes_tree.from_string(req))

  let assert Ok(resp) = tcp.receive_timeout(socket, 0, 1000)
  let assert Ok(resp) = http.parse(resp)

  resp
}

pub fn expect_status(
  req: String,
  status: List(#(Int, Int)),
) -> Response(String) {
  let socket_address = server.start(server.echoer())
  use socket <- client.with_socket(socket_address.port, active: False)

  let resp = run_request(socket, req)

  assert list.fold_until(over: status, from: False, with: fn(_, status) {
      let #(start, end) = status

      case resp.status {
        status if status >= start && status <= end -> list.Stop(True)
        _ -> list.Continue(False)
      }
    })
    == True

  resp
}

pub fn fragmented_method_test() {
  expect_timeout("G")
}

pub fn fragmented_url_1_test() {
  expect_timeout("GET ")
}

pub fn fragmented_url_2_test() {
  expect_timeout("GET /hello")
}

pub fn fragmented_url_3_test() {
  expect_timeout("GET /hello ")
}

pub fn fragmented_http_version_test() {
  expect_timeout("GET /hello HTTP")
}

pub fn fragmented_request_line_test() {
  expect_timeout("GET /hello HTTP/1.1")
}

pub fn fragmented_request_line_newline_1_test() {
  expect_timeout("GET /hello HTTP/1.1\r")
}

pub fn fragmented_request_line_newline_2_test() {
  expect_timeout("GET /hello HTTP/1.1\r\n")
}

pub fn fragmented_field_name_test() {
  expect_timeout("GET /hello HTTP/1.1\r\nHos")
}

pub fn fragmented_field_value_1_test() {
  expect_timeout("GET /hello HTTP/1.1\r\nHost:")
}

pub fn fragmented_field_value_2_test() {
  expect_timeout("GET /hello HTTP/1.1\r\nHost: ")
}

pub fn fragmented_field_value_3_test() {
  expect_timeout("GET /hello HTTP/1.1\r\nHost: localhost")
}

pub fn fragmented_field_value_4_test() {
  expect_timeout("GET /hello HTTP/1.1\r\nHost: localhost\r")
}

pub fn fragmented_request_test() {
  expect_timeout("GET /hello HTTP/1.1\r\nHost: localhost\r\n")
}

pub fn fragmented_request_termination_test() {
  expect_timeout("GET /hello HTTP/1.1\r\nHost: localhost\r\n\r")
}

pub fn request_without_http_version_test() {
  expect_status("GET / \r\n\r\n", [#(400, 599)])
}

pub fn request_with_expect_header_test() {
  expect_status(
    "GET / HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue\r\n\r\n",
    [#(100, 100), #(200, 299)],
  )
}

pub fn valid_get_request_test() {
  expect_status("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n", [#(200, 299)])
}

pub fn valid_get_request_with_edge_case() {
  expect_status("GET / HTTP/1.1\r\nhoSt:\texample.com\r\nempty:\r\n\r\n", [
    #(200, 299),
  ])
}

pub fn invalid_header_characters_test() {
  expect_status(
    "GET / HTTP/1.1\r\nHost: example.com\r\nX-Invalid[]: test\r\n\r\n",
    [#(400, 499)],
  )
}

pub fn missing_host_header_test() {
  expect_status("GET / HTTP/1.1\r\nContent-Length: 5\r\n\r\n", [#(400, 499)])
}

pub fn multiple_host_headers_test() {
  expect_status(
    "GET / HTTP/1.1\r\nHost: example.com\r\nHost: example.org\r\n\r\n",
    [#(400, 499)],
  )
}

pub fn overflowing_negative_content_length_test() {
  expect_status(
    "GET / HTTP/1.1\r\nHost: example.com\r\nContent-Length: -123456789123456789123456789\r\n\r\n",
    [#(400, 499)],
  )
}

pub fn negative_content_length_test() {
  expect_status(
    "GET / HTTP/1.1\r\nHost: example.com\r\nContent-Length: -1234\r\n\r\n",
    [#(400, 499)],
  )
}

pub fn non_numeric_content_length_test() {
  expect_status(
    "GET / HTTP/1.1\r\nHost: example.com\r\nContent-Length: abc\r\n\r\n",
    [#(400, 499)],
  )
}

pub fn empty_header_value_test() {
  expect_status(
    "GET / HTTP/1.1\r\nHost: example.com\r\nX-Empty-Header: \r\n\r\n",
    [#(200, 299)],
  )
}

pub fn header_containing_invalid_control_character_test() {
  expect_status(
    "GET / HTTP/1.1\r\nHost: example.com\r\nX-Bad-Control-Char: test\u{0007}\r\n\r\n",
    [#(400, 499)],
  )
}

pub fn invalid_http_version_test() {
  expect_status("GET / HTTP/9.9\r\nHost: example.com\r\n\r\n", [
    #(400, 499),
    #(500, 599),
  ])
}

pub fn invalid_prefix_of_request_test() {
  expect_status("Extra lineGET / HTTP/1.1\r\nHost: example.com\r\n\r\n", [
    #(400, 499),
    #(500, 599),
  ])
}

pub fn invalid_line_ending_test() {
  expect_status(
    "GET / HTTP/1.1\r\nHost: example.com\r\n\rSome-Header: Test\r\n\r\n",
    [#(400, 499)],
  )
}

pub fn valid_post_request_with_body_test() {
  let resp =
    expect_status(
      "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello",
      [#(200, 299)],
    )

  assert resp.body == "hello"
}

pub fn chunked_transfer_encoding_test() {
  let resp =
    expect_status(
      "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\nc\r\nHellO world1\r\n0\r\n\r\n",
      [#(200, 299)],
    )

  assert resp.body == "HellO world1"
}

pub fn conflicting_transfer_encoding_and_content_length_test() {
  let resp =
    expect_status(
      "POST / HTTP/1.1\r\nHost: example.com\r\ncontent-LengtH: 5\r\nTransFer-Encoding: chunked\r\n\r\nc\r\nHellO world1\r\n0\r\n\r\n",
      [#(400, 499), #(200, 299)],
    )

  assert resp.body == "HellO world1"
}
