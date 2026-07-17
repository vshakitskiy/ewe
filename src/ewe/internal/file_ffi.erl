-module(file_ffi).

-include_lib("kernel/include/file.hrl").

-export([stat/1, sendfile/4, open/1, pread/3, close/1]).

stat(Path) ->
  case file:read_file_info(Path, [raw, {time, posix}]) of
    {ok, #file_info{type = directory}} -> {error, is_directory};
    {ok, #file_info{size = Size}} -> {ok, Size};
    {error, enoent} -> {error, not_found};
    {error, eacces} -> {error, access_denied};
    {error, _Reason} -> {error, unknown_error}
  end.

%% the kernel streams the file straight to the socket without passing through
%% userspace memory.
sendfile(Fd, Socket, Offset, Bytes) ->
  case file:sendfile(Fd, Socket, Offset, Bytes, []) of
    {ok, _Sent} -> {ok, nil};
    {error, Reason} -> {error, Reason}
  end.

open(Path) ->
  file:open(Path, [raw, binary, read]).

pread(Fd, Offset, Length) ->
  case file:pread(Fd, Offset, Length) of
    {ok, Data} -> {ok, Data};
    eof -> {ok, <<>>};
    {error, Reason} -> {error, Reason}
  end.

close(Fd) ->
  file:close(Fd),
  nil.
