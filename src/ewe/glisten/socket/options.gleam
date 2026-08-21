/// Mode for the socket.  Currently `list` is not supported
pub type SocketMode {
  Binary
}

/// Mapping to the `{active, _}` option
pub type ActiveState {
  /// The server acknowledges every package.
  Once
  /// Not used by server - for use with low level `tcp.receive`.
  Passive
  /// The server will receive `n` packages before activating again.
  Count(Int)
  /// Connection is always active, no flow control.
  Active
}

pub type Interface {
  Address(IpAddress)
  UnixPath(String)
  Any
  Loopback
}

/// Specifies how TLS certificates and keys are provided to the server
pub type TlsCerts {
  CertKeyFiles(certfile: String, keyfile: String)
  /// In-memory PEM-encoded certificate and key.
  CertKeyPem(cert: BitArray, key: BitArray)
  /// In-memory DER-encoded certificate and key. The key type must be provided 
  /// explicitly since it is not embedded in the binary.
  CertKeyDer(cert: BitArray, key_type: TlsKeyType, key: BitArray)
}

/// The private key encoding type, required when providing DER-encoded 
/// certificate and key
pub type TlsKeyType {
  /// Traditional RSA key.
  RsaPrivateKey
  /// Elliptic curve key.
  EcPrivateKey
  /// DSA key.
  DsaPrivateKey
  /// PKCS#8 key.
  PrivateKeyInfo
}

/// Options for the TCP socket
pub type TcpOption {
  /// Default 1024
  Backlog(Int)
  /// Default True
  Nodelay(Bool)
  Linger(#(Bool, Int))
  /// Default 30_000
  SendTimeout(Int)
  /// Default True
  SendTimeoutClose(Bool)
  /// Default True
  Reuseaddr(Bool)
  /// Default Passive for low level and Once for server.
  ActiveMode(ActiveState)
  /// Default Binary
  Mode(SocketMode)
  // TODO:  Probably should adjust the type here to only allow this for TLS
  CertKeyConfig(TlsCerts)
  AlpnPreferredProtocols(List(String))
  Ipv6
  Buffer(Int)
  Ip(Interface)
  /// Controls client certificate verification.
  Verify(VerifyMode)
  /// Path to a PEM file containing CA certificate for client verification.
  CaCertFile(String)
  /// In-memory DER-encoded CA certificate for client verification.
  CaCerts(List(BitArray))
  /// When `True`, rejects connections that do not present a client certificate.  
  /// Default False.
  FailIfNoPeerCert(Bool)
}

/// Controls whether the server verifies the client's certificate
pub type VerifyMode {
  /// No client certificate is requested.
  VerifyNone
  /// Client must present a certificate.
  VerifyPeer
}

pub type ErlangTcpOption

@external(erlang, "glisten_ffi", "to_erl_tcp_options")
pub fn to_erl_options(options: List(TcpOption)) -> List(ErlangTcpOption)

pub const unix_default_options = [
  Backlog(1024),
  SendTimeout(30_000),
  SendTimeoutClose(True),
  Mode(Binary),
  ActiveMode(Passive),
]

pub const tcp_default_options = [
  Backlog(1024),
  Nodelay(True),
  SendTimeout(30_000),
  SendTimeoutClose(True),
  Reuseaddr(True),
  Mode(Binary),
  ActiveMode(Passive),
]

@external(erlang, "glisten_ffi", "merge_type_list")
pub fn merge_type_list(original: List(a), override: List(a)) -> List(a)

pub fn merge_with_tcp_defaults(options: List(TcpOption)) -> List(TcpOption) {
  merge_type_list(tcp_default_options, options)
}

pub fn merge_with_unix_defaults(options: List(TcpOption)) -> List(TcpOption) {
  merge_type_list(unix_default_options, options)
}

pub type IpAddress {
  IpV4(Int, Int, Int, Int)
  IpV6(Int, Int, Int, Int, Int, Int, Int, Int)
}
