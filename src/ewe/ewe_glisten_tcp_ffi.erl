-module(ewe_glisten_tcp_ffi).

-export([controlling_process/2, send/2, set_opts/2, shutdown/2, close/1, sockname/1, peername/1]).

send(Socket, Packet) ->
  case gen_tcp:send(Socket, Packet) of
    ok ->
      {ok, nil};
    Res ->
      Res
  end.

set_opts(Socket, Options) ->
  case inet:setopts(Socket, Options) of
    ok ->
      {ok, nil};
    {error, _Reason} ->
      {error, nil}
  end.

controlling_process(Socket, Pid) ->
  case gen_tcp:controlling_process(Socket, Pid) of
    ok ->
      {ok, nil};
    {error, Reason} ->
      {error, Reason}
  end.

shutdown(Socket, How) ->
  case gen_tcp:shutdown(Socket, How) of
    ok ->
      {ok, nil};
    {error, Reason} ->
      {error, Reason}
  end.

close(Socket) ->
  case gen_tcp:close(Socket) of
    ok ->
      {ok, nil};
    {error, Reason} ->
      {error, Reason}
  end.

sockname(Socket) ->
  case inet:sockname(Socket) of
    {ok, {local, Path}} ->
      {ok, {unix_sock_name, Path}};
    {ok, {Ip, Port}} ->
      {ok, {tcp_sock_name, normalize_ip(Ip), Port}};
    {error, Reason} ->
      {error, Reason}
  end.

peername(Socket) ->
  case inet:peername(Socket) of
    {ok, {local, Path}} ->
      {ok, {unix_sock_name, Path}};
    {ok, {Ip, Port}} ->
      {ok, {tcp_sock_name, normalize_ip(Ip), Port}};
    {error, Reason} ->
      {error, Reason}
  end.

normalize_ip({0, 0, 0, 0, 0, 16#FFFF, AB, CD}) ->
  {ip_v4, AB bsr 8, AB band 16#FF, CD bsr 8, CD band 16#FF};
normalize_ip({A, B, C, D, E, F, G, H}) ->
  {ip_v6, A, B, C, D, E, F, G, H};
normalize_ip({A, B, C, D}) ->
  {ip_v4, A, B, C, D}.
