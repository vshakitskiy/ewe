-module(elli_bench_callback).

-behaviour(elli_handler).

-export([handle/2, handle_event/3]).

-include_lib("elli/include/elli.hrl").

-define(SMALL_COUNT, 100).
-define(BIG_COUNT, 64).

handle(Req, _Args) ->
  elli_tcp:setopts(Req#req.socket, [{nodelay, true}]),
  handle(Req#req.method, elli_request:path(Req), Req).

handle('GET', [<<"hello">>], _Req) ->
  {ok, [], <<"Hello, Joe!">>};

handle('POST', [<<"echo">>], Req) ->
  {ok, [], elli_request:body(Req)};

handle('GET', [<<"stream">>], Req) ->
  Ref = elli_request:chunk_ref(Req),
  spawn(fun() -> stream_hello(Ref) end),
  {chunk, []};

handle('GET', [<<"stream">>, <<"small">>], Req) ->
  burst(Req, elli_bench_app:payload(small_chunk), ?SMALL_COUNT);
handle('GET', [<<"stream">>, <<"big">>], Req) ->
  burst(Req, elli_bench_app:payload(big_chunk), ?BIG_COUNT);

handle('GET', [<<"file">>, <<"tiny">>], _Req) ->
  {ok, [{<<"Content-Type">>, <<"application/octet-stream">>}],
   {file, "../priv/file_1kb.bin"}};
handle('GET', [<<"file">>, <<"small">>], _Req) ->
  {ok, [{<<"Content-Type">>, <<"application/octet-stream">>}],
   {file, "../priv/file_100kb.bin"}};
handle('GET', [<<"file">>, <<"big">>], _Req) ->
  {ok, [{<<"Content-Type">>, <<"application/octet-stream">>}],
   {file, "../priv/file_5mb.bin"}};

handle(_Method, _Path, _Req) ->
  {404, [], <<>>}.

burst(Req, Chunk, Count) ->
  Ref = elli_request:chunk_ref(Req),
  spawn(fun() -> send_burst(Ref, Chunk, Count) end),
  {chunk, []}.

send_burst(Ref, _Chunk, 0) ->
  elli_request:close_chunk(Ref);
send_burst(Ref, Chunk, Remaining) ->
  case elli_request:send_chunk(Ref, Chunk) of
    ok -> send_burst(Ref, Chunk, Remaining - 1);
    {error, _Reason} -> ok
  end.

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
