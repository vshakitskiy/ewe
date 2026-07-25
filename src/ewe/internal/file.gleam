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
  path: String,
  offset: option.Option(Int),
  limit: option.Option(Int),
) -> Result(connection.File, FileError) {
  use size <- result.try(stat(path))
  let offset = option.unwrap(offset, 0)
  let available = size - offset

  case offset >= 0 && offset <= size, limit {
    True, option.None -> {
      Ok(connection.FileMetadata(path:, offset:, length: available))
    }
    True, option.Some(limit) -> {
      let length = int.min(limit, available)
      Ok(connection.FileMetadata(path:, offset:, length:))
    }
    _, option.Some(limit) if limit < 0 -> Error(InvalidLimit)
    False, _ -> Error(InvalidOffset)
  }
}

pub fn send(
  transport: transport.Transport,
  socket: socket.Socket,
  file: connection.File,
) -> Result(Nil, socket.SocketReason) {
  case file.length {
    0 -> Ok(Nil)
    length -> {
      use fd <- result.try(open(file.path))
      let result = case transport {
        transport.Tcp -> do_sendfile(fd, socket, file.offset, length)
        transport.Ssl -> send_chunks(transport, socket, fd, file.offset, length)
      }
      close(fd)
      result
    }
  }
}

const chunk_size = 65_536

fn send_chunks(
  transport: transport.Transport,
  socket: socket.Socket,
  fd: FileDescriptor,
  offset: Int,
  remaining: Int,
) -> Result(Nil, socket.SocketReason) {
  case remaining {
    0 -> Ok(Nil)
    _remaining -> {
      let amount = int.min(remaining, chunk_size)
      use data <- result.try(pread(fd, offset, amount))
      use Nil <- result.try(transport.send(
        transport,
        socket,
        bytes_tree.from_bit_array(data),
      ))

      send_chunks(transport, socket, fd, offset + amount, remaining - amount)
    }
  }
}

pub type FileDescriptor

@external(erlang, "file_ffi", "stat")
fn stat(path: String) -> Result(Int, FileError)

@external(erlang, "file_ffi", "sendfile")
fn do_sendfile(
  fd: FileDescriptor,
  socket: socket.Socket,
  offset: Int,
  bytes: Int,
) -> Result(Nil, socket.SocketReason)

@external(erlang, "file_ffi", "open")
fn open(path: String) -> Result(FileDescriptor, socket.SocketReason)

@external(erlang, "file_ffi", "pread")
fn pread(
  fd: FileDescriptor,
  offset: Int,
  length: Int,
) -> Result(BitArray, socket.SocketReason)

@external(erlang, "file_ffi", "close")
fn close(fd: FileDescriptor) -> Nil
