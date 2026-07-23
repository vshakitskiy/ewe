-module(roadrunner_bench_callback).

-behaviour(roadrunner_handler).

-export([handle/1]).

-include_lib("kernel/include/file.hrl").

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

route(~"GET", ~"/file/small", Req) ->
  send_file(Req, "../priv/file_100kb.bin");
route(~"GET", ~"/file/big", Req) ->
  send_file(Req, "../priv/file_1gb.bin");

route(_Method, _Path, Req) ->
  {roadrunner_resp:not_found(), Req}.

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
