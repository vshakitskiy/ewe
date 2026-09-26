import alpacki
import ewe
import ewe/internal/http2/frame
import gleam/bit_array
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/otp/actor

pub type Socket

pub type RecvError {
  Timeout
  Closed
}

pub type Client {
  Client(
    socket: Socket,
    buffer: BitArray,
    decoder: alpacki.DynamicTable,
    encoder: alpacki.DynamicTable,
  )
}

pub type Received {
  Response(status: Int, headers: List(#(String, String)), body: BitArray)
  Reset(error: frame.ErrorCode)
  GoneAway(error: frame.ErrorCode)
}

pub fn serve(
  handler: fn(request.Request(ewe.Connection)) -> response.Response(ewe.Body),
) -> Int {
  serve_with(handler, ewe.default_http2_options())
}

pub fn serve_with(
  handler: fn(request.Request(ewe.Connection)) -> response.Response(ewe.Body),
  options: ewe.Http2Options,
) -> Int {
  let assert Ok(actor.Started(data: ewe.TcpSocketAddress(port:, ..), ..)) =
    ewe.new(handler)
    |> ewe.listening_random
    |> ewe.quiet
    |> ewe.with_http2(options)
    |> ewe.start

  port
}

pub fn connect(port: Int) -> Client {
  let assert Ok(socket) = tcp_connect(port)
  let client =
    Client(
      socket:,
      buffer: <<>>,
      decoder: alpacki.new_dynamic(4096),
      encoder: alpacki.new_dynamic(4096),
    )
  send_bits(client, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8>>)
}

pub fn handshake(port: Int, settings: List(frame.Setting)) -> Client {
  let client =
    connect(port)
    |> send(frame.Settings(ack: False, settings:))

  let #(server_settings, client) = receive_any(client)
  let assert frame.Settings(ack: False, ..) = server_settings

  let client = send(client, frame.Settings(ack: True, settings: []))
  skip_until(client, fn(received) {
    received == frame.Settings(ack: True, settings: [])
  }).1
}

pub fn send(client: Client, sent: frame.Frame) -> Client {
  send_bits(client, frame.encode(sent))
}

fn send_bits(client: Client, bits: BitArray) -> Client {
  let assert Ok(Nil) = tcp_send(client.socket, bits)
  client
}

pub fn encode_fields(
  client: Client,
  fields: List(#(String, String)),
) -> #(BitArray, Client) {
  let fields =
    list.map(fields, fn(field) {
      alpacki.HeaderField(
        <<field.0:utf8>>,
        <<field.1:utf8>>,
        alpacki.WithIndexing,
      )
    })
  let #(block, encoder) =
    alpacki.encode_header_block(fields, client.encoder, False)
  #(block, Client(..client, encoder:))
}

pub fn headers(
  client: Client,
  stream_id: Int,
  fields: List(#(String, String)),
  end_stream: Bool,
) -> Client {
  let #(fragment, client) = encode_fields(client, fields)

  send(
    client,
    frame.Headers(
      stream_id:,
      end_stream:,
      end_headers: True,
      dependency: None,
      fragment:,
    ),
  )
}

pub fn get(client: Client, stream_id: Int, path: String) -> Client {
  headers(client, stream_id, request_fields("GET", path), True)
}

pub fn request_fields(method: String, path: String) -> List(#(String, String)) {
  [
    #(":method", method),
    #(":scheme", "http"),
    #(":authority", "localhost"),
    #(":path", path),
  ]
}

pub fn data(
  client: Client,
  stream_id: Int,
  data: BitArray,
  end_stream: Bool,
) -> Client {
  send(
    client,
    frame.Data(stream_id:, end_stream:, data:, size: bit_array.byte_size(data)),
  )
}

pub fn receive_any(client: Client) -> #(frame.Frame, Client) {
  let assert Ok(received) = try_receive(client, 2000)
  received
}

fn try_receive(
  client: Client,
  timeout: Int,
) -> Result(#(frame.Frame, Client), RecvError) {
  case frame.decode(client.buffer, frame.max_frame_size) {
    frame.Decoded(frame:, rest:) -> Ok(#(frame, Client(..client, buffer: rest)))
    frame.NeedMoreData ->
      case tcp_recv(client.socket, timeout) {
        Ok(bytes) ->
          Client(..client, buffer: <<client.buffer:bits, bytes:bits>>)
          |> try_receive(timeout)
        Error(error) -> Error(error)
      }
    frame.StreamError(..) | frame.ConnectionError(..) ->
      panic as "the server sent a malformed frame"
  }
}

pub fn receive(client: Client) -> #(frame.Frame, Client) {
  skip_until(client, fn(received) {
    case received {
      frame.Settings(ack: True, ..) | frame.WindowUpdate(..) -> False
      _frame -> True
    }
  })
}

pub fn skip_until(
  client: Client,
  wanted: fn(frame.Frame) -> Bool,
) -> #(frame.Frame, Client) {
  let #(received, client) = receive_any(client)

  case wanted(received) {
    True -> #(received, client)
    False -> skip_until(client, wanted)
  }
}

pub fn is_closed(client: Client) -> Bool {
  case try_receive(client, 2000) {
    Error(Closed) -> True
    Error(Timeout) -> False
    Ok(#(_frame, client)) -> is_closed(client)
  }
}

pub fn is_quiet(client: Client) -> Bool {
  case try_receive(client, 200) {
    Error(Timeout) -> True
    Error(Closed) | Ok(_frame) -> False
  }
}

pub fn response(client: Client, stream_id: Int) -> #(Received, Client) {
  collect(client, stream_id, None, <<>>)
}

fn collect(
  client: Client,
  stream_id: Int,
  head: option.Option(#(Int, List(#(String, String)))),
  body: BitArray,
) -> #(Received, Client) {
  let #(received, client) = receive(client)

  case received {
    frame.Headers(stream_id: id, end_stream:, end_headers:, fragment:, ..) -> {
      let #(fields, client) = decode_block(client, [fragment], end_headers)

      case id == stream_id, fields {
        True, [#(":status", status), ..headers] -> {
          let assert Ok(status) = int.parse(status)

          case end_stream {
            True -> #(Response(status:, headers:, body:), client)
            False ->
              collect(client, stream_id, option.Some(#(status, headers)), body)
          }
        }
        True, _fields -> panic as "a response without :status"
        False, _fields -> collect(client, stream_id, head, body)
      }
    }
    frame.Data(stream_id: id, end_stream:, data:, size:) if id == stream_id -> {
      let client = credit(client, stream_id, size)
      let body = <<body:bits, data:bits>>

      case end_stream, head {
        True, option.Some(#(status, headers)) -> #(
          Response(status:, headers:, body:),
          client,
        )
        _end_stream, _head -> collect(client, stream_id, head, body)
      }
    }
    frame.RstStream(stream_id: id, error:) if id == stream_id -> #(
      Reset(error),
      client,
    )
    frame.Goaway(error: frame.NoError, ..) ->
      collect(client, stream_id, head, body)
    frame.Goaway(error:, ..) -> #(GoneAway(error), client)
    _other -> collect(client, stream_id, head, body)
  }
}

fn decode_block(
  client: Client,
  fragments: List(BitArray),
  end_headers: Bool,
) -> #(List(#(String, String)), Client) {
  case end_headers {
    False -> {
      let #(received, client) = receive_any(client)
      let assert frame.Continuation(end_headers:, fragment:, ..) = received
      decode_block(client, [fragment, ..fragments], end_headers)
    }
    True -> {
      let block = bit_array.concat(list.reverse(fragments))
      let assert Ok(alpacki.DecodedHeaderBlock(
        headers: fields,
        dynamic_table: decoder,
        remaining: <<>>,
        ..,
      )) = alpacki.decode_header_block(block, client.decoder)
      let fields =
        list.map(fields, fn(field) {
          let assert Ok(name) = bit_array.to_string(field.0)
          let assert Ok(value) = bit_array.to_string(field.1)
          #(name, value)
        })

      #(fields, Client(..client, decoder:))
    }
  }
}

fn credit(client: Client, stream_id: Int, size: Int) -> Client {
  case size {
    0 -> client
    _size -> {
      let _sent =
        tcp_send(client.socket, <<
          frame.encode(frame.WindowUpdate(0, size)):bits,
          frame.encode(frame.WindowUpdate(stream_id, size)):bits,
        >>)
      client
    }
  }
}

pub fn close(client: Client) -> Nil {
  tcp_close(client.socket)
}

pub fn wait_until(condition: fn() -> Bool, tries: Int) -> Bool {
  case condition(), tries {
    True, _tries -> True
    False, 0 -> False
    False, _tries -> {
      process.sleep(10)
      wait_until(condition, tries - 1)
    }
  }
}

@external(erlang, "ewe_http2_client_ffi", "connect")
fn tcp_connect(port: Int) -> Result(Socket, Nil)

@external(erlang, "ewe_http2_client_ffi", "send")
fn tcp_send(socket: Socket, bits: BitArray) -> Result(Nil, Nil)

@external(erlang, "ewe_http2_client_ffi", "recv")
fn tcp_recv(socket: Socket, timeout: Int) -> Result(BitArray, RecvError)

@external(erlang, "ewe_http2_client_ffi", "close")
fn tcp_close(socket: Socket) -> Nil
