import ewe/glisten/socket/options

pub type SocketReason {
  Closed
  Timeout
  Badarg
  Terminated

  // inet:posix() errors.
  Eaddrinuse
  Eaddrnotavail
  Eafnosupport
  Ealready
  Econnaborted
  Econnrefused
  Econnreset
  Edestaddrreq
  Ehostdown
  Ehostunreach
  Einprogress
  Eisconn
  Emsgsize
  Enetdown
  Enetunreach
  Enopkg
  Enoprotoopt
  Enotconn
  Enotty
  Enotsock
  Eproto
  Eprotonosupport
  Eprototype
  Esocktnosupport
  Etimedout
  Ewouldblock
  Exbadport
  Exbadseq

  // file:posix() errors.
  Eacces
  Eagain
  Ebadf
  Ebadmsg
  Ebusy
  Edeadlk
  Edeadlock
  Edquot
  Eexist
  Efault
  Efbig
  Eftype
  Eintr
  Einval
  Eio
  Eisdir
  Eloop
  Emfile
  Emlink
  Emultihop
  Enametoolong
  Enfile
  Enobufs
  Enodev
  Enolck
  Enolink
  Enoent
  Enomem
  Enospc
  Enosr
  Enostr
  Enosys
  Enotblk
  Enotdir
  Enotsup
  Enxio
  Eopnotsupp
  Eoverflow
  Eperm
  Epipe
  Erange
  Erofs
  Espipe
  Esrch
  Estale
  Etxtbsy
  Exdev
}

pub fn reason_to_string(reason: SocketReason) -> String {
  case reason {
    Closed -> "Closed"
    Timeout -> "Timeout"
    Badarg -> "Badarg"
    Terminated -> "Terminated"
    Eaddrinuse -> "Eaddrinuse"
    Eaddrnotavail -> "Eaddrnotavail"
    Eafnosupport -> "Eafnosupport"
    Ealready -> "Ealready"
    Econnaborted -> "Econnaborted"
    Econnrefused -> "Econnrefused"
    Econnreset -> "Econnreset"
    Edestaddrreq -> "Edestaddrreq"
    Ehostdown -> "Ehostdown"
    Ehostunreach -> "Ehostunreach"
    Einprogress -> "Einprogress"
    Eisconn -> "Eisconn"
    Emsgsize -> "Emsgsize"
    Enetdown -> "Enetdown"
    Enetunreach -> "Enetunreach"
    Enopkg -> "Enopkg"
    Enoprotoopt -> "Enoprotoopt"
    Enotconn -> "Enotconn"
    Enotty -> "Enotty"
    Enotsock -> "Enotsock"
    Eproto -> "Eproto"
    Eprotonosupport -> "Eprotonosupport"
    Eprototype -> "Eprototype"
    Esocktnosupport -> "Esocktnosupport"
    Etimedout -> "Etimedout"
    Ewouldblock -> "Ewouldblock"
    Exbadport -> "Exbadport"
    Exbadseq -> "Exbadseq"
    Eacces -> "Eacces"
    Eagain -> "Eagain"
    Ebadf -> "Ebadf"
    Ebadmsg -> "Ebadmsg"
    Ebusy -> "Ebusy"
    Edeadlk -> "Edeadlk"
    Edeadlock -> "Edeadlock"
    Edquot -> "Edquot"
    Eexist -> "Eexist"
    Efault -> "Efault"
    Efbig -> "Efbig"
    Eftype -> "Eftype"
    Eintr -> "Eintr"
    Einval -> "Einval"
    Eio -> "Eio"
    Eisdir -> "Eisdir"
    Eloop -> "Eloop"
    Emfile -> "Emfile"
    Emlink -> "Emlink"
    Emultihop -> "Emultihop"
    Enametoolong -> "Enametoolong"
    Enfile -> "Enfile"
    Enobufs -> "Enobufs"
    Enodev -> "Enodev"
    Enolck -> "Enolck"
    Enolink -> "Enolink"
    Enoent -> "Enoent"
    Enomem -> "Enomem"
    Enospc -> "Enospc"
    Enosr -> "Enosr"
    Enostr -> "Enostr"
    Enosys -> "Enosys"
    Enotblk -> "Enotblk"
    Enotdir -> "Enotdir"
    Enotsup -> "Enotsup"
    Enxio -> "Enxio"
    Eopnotsupp -> "Eopnotsupp"
    Eoverflow -> "Eoverflow"
    Eperm -> "Eperm"
    Epipe -> "Epipe"
    Erange -> "Erange"
    Erofs -> "Erofs"
    Espipe -> "Espipe"
    Esrch -> "Esrch"
    Estale -> "Estale"
    Etxtbsy -> "Etxtbsy"
    Exdev -> "Exdev"
  }
}

pub type ListenSocket

pub type Socket

pub type SockName {
  TcpSockName(ip_address: options.IpAddress, port: Int)
  UnixSockName(path: String)
}
