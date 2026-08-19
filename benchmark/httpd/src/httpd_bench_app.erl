-module(httpd_bench_app).

-behaviour(application).

-export([start/2, stop/1, payload/1]).

-define(SMALL_LINE, <<"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef">>).
-define(BIG_REPEATS, 256).

start(_StartType, _StartArgs) ->
  BigLine = binary:copy(?SMALL_LINE, ?BIG_REPEATS),
  put_payload(small_chunk, ?SMALL_LINE),
  put_payload(big_chunk, BigLine),
  httpd_bench_sup:start_link().

stop(_State) ->
  ok.

put_payload(Key, Value) ->
  persistent_term:put({?MODULE, Key}, Value).

payload(Key) ->
  persistent_term:get({?MODULE, Key}).
