-module(mochiweb_bench_handler).

-export([loop/1]).

-define(SMALL_COUNT, 100).
-define(BIG_COUNT, 64).
-define(MAX_BODY, 10000000).
-define(CHUNK_BYTES, 4096).

loop(Req) ->
  route(mochiweb_request:get(method, Req), mochiweb_request:get(path, Req), Req).

route('GET', "/hello", Req) ->
  mochiweb_request:ok({"text/plain", ~"Hello, Joe!"}, Req);

route('POST', "/echo", Req) ->
  Body = mochiweb_request:recv_body(?MAX_BODY, Req),
  mochiweb_request:respond({200, [], Body}, Req);

route('POST', "/echo/chunked", Req) ->
  Body = mochiweb_request:stream_body(?CHUNK_BYTES, fun collect/2, [], Req),
  mochiweb_request:respond({200, [], Body}, Req);

route('GET', "/stream", Req) ->
  Resp = mochiweb_request:respond({200, [], chunked}, Req),
  mochiweb_response:write_chunk(~"hello, ", Resp),
  mochiweb_response:write_chunk(~"Joe!", Resp),
  mochiweb_response:write_chunk(~"", Resp);

route('GET', "/stream/small", Req) ->
  burst(Req, mochiweb_bench_app:payload(small_chunk), ?SMALL_COUNT);
route('GET', "/stream/big", Req) ->
  burst(Req, mochiweb_bench_app:payload(big_chunk), ?BIG_COUNT);

route('GET', "/file/tiny", Req) ->
  send_file(Req, "../priv/file_1kb.bin");
route('GET', "/file/small", Req) ->
  send_file(Req, "../priv/file_100kb.bin");
route('GET', "/file/big", Req) ->
  send_file(Req, "../priv/file_5mb.bin");

route(_Method, _Path, Req) ->
  mochiweb_request:not_found(Req).

collect({0, _Footers}, Acc) ->
  lists:reverse(Acc);
collect({_Length, Bytes}, Acc) ->
  [Bytes | Acc].

burst(Req, Chunk, Count) ->
  Resp = mochiweb_request:respond({200, [], chunked}, Req),
  send_burst(Resp, Chunk, Count).

send_burst(Resp, _Chunk, 0) ->
  mochiweb_response:write_chunk(~"", Resp);
send_burst(Resp, Chunk, Remaining) ->
  mochiweb_response:write_chunk(Chunk, Resp),
  send_burst(Resp, Chunk, Remaining - 1).

send_file(Req, Path) ->
  case file:open(Path, [read, raw, binary]) of
    {ok, File} ->
      Headers = [{"Content-Type", "application/octet-stream"}],
      mochiweb_request:respond({200, Headers, {file, File}}, Req),
      file:close(File);
    {error, _Reason} ->
      mochiweb_request:not_found(Req)
  end.
