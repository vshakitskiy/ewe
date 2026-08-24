-module(ewe_sse_ffi).

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
  case has_break(Bin) of
    false -> [Bin];
    true -> binary:split(Bin, break_pattern(), [global])
  end.

strip_breaks(Bin) ->
  case has_break(Bin) of
    false -> Bin;
    true -> binary:replace(Bin, break_pattern(), <<>>, [global])
  end.

break_pattern() ->
  persistent_term:get({?MODULE, break}).

has_break(Bin) ->
  binary:match(Bin, <<"\n">>) =/= nomatch orelse
    binary:match(Bin, <<"\r">>) =/= nomatch.
