import ewe/internal/http2/connection as http2
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/erlang/reference
import gleam/option

pub type BodyError {
  BodyTooLarge
  InvalidBody
}

pub fn read_body(
  connection: http2.Connection(body),
  limit: Int,
) -> Result(#(BitArray, List(#(String, String))), BodyError) {
  case connection.has_body {
    False -> Ok(#(<<>>, []))
    True -> read_all(connection, limit, bytes_tree.new())
  }
}

fn read_all(
  connection: http2.Connection(body),
  limit: Int,
  acc: bytes_tree.BytesTree,
) -> Result(#(BitArray, List(#(String, String))), BodyError) {
  case next_chunk(connection) {
    Error(error) -> Error(error)
    Ok(Done(trailers)) -> Ok(#(bytes_tree.to_bit_array(acc), trailers))
    Ok(Chunk(data, connection)) ->
      case connection.read > limit {
        True -> Error(BodyTooLarge)
        False -> read_all(connection, limit, bytes_tree.append(acc, data))
      }
  }
}

pub type ReadEvent(body) {
  Chunk(data: BitArray, connection: http2.Connection(body))
  Done(trailers: List(#(String, String)))
}

pub fn read_body_chunk(
  connection: http2.Connection(body),
  max_chunk_bytes max_chunk_bytes: Int,
  limit limit: Int,
) -> Result(ReadEvent(body), BodyError) {
  case next_chunk(connection) {
    Error(error) -> Error(error)
    Ok(Done(trailers)) -> Ok(Done(trailers))
    Ok(Chunk(data, connection)) ->
      case connection.read > limit {
        True -> Error(BodyTooLarge)
        False -> Ok(split(connection, data, max_chunk_bytes))
      }
  }
}

fn split(
  connection: http2.Connection(body),
  data: BitArray,
  max_chunk_bytes: Int,
) -> ReadEvent(body) {
  case data {
    <<chunk:bytes-size(max_chunk_bytes), pending:bits>> ->
      Chunk(chunk, http2.Connection(..connection, pending:))
    _data -> Chunk(data, http2.Connection(..connection, pending: <<>>))
  }
}

fn next_chunk(
  connection: http2.Connection(body),
) -> Result(ReadEvent(body), BodyError) {
  case connection.has_body, connection.pending, connection.pending_trailers {
    False, _pending, _trailers -> Ok(Done([]))
    True, <<>>, option.Some(trailers) -> Ok(Done(trailers))
    True, <<>>, option.None -> pull(connection)
    True, pending, _trailers ->
      Ok(Chunk(pending, http2.Connection(..connection, pending: <<>>)))
  }
}

fn pull(
  connection: http2.Connection(body),
) -> Result(ReadEvent(body), BodyError) {
  let tag = reference.new()
  let reply_to = process.unsafely_create_subject(process.self(), http2.tag(tag))

  process.send(
    connection.connection,
    http2.ReadBody(connection.stream_id, reply_to),
  )

  case http2.receive_reply_within(tag, connection.body_read_timeout) {
    Error(_interrupted) -> Error(InvalidBody)
    Ok(http2.DoneEvent(trailers)) -> Ok(Done(trailers))
    Ok(http2.ChunkEvent(data)) -> Ok(Chunk(data, advance(connection, data)))
    Ok(http2.LastChunkEvent(data, trailers)) ->
      Ok(Chunk(
        data,
        http2.Connection(
          ..advance(connection, data),
          pending_trailers: option.Some(trailers),
        ),
      ))
  }
}

fn advance(
  connection: http2.Connection(body),
  data: BitArray,
) -> http2.Connection(body) {
  http2.Connection(
    ..connection,
    read: connection.read + bit_array.byte_size(data),
  )
}
