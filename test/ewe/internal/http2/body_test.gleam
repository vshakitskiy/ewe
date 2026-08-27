import ewe/internal/connection as ewe_connection
import ewe/internal/http2/body
import ewe/internal/http2/connection as http2
import gleam/erlang/process
import gleam/option

fn fill_mailbox(
  conn_subject: process.Subject(http2.Reply(ewe_connection.Body)),
  script: List(http2.BodyEvent),
) -> Nil {
  case script {
    [] -> Nil
    [event, ..remaining] -> {
      let assert http2.ReadBody(_stream_id, reply_to) =
        process.receive_forever(conn_subject)
      process.send(reply_to, event)
      fill_mailbox(conn_subject, remaining)
    }
  }
}

fn mock_connection(
  script: List(http2.BodyEvent),
) -> http2.Connection(ewe_connection.Body) {
  let init_subject = process.new_subject()
  process.spawn(fn() {
    let conn_subject = process.new_subject()
    process.send(init_subject, conn_subject)
    fill_mailbox(conn_subject, script)
  })
  let conn_subject = process.receive_forever(init_subject)
  http2.Connection(
    connection: conn_subject,
    stream_id: 1,
    has_body: True,
    pending: <<>>,
    pending_trailers: option.None,
    read: 0,
    body_read_timeout: 1000,
    peer: Error(Nil),
    protocol: option.None,
  )
}

pub fn read_body_accumulates_chunks_until_done_test() {
  let conn =
    mock_connection([
      http2.ChunkEvent(<<"abc":utf8>>),
      http2.ChunkEvent(<<"def":utf8>>),
      http2.DoneEvent([]),
    ])

  assert body.read_body(conn, 100) == Ok(#(<<"abcdef":utf8>>, []))
}

pub fn read_body_returns_trailers_test() {
  let conn =
    mock_connection([
      http2.ChunkEvent(<<"abc":utf8>>),
      http2.DoneEvent([#("x-checksum", "deadbeef")]),
    ])

  assert body.read_body(conn, 100)
    == Ok(#(<<"abc":utf8>>, [#("x-checksum", "deadbeef")]))
}

pub fn read_body_collapses_last_chunk_into_one_round_trip_test() {
  let conn = mock_connection([http2.LastChunkEvent(<<"abcdef":utf8>>, [])])

  assert body.read_body(conn, 100) == Ok(#(<<"abcdef":utf8>>, []))
}

pub fn read_body_collapsed_last_chunk_carries_trailers_test() {
  let conn =
    mock_connection([
      http2.LastChunkEvent(<<"abc":utf8>>, [#("x-checksum", "deadbeef")]),
    ])

  assert body.read_body(conn, 100)
    == Ok(#(<<"abc":utf8>>, [#("x-checksum", "deadbeef")]))
}

pub fn read_body_chunk_collapses_final_lump_into_one_round_trip_test() {
  let conn = mock_connection([http2.LastChunkEvent(<<"abcdefghij":utf8>>, [])])

  let assert Ok(body.Chunk(first, conn)) =
    body.read_body_chunk(conn, max_chunk_bytes: 4, limit: 100)
  assert first == <<"abcd":utf8>>

  let assert Ok(body.Chunk(second, conn)) =
    body.read_body_chunk(conn, max_chunk_bytes: 4, limit: 100)
  assert second == <<"efgh":utf8>>

  let assert Ok(body.Chunk(third, conn)) =
    body.read_body_chunk(conn, max_chunk_bytes: 4, limit: 100)
  assert third == <<"ij":utf8>>

  assert body.read_body_chunk(conn, max_chunk_bytes: 4, limit: 100)
    == Ok(body.Done([]))
}

pub fn read_body_empty_body_is_done_immediately_test() {
  let conn = mock_connection([http2.DoneEvent([])])

  assert body.read_body(conn, 100) == Ok(#(<<>>, []))
}

pub fn read_body_no_body_skips_round_trip_test() {
  let conn =
    http2.Connection(
      connection: process.new_subject(),
      stream_id: 1,
      has_body: False,
      pending: <<>>,
      pending_trailers: option.None,
      read: 0,
      body_read_timeout: 1000,
      peer: Error(Nil),
      protocol: option.None,
    )

  assert body.read_body(conn, 100) == Ok(#(<<>>, []))
}

pub fn read_body_stops_when_over_limit_test() {
  let chunk = <<0:size({ 30 * 8 })>>
  let conn = mock_connection([http2.ChunkEvent(chunk), http2.ChunkEvent(chunk)])

  assert body.read_body(conn, 40) == Error(body.BodyTooLarge)
}

pub fn read_body_chunk_splits_pulled_lump_without_extra_message_test() {
  let conn =
    mock_connection([
      http2.ChunkEvent(<<"abcdefghij":utf8>>),
      http2.DoneEvent([]),
    ])

  let assert Ok(body.Chunk(first, conn)) =
    body.read_body_chunk(conn, max_chunk_bytes: 4, limit: 100)
  assert first == <<"abcd":utf8>>

  let assert Ok(body.Chunk(second, conn)) =
    body.read_body_chunk(conn, max_chunk_bytes: 4, limit: 100)
  assert second == <<"efgh":utf8>>

  let assert Ok(body.Chunk(third, conn)) =
    body.read_body_chunk(conn, max_chunk_bytes: 4, limit: 100)
  assert third == <<"ij":utf8>>

  assert body.read_body_chunk(conn, max_chunk_bytes: 4, limit: 100)
    == Ok(body.Done([]))
}

pub fn read_body_chunk_returns_whole_lump_when_under_cap_test() {
  let conn =
    mock_connection([
      http2.ChunkEvent(<<"abc":utf8>>),
      http2.DoneEvent([#("x-checksum", "deadbeef")]),
    ])

  let assert Ok(body.Chunk(data, conn)) =
    body.read_body_chunk(conn, max_chunk_bytes: 100, limit: 100)
  assert data == <<"abc":utf8>>

  assert body.read_body_chunk(conn, max_chunk_bytes: 100, limit: 100)
    == Ok(body.Done([#("x-checksum", "deadbeef")]))
}

pub fn read_body_chunk_no_body_skips_round_trip_test() {
  let conn =
    http2.Connection(
      connection: process.new_subject(),
      stream_id: 1,
      has_body: False,
      pending: <<>>,
      pending_trailers: option.None,
      read: 0,
      body_read_timeout: 1000,
      peer: Error(Nil),
      protocol: option.None,
    )

  assert body.read_body_chunk(conn, max_chunk_bytes: 100, limit: 100)
    == Ok(body.Done([]))
}
