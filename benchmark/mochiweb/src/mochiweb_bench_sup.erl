-module(mochiweb_bench_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
  SupFlags = #{strategy => one_for_one,
               intensity => 0,
               period => 1},
  Options = [{port, 3010},
             {nodelay, true},
             {loop, fun mochiweb_bench_handler:loop/1}],
  ChildSpecs = [#{id => mochiweb_bench,
                  start => {mochiweb_http, start_link, [Options]},
                  restart => permanent,
                  shutdown => 5000,
                  type => worker,
                  modules => [mochiweb_http]}],
  {ok, {SupFlags, ChildSpecs}}.
