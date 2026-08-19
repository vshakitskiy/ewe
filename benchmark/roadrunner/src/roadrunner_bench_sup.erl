-module(roadrunner_bench_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
  {ok, _Http1} = roadrunner:start_listener(bench_http1, listener_opts(3007, #{})),
  {ok, _Http2} = roadrunner:start_listener(bench_http2,
                                           listener_opts(3008, #{protocols => [http2]})),

  SupFlags = #{strategy => one_for_one,
               intensity => 0,
               period => 1},
  {ok, {SupFlags, []}}.

listener_opts(Port, Extra) ->
  maps:merge(#{
    port => Port,
    body_buffering => manual,
    routes => [
      {~"/hello", roadrunner_bench_callback, undefined},
      {~"/echo", roadrunner_bench_callback, undefined},
      {~"/echo/chunked", roadrunner_bench_callback, undefined},
      {~"/stream", roadrunner_bench_callback, undefined},
      {~"/stream/small", roadrunner_bench_callback, undefined},
      {~"/stream/big", roadrunner_bench_callback, undefined},
      {~"/sse", roadrunner_bench_callback, undefined},
      {~"/sse/small", roadrunner_bench_callback, undefined},
      {~"/sse/big", roadrunner_bench_callback, undefined},
      {~"/file/tiny", roadrunner_bench_callback, undefined},
      {~"/file/small", roadrunner_bench_callback, undefined},
      {~"/file/big", roadrunner_bench_callback, undefined}
    ]
  }, Extra).
