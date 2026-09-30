-module(yaws_bench_handler).

-export([out/1]).

-include_lib("yaws/include/yaws_api.hrl").

-define(SSE_EVENTS, 32).
-define(SMALL_COUNT, 100).
-define(BIG_COUNT, 64).

out(Arg) ->
  route((Arg#arg.req)#http_request.method, Arg#arg.server_path, Arg).

route('GET', "/hello", _Arg) ->
  {content, "text/plain", ~"Hello, Joe!"};

route('POST', "/echo", Arg) ->
  echo(Arg);
route('POST', "/echo/chunked", Arg) ->
  echo(Arg);

route('GET', "/stream", _Arg) ->
  stream("application/octet-stream", [~"hello, ", ~"Joe!"]);

route('GET', "/stream/small", _Arg) ->
  burst(yaws_bench_app:payload(small_line), ?SMALL_COUNT);
route('GET', "/stream/big", _Arg) ->
  burst(yaws_bench_app:payload(big_line), ?BIG_COUNT);

route('GET', "/sse", _Arg) ->
  sse_burst(yaws_bench_app:payload(small_line), ?SSE_EVENTS);
route('GET', "/sse/small", _Arg) ->
  sse_burst(yaws_bench_app:payload(small_line), ?SMALL_COUNT);
route('GET', "/sse/big", _Arg) ->
  sse_burst(yaws_bench_app:payload(big_line), ?BIG_COUNT);

route('GET', "/file/tiny", _Arg) ->
  {page, "/file_1kb.bin"};
route('GET', "/file/small", _Arg) ->
  {page, "/file_100kb.bin"};
route('GET', "/file/big", _Arg) ->
  {page, "/file_5mb.bin"};

route(_Method, _Path, _Arg) ->
  {status, 404}.

echo(#arg{clidata = {partial, Bytes}, state = State}) ->
  {get_more, undefined, [Bytes | pieces(State)]};
echo(#arg{clidata = Bytes, state = State}) ->
  {content, "application/octet-stream", lists:reverse([Bytes | pieces(State)])}.

pieces(undefined) -> [];
pieces(Pieces) -> Pieces.

burst(Chunk, Count) ->
  stream("application/octet-stream", lists:duplicate(Count, Chunk)).

sse_burst(Data, Count) ->
  Event = [yaws_sse:event(~"tick"), yaws_sse:data(Data), ~"\n"],
  [{header, {"Cache-Control", "no-cache"}}
   | stream("text/event-stream", lists:duplicate(Count, Event))].

stream(ContentType, [First | Rest]) ->
  YawsPid = self(),
  spawn(fun() -> deliver(YawsPid, Rest) end),
  [{streamcontent, ContentType, First}].

deliver(YawsPid, []) ->
  yaws_api:stream_chunk_end(YawsPid);
deliver(YawsPid, [Chunk | Rest]) ->
  case yaws_api:stream_chunk_deliver_blocking(YawsPid, Chunk) of
    ok -> deliver(YawsPid, Rest);
    {error, _Reason} -> ok
  end.
