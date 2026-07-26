-module(sse_ffi).

-on_load(init/0).
-export([
    init/0,
    split_breaks/1,
    strip_breaks/1
]).

init() ->
  persistent_term:put(
    {?MODULE, break},
    binary:compile_pattern([<<"\r\n">>, <<"\r">>, <<"\n">>])
  ),
  ok.

split_breaks(Bin) ->
  binary:split(Bin, persistent_term:get({?MODULE, break}), [global]).

strip_breaks(Bin) ->
  binary:replace(Bin, persistent_term:get({?MODULE, break}), <<>>, [global]).
