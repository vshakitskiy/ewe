-module(ewe_ffi).

-export([now_datetime/0, set_http_date/1, get_http_date/0]).


now_datetime() ->
  {Date, Time} = calendar:universal_time(),
  Weekday = calendar:day_of_the_week(Date),
  {Weekday, Date, Time}.

set_http_date(Value) ->
  persistent_term:put({?MODULE, http_date}, Value).

get_http_date() ->
  case persistent_term:get({?MODULE, http_date}, undefined) of
    undefined -> {error, nil};
    Value -> {ok, Value}
  end.