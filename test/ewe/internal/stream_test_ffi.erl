-module(stream_test_ffi).

-export([rescue/1]).

%% Catches every class, so a test can assert that something crashed at all.
rescue(Func) ->
  try
    {ok, Func()}
  catch
    _Class:_Reason -> {error, nil}
  end.
