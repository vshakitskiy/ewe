import ewe/internal/http/buffer
import gleam/dynamic
import gleam/http
import gleam/option

/// Type of HTTP packet being decoded.
/// 
pub type PacketType {
  HttpBin
  HttphBin
}

/// Absolute path in HTTP request.
/// 
pub type AbsPath {
  AbsPath(BitArray)
}

/// HTTP version as major and minor numbers.
/// 
pub type Version =
  #(Int, Int)

/// HTTP packet structure.
/// 
pub type HttpPacket {
  HttpRequest(method: BitArray, path: AbsPath, version: Version)
  HttpHeader(idx: Int, field: BitArray, value: BitArray)
  HttpEoh
  Http2Upgrade
}

/// Complete packet with data and remaining bytes.
/// 
pub type Packet {
  Packet(HttpPacket, rest: BitArray)
  More(length: option.Option(Int))
}

/// Decodes HTTP packets using external FFI implementation.
/// 
pub fn decode_packet(
  type_ type_: PacketType,
  buffer buffer: buffer.Buffer,
) -> Result(Packet, dynamic.Dynamic) {
  decode_packet_ffi(type_, buffer.data, [])
}

@external(erlang, "ewe_ffi", "decode_packet")
fn decode_packet_ffi(
  type_ type_: PacketType,
  packet packet: BitArray,
  options options: List(a),
) -> Result(Packet, dynamic.Dynamic)

/// Decodes HTTP method from binary data.
/// 
pub fn decode_method(method: BitArray) -> Result(http.Method, Nil) {
  case method {
    <<"GET">> -> Ok(http.Get)
    <<"POST">> -> Ok(http.Post)
    <<"HEAD">> -> Ok(http.Head)
    <<"PUT">> -> Ok(http.Put)
    <<"DELETE">> -> Ok(http.Delete)
    <<"TRACE">> -> Ok(http.Trace)
    <<"CONNECT">> -> Ok(http.Connect)
    <<"OPTIONS">> -> Ok(http.Options)
    <<"PATCH">> -> Ok(http.Patch)
    _ -> Error(Nil)
  }
}

/// Maps header field indices to their string names.
/// 
pub fn formatted_field_by_idx(idx: Int) -> Result(String, Nil) {
  case idx {
    0 -> Error(Nil)
    1 -> Ok("cache-control")
    2 -> Ok("connection")
    3 -> Ok("date")
    4 -> Ok("pragma")
    5 -> Ok("transfer-encoding")
    6 -> Ok("upgrade")
    7 -> Ok("via")
    8 -> Ok("accept")
    9 -> Ok("accept-charset")
    10 -> Ok("accept-encoding")
    11 -> Ok("accept-language")
    12 -> Ok("authorization")
    13 -> Ok("from")
    14 -> Ok("host")
    15 -> Ok("if-modified-since")
    16 -> Ok("if-match")
    17 -> Ok("if-none-match")
    18 -> Ok("if-range")
    19 -> Ok("if-unmodified-since")
    20 -> Ok("max-forwards")
    21 -> Ok("proxy-authorization")
    22 -> Ok("range")
    23 -> Ok("referer")
    24 -> Ok("user-agent")
    25 -> Ok("age")
    26 -> Ok("location")
    27 -> Ok("proxy-authenticate")
    28 -> Ok("public")
    29 -> Ok("retry-after")
    30 -> Ok("server")
    31 -> Ok("vary")
    32 -> Ok("warning")
    33 -> Ok("www-authenticate")
    34 -> Ok("allow")
    35 -> Ok("content-base")
    36 -> Ok("content-encoding")
    37 -> Ok("content-language")
    38 -> Ok("content-length")
    39 -> Ok("content-location")
    40 -> Ok("content-md5")
    41 -> Ok("content-range")
    42 -> Ok("content-type")
    43 -> Ok("etag")
    44 -> Ok("expires")
    45 -> Ok("last-modified")
    46 -> Ok("accept-ranges")
    47 -> Ok("set-cookie")
    48 -> Ok("set-cookie2")
    49 -> Ok("x-forwarded-for")
    50 -> Ok("cookie")
    51 -> Ok("keep-alive")
    52 -> Ok("proxy-connection")
    _ -> Error(Nil)
  }
}
