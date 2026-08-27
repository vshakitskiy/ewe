import ewe
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import logging

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Debug)

  let assert Ok(_started) =
    ewe.new(
      listener_name: process.new_name("cleartext_listener"),
      connection_factory_name: process.new_name("cleartext_factory"),
      handler: handle_request,
    )
    |> ewe.bind("0.0.0.0")
    |> ewe.listening(on: 8099)
    |> ewe.start

  let assert Ok(_started) =
    ewe.new(
      listener_name: process.new_name("tls_listener"),
      connection_factory_name: process.new_name("tls_factory"),
      handler: handle_request,
    )
    |> ewe.bind("0.0.0.0")
    |> ewe.listening(on: 8443)
    |> ewe.with_tls(ewe.Disk("dev/priv/localhost.crt", "dev/priv/localhost.key"))
    |> ewe.start

  process.sleep_forever()
}

fn handle_request(
  request: request.Request(ewe.Connection),
) -> response.Response(ewe.Body) {
  case request.path {
    "/ws" -> echo_socket(request)
    _path ->
      response.new(200)
      |> response.set_header("content-type", "text/html; charset=utf-8")
      |> response.set_body(ewe.Text(page))
  }
}

fn echo_socket(
  request: request.Request(ewe.Connection),
) -> response.Response(ewe.Body) {
  ewe.websocket(
    request:,
    on_init: fn(_conn, selector) { #(0, selector) },
    handler: fn(conn, count, message) {
      case message {
        ewe.TextFrame(text) -> {
          logging.log(logging.Info, "text frame: " <> text)

          case ewe.send_text_frame(conn, text) {
            Ok(Nil) -> ewe.continue(count + 1)
            Error(_error) -> ewe.stop()
          }
        }
        ewe.BinaryFrame(data) ->
          case ewe.send_binary_frame(conn, data) {
            Ok(Nil) -> ewe.continue(count + 1)
            Error(_error) -> ewe.stop()
          }
        ewe.UserMessage(_message) -> ewe.continue(count)
      }
    },
    on_close: fn(_conn, count) {
      logging.log(logging.Info, "socket closed after " <> to_string(count))
    },
  )
}

@external(erlang, "erlang", "integer_to_binary")
fn to_string(value: Int) -> String

const page = "<!doctype html>
<meta charset='utf-8'>
<title>WebSocket</title>
<style>
  body { font: 15px/1.6 system-ui, sans-serif; max-width: 42rem; margin: 3rem auto; padding: 0 1rem }
  h1 { font-size: 1.4rem }
  #log { background: #f4f4f5; border-radius: 6px; padding: 1rem; white-space: pre-wrap; font: 13px/1.7 ui-monospace, monospace }
  .ok { color: #15803d } .bad { color: #b91c1c }
  button { font: inherit; padding: .4rem .9rem; border-radius: 6px; border: 1px solid #d4d4d8; background: #fff; cursor: pointer }
  input { font: inherit; padding: .4rem .6rem; border-radius: 6px; border: 1px solid #d4d4d8; width: 18rem }
</style>

<p><input id='msg' value='hello' autocomplete='off'>
<button id='send'>send</button>
<button id='close'>close</button></p>

<div id='log'>connecting…</div>

<script>
  const log = document.getElementById('log')
  const line = (text, cls) => {
    const el = document.createElement('div')
    if (cls) el.className = cls
    el.textContent = text
    log.append(el)
  }

  const url = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws'
  log.textContent = ''
  line('page loaded over ' + location.protocol)
  line('opening ' + url)

  const ws = new WebSocket(url)
  ws.onopen = () => line('open', 'ok')
  ws.onmessage = event => line('received: ' + event.data, 'ok')
  ws.onerror = () => line('error', 'bad')
  ws.onclose = event =>
    line('closed code=' + event.code + ' clean=' + event.wasClean, event.wasClean ? 'ok' : 'bad')

  document.getElementById('send').onclick = () => {
    const value = document.getElementById('msg').value
    ws.send(value)
    line('sent: ' + value)
  }
  document.getElementById('close').onclick = () => ws.close(1000, 'bye')
</script>
"
