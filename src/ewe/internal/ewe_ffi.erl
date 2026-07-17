-module(ewe_ffi).

-export([now_datetime/0, set_http_date/1, get_http_date/0]).

now_datetime() ->
  {Date, Time} = calendar:universal_time(),
  Weekday = calendar:day_of_the_week(Date),
  {Weekday, Date, Time}.

set_http_date(Value) ->
  ensure_http_date_table(),
  ets:insert(?MODULE, {http_date, Value}),
  ok.

get_http_date() ->
  try ets:lookup(?MODULE, http_date) of
    [{http_date, Value}] -> {ok, Value};
    [] -> {error, nil}
  catch
    error:badarg -> {error, nil}
  end.

ensure_http_date_table() ->
  case ets:info(?MODULE) of
    undefined ->
      try
        ets:new(?MODULE, [set, public, named_table, {read_concurrency, true}])
      catch
        error:badarg -> ?MODULE
      end;
    _ ->
      ?MODULE
  end.
