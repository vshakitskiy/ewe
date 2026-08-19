import ewe
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  let listener_name = process.new_name("listener_name")
  let connection_factory_name = process.new_name("connection_factory_name")

  // A server that logs who every request came from and tells the client its own
  // address, the way `curl ifconfig.me` does.
  //
  let assert Ok(_) =
    ewe.new(listener_name:, connection_factory_name:, handler: handle_request)
    |> ewe.bind(to: "0.0.0.0")
    |> ewe.listening(on: 8080)
    |> ewe.start

  process.sleep_forever()
}

fn handle_request(
  request: request.Request(ewe.Connection),
) -> response.Response(ewe.Body) {
  // The connection the request carries is what the client's address is read
  // from, so it is `request.body` that goes in here.
  let client = describe_client(request.body)

  logging.log(
    logging.Info,
    http.method_to_string(request.method)
      <> " "
      <> request.path
      <> " "
      <> client,
  )

  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(ewe.Text(client <> "\n"))
}

// Behind a proxy this is the proxy's address and not the browser's. The address
// the proxy puts in `x-forwarded-for` is the one to use there. 
// 
// See https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/X-Forwarded-For
fn describe_client(connection: ewe.Connection) -> String {
  case ewe.get_client_info(connection) {
    Ok(ewe.TcpSocketAddress(ip_address:, port:)) -> {
      // An IPv6 address is bracketed so the port stays readable next to the
      // colons the address itself is full of.
      let host = case ip_address {
        ewe.IpV6(..) -> "[" <> ewe.ip_address_to_string(ip_address) <> "]"
        ewe.IpV4(..) -> ewe.ip_address_to_string(ip_address)
      }

      host <> ":" <> int.to_string(port)
    }
    // A unix socket client is unnamed unless it bound a path of its own, which
    // clients rarely do, so most of the time there is no path to report.
    Ok(ewe.UnixSocketAddress(path: "")) -> "unix socket"
    Ok(ewe.UnixSocketAddress(path:)) -> "unix:" <> path
    // The socket is already gone, so there is nothing left to report.
    Error(Nil) -> "unknown"
  }
}
