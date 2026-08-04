import ewe/internal/connection
import gleam/bytes_tree
import gleam/int
import gleam/option
import gleam/result
import glisten/socket
import glisten/transport

pub type FileError {
  NotFound
  IsDirectory
  AccessDenied
  UnknownError
  InvalidOffset
  InvalidLimit
}

pub fn resolve(
  conn: connection.Connection,
  path: String,
  offset: option.Option(Int),
  limit: option.Option(Int),
) -> Result(connection.File, FileError) {
  case conn {
    connection.Http1(_conn) -> {
      use handle <- result.try(open(path))

      case size(handle) |> result.try(range(_, offset, limit)) {
        Ok(#(offset, length)) ->
          Ok(connection.OpenFile(handle:, offset:, length:))
        Error(error) -> {
          close(handle)
          Error(error)
        }
      }
    }
    connection.Http2 -> {
      use size <- result.try(stat(path))
      use #(offset, length) <- result.map(range(size, offset, limit))

      connection.PendingFile(path:, offset:, length:)
    }
  }
}

fn range(
  size: Int,
  offset: option.Option(Int),
  limit: option.Option(Int),
) -> Result(#(Int, Int), FileError) {
  let offset = option.unwrap(offset, 0)

  case offset >= 0 && offset <= size {
    False -> Error(InvalidOffset)
    True -> {
      let available = size - offset

      case limit {
        option.None -> Ok(#(offset, available))
        option.Some(limit) if limit < 0 -> Error(InvalidLimit)
        option.Some(limit) -> Ok(#(offset, int.min(limit, available)))
      }
    }
  }
}

/// Hands back a descriptor. 
pub fn release(file: connection.File) -> Nil {
  case file {
    connection.OpenFile(handle:, ..) -> close(handle)
    connection.PendingFile(..) -> Nil
  }
}

pub fn release_body(body: connection.Body) -> Nil {
  case body {
    connection.File(file) -> release(file)
    connection.Bytes(..)
    | connection.Text(..)
    | connection.Empty
    | connection.Streaming(..)
    | connection.Sse(..) -> Nil
  }
}

pub fn send(
  transport: transport.Transport,
  socket: socket.Socket,
  file: connection.File,
) -> Result(Nil, socket.SocketReason) {
  case file {
    connection.OpenFile(handle:, offset:, length:) ->
      send_handle(transport, socket, handle, offset, length)
    connection.PendingFile(..) -> todo as "HTTP/2 is not implemented yet!"
  }
}

/// Owns the descriptor from here on, so it is closed however the write ends.
fn send_handle(
  transport: transport.Transport,
  socket: socket.Socket,
  handle: connection.FileDescriptor,
  offset: Int,
  length: Int,
) -> Result(Nil, socket.SocketReason) {
  let sent = case length {
    0 -> Ok(Nil)
    _length ->
      case transport {
        transport.Tcp -> do_sendfile(handle, socket, offset, length)
        transport.Ssl -> send_chunks(transport, socket, handle, offset, length)
      }
  }

  close(handle)
  sent
}

const chunk_size = 65_536

fn send_chunks(
  transport: transport.Transport,
  socket: socket.Socket,
  handle: connection.FileDescriptor,
  offset: Int,
  remaining: Int,
) -> Result(Nil, socket.SocketReason) {
  case remaining {
    0 -> Ok(Nil)
    _remaining -> {
      let amount = int.min(remaining, chunk_size)
      use data <- result.try(pread(handle, offset, amount))
      use Nil <- result.try(transport.send(
        transport,
        socket,
        bytes_tree.from_bit_array(data),
      ))

      send_chunks(
        transport,
        socket,
        handle,
        offset + amount,
        remaining - amount,
      )
    }
  }
}

@external(erlang, "file_ffi", "stat")
fn stat(path: String) -> Result(Int, FileError)

@external(erlang, "file_ffi", "sendfile")
fn do_sendfile(
  handle: connection.FileDescriptor,
  socket: socket.Socket,
  offset: Int,
  bytes: Int,
) -> Result(Nil, socket.SocketReason)

@external(erlang, "file_ffi", "open")
fn open(path: String) -> Result(connection.FileDescriptor, FileError)

@external(erlang, "file_ffi", "size")
fn size(handle: connection.FileDescriptor) -> Result(Int, FileError)

@external(erlang, "file_ffi", "pread")
fn pread(
  handle: connection.FileDescriptor,
  offset: Int,
  length: Int,
) -> Result(BitArray, socket.SocketReason)

@external(erlang, "file_ffi", "close")
fn close(handle: connection.FileDescriptor) -> Nil
