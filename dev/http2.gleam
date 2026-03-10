import ewe
import gleam/erlang/process
import gleam/http/response
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Debug)

  let assert Ok(_started) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(server_worker(port: 8080, secure: False))
    |> supervisor.add(server_worker(port: 8443, secure: True))
    |> supervisor.start

  process.sleep_forever()
}

fn server_worker(
  port port: Int,
  secure secure: Bool,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  supervision.worker(fn() {
    let builder =
      ewe.new(handle_request)
      |> ewe.listening(port:)

    let builder = case secure {
      True -> {
        ewe.enable_tls(
          builder,
          certificate_file: "examples/priv/localhost.crt",
          key_file: "examples/priv/localhost.key",
        )
      }
      False -> builder
    }

    ewe.start(builder)
  })
}

fn handle_request(_request: ewe.Request) -> ewe.Response {
  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(ewe.TextData("Hello, World!"))
}
