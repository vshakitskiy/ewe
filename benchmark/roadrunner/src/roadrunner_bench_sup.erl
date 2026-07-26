-module(roadrunner_bench_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
  {ok, _Pid} = roadrunner:start_listener(bench_listener, #{
    port => 3007,
    body_buffering => manual,
    routes => [
      {~"/hello", roadrunner_bench_callback, undefined},
      {~"/echo", roadrunner_bench_callback, undefined},
      {~"/echo/chunked", roadrunner_bench_callback, undefined},
      {~"/stream", roadrunner_bench_callback, undefined},
      {~"/sse", roadrunner_bench_callback, undefined},
      {~"/file/small", roadrunner_bench_callback, undefined},
      {~"/file/big", roadrunner_bench_callback, undefined}
    ]
  }),

  SupFlags = #{strategy => one_for_one,
               intensity => 0,
               period => 1},
  {ok, {SupFlags, []}}.
