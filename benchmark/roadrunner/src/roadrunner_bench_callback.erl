-module(roadrunner_bench_callback).

-behaviour(roadrunner_handler).

-export([handle/1]).

-include_lib("kernel/include/file.hrl").

-define(SSE_EVENTS, 32).
-define(SMALL_COUNT, 100).
-define(BIG_COUNT, 64).

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

route(~"GET", ~"/stream/small", Req) ->
  {burst(roadrunner_bench_app:payload(small_chunk), ?SMALL_COUNT), Req};
route(~"GET", ~"/stream/big", Req) ->
  {burst(roadrunner_bench_app:payload(big_chunk), ?BIG_COUNT), Req};

route(~"GET", ~"/sse", Req) ->
  {sse_burst(roadrunner_bench_app:payload(small_line), ?SSE_EVENTS), Req};
route(~"GET", ~"/sse/small", Req) ->
  {sse_burst(roadrunner_bench_app:payload(small_line), ?SMALL_COUNT), Req};
route(~"GET", ~"/sse/big", Req) ->
  {sse_burst(roadrunner_bench_app:payload(big_line), ?BIG_COUNT), Req};

route(~"GET", ~"/file/tiny", Req) ->
  send_file(Req, "../priv/file_1kb.bin");
route(~"GET", ~"/file/small", Req) ->
  send_file(Req, "../priv/file_100kb.bin");
route(~"GET", ~"/file/big", Req) ->
  send_file(Req, "../priv/file_5mb.bin");

route(_Method, _Path, Req) ->
  {roadrunner_resp:not_found(), Req}.

sse_headers() ->
  [{~"content-type", ~"text/event-stream"}, {~"cache-control", ~"no-cache"}].

burst(Chunk, Count) ->
  {stream, 200, [], fun(Send) -> send_burst(Send, Chunk, Count) end}.

send_burst(Send, Chunk, 1) ->
  Send(Chunk, fin);
send_burst(Send, Chunk, Remaining) ->
  Send(Chunk, nofin),
  send_burst(Send, Chunk, Remaining - 1).

sse_burst(Data, Count) ->
  {stream, 200, sse_headers(), fun(Send) -> send_events(Send, Data, Count) end}.

send_events(Send, Data, 1) ->
  Send(roadrunner_sse:event(~"tick", Data), fin);
send_events(Send, Data, Remaining) ->
  Send(roadrunner_sse:event(~"tick", Data), nofin),
  send_events(Send, Data, Remaining - 1).

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
