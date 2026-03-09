import gleam/bit_array
import gleam/int

/// Buffer holding data read from a socket, along with how many more bytes are
/// expected (pending) before the current read operation is complete.
///
pub type Buffer {
  Buffer(data: BitArray, pending: Int)
}

/// Appends data to the buffer and decrements pending bytes accordingly.
///
pub fn append(buffer: Buffer, data: BitArray) -> Buffer {
  let pending = int.max(0, buffer.pending - bit_array.byte_size(data))
  Buffer(<<buffer.data:bits, data:bits>>, pending)
}

/// Splits the buffer data at the given byte boundary. Returns the first part
/// and the rest.
///
pub fn split(buffer: Buffer, bytes: Int) -> #(BitArray, BitArray) {
  case buffer.data {
    <<partition:bytes-size(bytes), rest:bits>> -> #(partition, rest)
    _ -> #(buffer.data, <<>>)
  }
}
