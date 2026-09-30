-module(cowboy_bench_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
  Dispatch = cowboy_router:compile([{'_', [{'_', cowboy_bench_handler, []}]}]),
  {ok, _Listener} = cowboy:start_clear(bench, [{port, 3009}], #{
    env => #{dispatch => Dispatch},
    max_keepalive => infinity,
    max_received_frame_rate => {1000000000, 1000}
  }),

  SupFlags = #{strategy => one_for_one,
               intensity => 0,
               period => 1},
  {ok, {SupFlags, []}}.
