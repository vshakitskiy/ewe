-module(stream_ffi).

-export([dead/1, rescue_dead/1]).

-define(STREAM_DEAD, ewe_stream_dead).

dead(Reason) ->
  erlang:error({?STREAM_DEAD, Reason}).

%% Matches the sentinel exactly and reraises everything else with its own
%% stacktrace so a bug in a handler still crashes as a bug.
rescue_dead(Func) ->
  try
    {ok, Func()}
  catch
    error:{?STREAM_DEAD, Reason} -> {error, Reason};
    Class:Reason:Stacktrace -> erlang:raise(Class, Reason, Stacktrace)
  end.
