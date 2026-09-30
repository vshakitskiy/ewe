-module(cowboy_bench_handler).

-behaviour(cowboy_handler).

-export([init/2]).

-include_lib("kernel/include/file.hrl").

-define(SSE_EVENTS, 32).
-define(SMALL_COUNT, 100).
-define(BIG_COUNT, 64).
-define(MAX_BODY, 10000000).
-define(CHUNK_BYTES, 4096).

init(Req, State) ->
  {ok, route(cowboy_req:method(Req), cowboy_req:path(Req), Req), State}.

route(~"GET", ~"/hello", Req) ->
  cowboy_req:reply(200, #{~"content-type" => ~"text/plain"}, ~"Hello, Joe!", Req);

route(~"POST", ~"/echo", Req) ->
  {ok, Body, Req2} = cowboy_req:read_body(Req, #{length => ?MAX_BODY}),
  cowboy_req:reply(200, #{}, Body, Req2);

route(~"POST", ~"/echo/chunked", Req) ->
  {Body, Req2} = read_all_chunks(Req, []),
  cowboy_req:reply(200, #{}, Body, Req2);

route(~"GET", ~"/stream", Req) ->
  Req2 = cowboy_req:stream_reply(200, Req),
  cowboy_req:stream_body(~"hello, ", nofin, Req2),
  cowboy_req:stream_body(~"Joe!", fin, Req2),
  Req2;

route(~"GET", ~"/stream/small", Req) ->
  burst(Req, cowboy_bench_app:payload(small_line), ?SMALL_COUNT);
route(~"GET", ~"/stream/big", Req) ->
  burst(Req, cowboy_bench_app:payload(big_line), ?BIG_COUNT);

route(~"GET", ~"/sse", Req) ->
  sse_burst(Req, cowboy_bench_app:payload(small_line), ?SSE_EVENTS);
route(~"GET", ~"/sse/small", Req) ->
  sse_burst(Req, cowboy_bench_app:payload(small_line), ?SMALL_COUNT);
route(~"GET", ~"/sse/big", Req) ->
  sse_burst(Req, cowboy_bench_app:payload(big_line), ?BIG_COUNT);

route(~"GET", ~"/file/tiny", Req) ->
  send_file(Req, "../priv/file_1kb.bin");
route(~"GET", ~"/file/small", Req) ->
  send_file(Req, "../priv/file_100kb.bin");
route(~"GET", ~"/file/big", Req) ->
  send_file(Req, "../priv/file_5mb.bin");

route(_Method, _Path, Req) ->
  cowboy_req:reply(404, Req).

burst(Req, Chunk, Count) ->
  Req2 = cowboy_req:stream_reply(200, Req),
  send_burst(Req2, Chunk, Count),
  Req2.

send_burst(Req, Chunk, 1) ->
  cowboy_req:stream_body(Chunk, fin, Req);
send_burst(Req, Chunk, Remaining) ->
  cowboy_req:stream_body(Chunk, nofin, Req),
  send_burst(Req, Chunk, Remaining - 1).

sse_burst(Req, Data, Count) ->
  Headers = #{~"content-type" => ~"text/event-stream", ~"cache-control" => ~"no-cache"},
  Req2 = cowboy_req:stream_reply(200, Headers, Req),
  send_events(Req2, Data, Count),
  Req2.

send_events(Req, Data, 1) ->
  cowboy_req:stream_events(#{event => ~"tick", data => Data}, fin, Req);
send_events(Req, Data, Remaining) ->
  cowboy_req:stream_events(#{event => ~"tick", data => Data}, nofin, Req),
  send_events(Req, Data, Remaining - 1).

read_all_chunks(Req, Acc) ->
  case cowboy_req:read_body(Req, #{length => ?CHUNK_BYTES}) of
    {more, Bytes, Req2} -> read_all_chunks(Req2, [Bytes | Acc]);
    {ok, Bytes, Req2} -> {lists:reverse([Bytes | Acc]), Req2}
  end.

send_file(Req, Path) ->
  case file:read_file_info(Path) of
    {ok, #file_info{size = Size}} ->
      Headers = #{~"content-type" => ~"application/octet-stream"},
      cowboy_req:reply(200, Headers, {sendfile, 0, Size, Path}, Req);
    {error, _Reason} ->
      cowboy_req:reply(404, Req)
  end.
