import ewe
import ewe/internal/connection
import ewe/internal/http2/connection as http2
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/option
import gleeunit
import logging

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Info)

  gleeunit.main()
}

fn answer_reads(
  conn_subject: process.Subject(http2.Reply(connection.Body)),
  script: List(http2.BodyEvent),
) -> Nil {
  case script {
    [] -> Nil
    [event, ..remaining] -> {
      let assert http2.ReadBody(_stream_id, reply_to) =
        process.receive_forever(conn_subject)
      process.send(reply_to, event)
      answer_reads(conn_subject, remaining)
    }
  }
}

fn request_reading(
  script: List(http2.BodyEvent),
) -> request.Request(ewe.Connection) {
  let init_subject = process.new_subject()
  process.spawn(fn() {
    let conn_subject = process.new_subject()
    process.send(init_subject, conn_subject)
    answer_reads(conn_subject, script)
  })

  let body =
    connection.Http2(http2.Connection(
      connection: process.receive_forever(init_subject),
      stream_id: 1,
      has_body: True,
      pending: <<>>,
      pending_trailers: option.None,
      read: 0,
      body_read_timeout: 1000,
      peer: Error(Nil),
    ))

  request.Request(
    method: http.Post,
    headers: [],
    body:,
    scheme: http.Http,
    host: "example.com",
    port: option.None,
    path: "/",
    query: option.None,
  )
}

pub fn read_body_chunk_reads_a_zero_chunk_size_as_one_test() {
  let request = request_reading([http2.ChunkEvent(<<"abc":utf8>>)])

  let assert Ok(ewe.Chunk(data, _request)) =
    ewe.read_body_chunk(request, max_chunk_bytes: 0, limit: 1000)

  assert data == <<"a":utf8>>
}

pub fn read_body_chunk_reads_a_negative_chunk_size_as_one_test() {
  let request = request_reading([http2.ChunkEvent(<<"abc":utf8>>)])

  let assert Ok(ewe.Chunk(data, _request)) =
    ewe.read_body_chunk(request, max_chunk_bytes: -5, limit: 1000)

  assert data == <<"a":utf8>>
}
