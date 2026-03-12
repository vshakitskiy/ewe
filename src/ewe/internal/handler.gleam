import ewe/internal/http.{type Connection, type ResponseBody} as http_
import ewe/internal/http/handler as handler_
import ewe/internal/http2
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import glisten

/// State of the request handler.
///
pub type Handler {
  Http1(state: handler_.HttpHandler, self: process.Subject(Nil))
}

/// Initializes the request handler state.
///
pub fn init(_) -> #(Handler, Option(process.Selector(Nil))) {
  let subject = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(subject)

  #(Http1(handler_.init(), self: subject), Some(selector))
}

/// Main loop that processes incoming messages.
///
pub fn loop(
  handler: fn(Request(Connection)) -> Response(ResponseBody),
  on_crash: Response(ResponseBody),
  factory_name: process.Name(
    factory.Message(fn() -> Result(actor.Started(Nil), actor.StartError), Nil),
  ),
  idle_timeout: Int,
) -> glisten.Loop(Handler, Nil) {
  fn(
    state: Handler,
    message: glisten.Message(Nil),
    conn: glisten.Connection(Nil),
  ) -> glisten.Next(Handler, glisten.Message(Nil)) {
    let sender = conn.subject
    let conn = http_.transform_connection(conn, factory_name)

    case state, message {
      Http1(state, self), glisten.Packet(message) -> {
        let handled =
          handler_.handle_packet(
            state,
            conn,
            message,
            sender,
            handler,
            on_crash,
            idle_timeout,
          )

        case handled {
          handler_.Continue(state) -> glisten.continue(Http1(state, self))
          handler_.Http2Upgrade(http_.Direct(data:)) -> {
            let supervisor = factory.get_by_name(factory_name)
            let started =
              factory.start_child(supervisor, fn() {
                http2.start(
                  conn.transport,
                  conn.socket,
                  data,
                  option.None,
                  handler,
                )
              })

            case started {
              Ok(_) -> glisten.stop()
              Error(_) ->
                glisten.stop_abnormal("Failed to spawn HTTP/2 connection")
            }
          }
          handler_.Http2Upgrade(http_.Upgrade(req:, settings:)) ->
            http2.handle_http_upgrade(
              conn.transport,
              conn.socket,
              req,
              settings,
            )
          handler_.Stop -> glisten.stop()
        }
      }
      _, _ -> glisten.stop()
    }
  }
}
