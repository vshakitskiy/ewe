-module(roadrunner_bench_callback).

-behaviour(roadrunner_handler).

-export([handle/1]).

-include_lib("kernel/include/file.hrl").

-define(SSE_EVENTS, 32).

handle(Req) ->
  route(roadrunner_req:method(Req), roadrunner_req:path(Req), Req).

route(~"GET", ~"/hello", Req) ->
  {roadrunner_resp:text(200, ~"Hello, Joe!"), Req};

route(~"POST", ~"/echo", Req) ->
  {ok, Body, Req2} = roadrunner_req:read_body(Req),
  {roadrunner_resp:text(200, Body), Req2};

route(~"POST", ~"/echo/chunked", Req) ->
  {Body, Req2} = read_all_chunks(Req, []),
  {roadrunner_resp:text(200, Body), Req2};

route(~"GET", ~"/stream", Req) ->
  Resp = {stream, 200, [], fun(Send) ->
    Send(~"hello, ", nofin),
    Send(~"Joe!", fin)
  end},
  {Resp, Req};

route(~"GET", ~"/sse", Req) ->
  Headers = [
    {~"content-type", ~"text/event-stream"},
    {~"cache-control", ~"no-cache"}
  ],
  Resp = {stream, 200, Headers, fun(Send) -> start_sse(Send) end},
  {Resp, Req};

route(~"GET", ~"/file/small", Req) ->
  send_file(Req, "../priv/file_100kb.bin");
route(~"GET", ~"/file/big", Req) ->
  send_file(Req, "../priv/file_1gb.bin");

route(_Method, _Path, Req) ->
  {roadrunner_resp:not_found(), Req}.

start_sse(Send) ->
  self() ! {sse_tick, 1},
  send_sse(Send).

send_sse(Send) ->
  receive
    {sse_tick, N} when N >= ?SSE_EVENTS ->
      Send(sse_event(N), fin);
    {sse_tick, N} ->
      Send(sse_event(N), nofin),
      self() ! {sse_tick, N + 1},
      send_sse(Send)
  end.

sse_event(N) ->
  Id = integer_to_binary(N),
  Data = <<"{\"n\":", Id/binary, ",\"at\":\"benchmark\"}">>,
  iolist_to_binary(roadrunner_sse:event(~"tick", Data, Id)).

read_all_chunks(Req, Acc) ->
  case roadrunner_req:read_body_chunked(Req) of
    {more, Bytes, Req2} -> read_all_chunks(Req2, [Bytes | Acc]);
    {ok, Bytes, Req2} -> {lists:reverse([Bytes | Acc]), Req2}
  end.

send_file(Req, Path) ->
  case file:read_file_info(Path) of
    {ok, #file_info{size = Size}} ->
      Headers = [
        {~"content-type", ~"application/octet-stream"},
        {~"content-length", integer_to_binary(Size)}
      ],
      {{sendfile, 200, Headers, {Path, 0, Size}}, Req};
    {error, _Reason} ->
      {roadrunner_resp:not_found(), Req}
  end.
