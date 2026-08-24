-module(ewe_file_ffi).

-include_lib("kernel/include/file.hrl").

-export([stat/1, sendfile/4, open/1, size/1, pread/3, read_range/3, close/1]).

stat(Path) ->
  case file:read_file_info(Path, [raw, {time, posix}]) of
    {ok, #file_info{type = directory}} -> {error, is_directory};
    {ok, #file_info{size = Size}} -> {ok, Size};
    {error, enoent} -> {error, not_found};
    {error, eacces} -> {error, access_denied};
    {error, _Reason} -> {error, unknown_error}
  end.

sendfile(Fd, Socket, Offset, Bytes) ->
  try file:sendfile(Fd, Socket, Offset, Bytes, []) of
    {ok, Bytes} -> {ok, nil};
    {ok, _Short} -> {error, closed};
    {error, Reason} -> {error, Reason}
  catch
    error:{badmatch, undefined} -> {error, closed}
  end.

open(Path) ->
  case file:open(Path, [raw, binary, read]) of
    {ok, Fd} -> {ok, Fd};
    {error, enoent} -> {error, not_found};
    {error, eisdir} -> {error, is_directory};
    {error, eacces} -> {error, access_denied};
    {error, _Reason} -> {error, unknown_error}
  end.

size(Fd) ->
  case file:position(Fd, eof) of
    {ok, Size} -> {ok, Size};
    {error, _Reason} -> {error, unknown_error}
  end.

pread(Fd, Offset, Length) ->
  case file:pread(Fd, Offset, Length) of
    {ok, Data} -> {ok, Data};
    eof -> {ok, <<>>};
    {error, Reason} -> {error, Reason}
  end.

read_range(_Path, _Offset, 0) ->
  {ok, <<>>};
read_range(Path, Offset, Length) ->
  case open(Path) of
    {ok, Fd} ->
      Result =
        case file:pread(Fd, Offset, Length) of
          {ok, Data} when byte_size(Data) =:= Length -> {ok, Data};
          {ok, _Short} -> {error, unknown_error};
          eof -> {error, unknown_error};
          {error, _Reason} -> {error, unknown_error}
        end,
      file:close(Fd),
      Result;
    {error, Reason} ->
      {error, Reason}
  end.

close(Fd) ->
  file:close(Fd),
  nil.
