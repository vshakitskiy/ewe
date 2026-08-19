-module(elli_bench_sup).

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
  ChildSpecs = [#{id => elli_bench,
                  start => {elli, start_link,
                            [[{callback, elli_bench_callback},
                              {callback_args, []},
                              {port, 3003}]]},
                  restart => permanent,
                  shutdown => 5000,
                  type => worker,
                  modules => [elli]}],
  {ok, {SupFlags, ChildSpecs}}.
