-module(elli_bench_callback).

-behaviour(elli_handler).

-export([handle/2, handle_event/3]).

-include_lib("elli/include/elli.hrl").

-define(SSE_EVENTS, 32).

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

%% elli has no SSE API, so the stream is plain chunked writes carrying the
%% event framing.
handle('GET', [<<"sse">>], Req) ->
  Ref = elli_request:chunk_ref(Req),
  spawn(fun() -> start_events(Ref) end),
  {chunk, [{<<"Content-Type">>, <<"text/event-stream">>},
           {<<"Cache-Control">>, <<"no-cache">>}]};

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

start_events(Ref) ->
  self() ! {sse_tick, 1},
  stream_events(Ref).

stream_events(Ref) ->
  receive
    {sse_tick, N} when N > ?SSE_EVENTS ->
      elli_request:close_chunk(Ref);
    {sse_tick, N} ->
      case elli_request:send_chunk(Ref, sse_event(N)) of
        ok ->
          self() ! {sse_tick, N + 1},
          stream_events(Ref);
        {error, _Reason} ->
          ok
      end
  end.

sse_event(N) ->
  Id = integer_to_binary(N),
  <<"event: tick\nid: ", Id/binary,
    "\ndata: {\"n\":", Id/binary, ",\"at\":\"benchmark\"}\n\n">>.

handle_event(_Event, _Args, _Config) ->
  ok.
