-module(ewe_http2_client_ffi).

-export([connect/1, send/2, recv/2, close/1, write_file/2]).

write_file(Path, Data) ->
  ok = file:write_file(Path, Data),
  nil.

connect(Port) ->
  case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}, {nodelay, true}]) of
    {ok, Socket} -> {ok, Socket};
    {error, _Reason} -> {error, nil}
  end.

send(Socket, Data) ->
  case gen_tcp:send(Socket, Data) of
    ok -> {ok, nil};
    {error, _Reason} -> {error, nil}
  end.

recv(Socket, Timeout) ->
  case gen_tcp:recv(Socket, 0, Timeout) of
    {ok, Data} -> {ok, Data};
    {error, timeout} -> {error, timeout};
    {error, _Reason} -> {error, closed}
  end.

close(Socket) ->
  gen_tcp:close(Socket),
  nil.
