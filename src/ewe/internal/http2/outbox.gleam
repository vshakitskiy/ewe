import ewe/internal/connection
import ewe/internal/queue
import gleam/bit_array
import gleam/bytes_tree
import gleam/int
import gleam/result

pub opaque type Outbox {
  Outbox(items: queue.Queue(Piece), size: Int, finished: Bool)
}

pub type Piece {
  Bytes(bytes: bytes_tree.BytesTree, size: Int)
  File(descriptor: connection.FileDescriptor, offset: Int, length: Int)
}

const file_chunk = 65_536

pub fn new() -> Outbox {
  Outbox(items: queue.new(), size: 0, finished: False)
}

pub fn push(outbox: Outbox, piece: Piece) -> Outbox {
  case piece_size(piece) {
    0 -> outbox
    size ->
      Outbox(
        ..outbox,
        items: queue.push(outbox.items, piece),
        size: outbox.size + size,
      )
  }
}

pub fn finish(outbox: Outbox) -> Outbox {
  Outbox(..outbox, finished: True)
}

pub fn size(outbox: Outbox) -> Int {
  outbox.size
}

pub fn is_finished(outbox: Outbox) -> Bool {
  outbox.finished
}

pub fn take(
  outbox: Outbox,
  limit: Int,
  read: fn(connection.FileDescriptor, Int, Int) -> Result(BitArray, error),
) -> Result(#(Piece, Bool, Outbox), error) {
  case queue.pop(outbox.items) {
    Error(Nil) -> Ok(#(Bytes(bytes_tree.new(), 0), outbox.finished, outbox))
    Ok(#(File(descriptor:, offset:, length:), items)) if limit >= file_chunk -> {
      let taken = int.min(length, limit)
      let items = rest_of_file(items, descriptor, offset, taken, length)
      Ok(finish_take(outbox, File(descriptor, offset, taken), items))
    }
    Ok(#(File(descriptor:, offset:, length:), items)) -> {
      let size = int.min(length, file_chunk)
      use bits <- result.try(read(descriptor, offset, size))
      let items = rest_of_file(items, descriptor, offset, size, length)

      Outbox(..outbox, items: queue.push_front(items, bytes(bits)))
      |> take(limit, read)
    }
    Ok(#(Bytes(bytes:, size:), items)) -> {
      let #(bytes, size, items) =
        gather(bytes_tree.new(), 0, bytes, size, items, limit)
      Ok(finish_take(outbox, Bytes(bytes, size), items))
    }
  }
}

fn rest_of_file(
  items: queue.Queue(Piece),
  descriptor: connection.FileDescriptor,
  offset: Int,
  taken: Int,
  length: Int,
) -> queue.Queue(Piece) {
  case length - taken {
    0 -> items
    left -> queue.push_front(items, File(descriptor, offset + taken, left))
  }
}

fn finish_take(
  outbox: Outbox,
  taken: Piece,
  items: queue.Queue(Piece),
) -> #(Piece, Bool, Outbox) {
  let size = outbox.size - piece_size(taken)
  #(taken, outbox.finished && size == 0, Outbox(..outbox, items:, size:))
}

fn gather(
  acc: bytes_tree.BytesTree,
  acc_size: Int,
  bytes: bytes_tree.BytesTree,
  size: Int,
  items: queue.Queue(Piece),
  limit: Int,
) -> #(bytes_tree.BytesTree, Int, queue.Queue(Piece)) {
  let room = limit - acc_size

  case size <= room {
    True -> {
      let acc = bytes_tree.append_tree(acc, bytes)
      let acc_size = acc_size + size

      case queue.pop(items) {
        Ok(#(Bytes(bytes:, size:), rest)) if acc_size < limit ->
          gather(acc, acc_size, bytes, size, rest, limit)
        Ok(_next) | Error(Nil) -> #(acc, acc_size, items)
      }
    }
    False -> {
      let assert <<head:bytes-size(room), rest:bits>> =
        bytes_tree.to_bit_array(bytes)
      let rest = Bytes(bytes_tree.from_bit_array(rest), size - room)

      #(bytes_tree.append(acc, head), limit, queue.push_front(items, rest))
    }
  }
}

pub fn piece_size(piece: Piece) -> Int {
  case piece {
    Bytes(size:, ..) -> size
    File(length:, ..) -> length
  }
}

pub fn bytes(bits: BitArray) -> Piece {
  Bytes(bytes_tree.from_bit_array(bits), bit_array.byte_size(bits))
}
