-module(elli_bench_callback).

-behaviour(elli_handler).

-export([handle/2, handle_event/3]).

-include_lib("elli/include/elli.hrl").

%% elli never sets TCP_NODELAY on accepted sockets, so multi write responses 
%% (well chunked in particular) eat a Nagle and delayed-ACK stall between each 
%% write.
handle(Req, _Args) ->
  elli_tcp:setopts(Req#req.socket, [{nodelay, true}]),
  handle(Req#req.method, elli_request:path(Req), Req).

handle('GET', [<<"hello">>], _Req) ->
  {ok, [], <<"Hello, Joe!">>};

%% elli reads the full request body before calling the handler, so there is
%% no incremental and chunked read to distinguish from a plain echo.
handle('POST', [<<"echo">>], Req) ->
  {ok, [], elli_request:body(Req)};

handle('GET', [<<"stream">>], Req) ->
  Ref = elli_request:chunk_ref(Req),
  spawn(fun() -> stream_hello(Ref) end),
  {chunk, []};

handle('GET', [<<"file">>, <<"small">>], _Req) ->
  {ok, [{<<"Content-Type">>, <<"application/octet-stream">>}],
   {file, "../priv/file_100kb.bin"}};
handle('GET', [<<"file">>, <<"big">>], _Req) ->
  {ok, [{<<"Content-Type">>, <<"application/octet-stream">>}],
   {file, "../priv/file_1gb.bin"}};

handle(_Method, _Path, _Req) ->
  {404, [], <<>>}.

stream_hello(Ref) ->
  case elli_request:send_chunk(Ref, <<"hello, ">>) of
    ok ->
      case elli_request:send_chunk(Ref, <<"Joe!">>) of
        ok -> elli_request:close_chunk(Ref);
        {error, _reason} -> ok
      end;
    {error, _reason} -> ok
  end.

handle_event(_Event, _Args, _Config) ->
  ok.
