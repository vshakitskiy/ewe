-module(httpd_bench_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
  Root = filename:absname("."),
  Config = [
    {port, 3005},
    {server_name, "httpd_bench"},
    {server_root, Root},
    {document_root, filename:join(Root, "www")},
    {modules, [httpd_bench_callback, mod_get]}
  ],
  SupFlags = #{strategy => one_for_one,
               intensity => 0,
               period => 1},
  ChildSpecs = [#{id => httpd_bench,
                  start => {httpd, start_standalone, [Config]},
                  restart => permanent,
                  shutdown => 5000,
                  type => worker,
                  modules => [httpd]}],
  {ok, {SupFlags, ChildSpecs}}.
