-module(ewe_ffi).

-export([
    identity/1,
    now_datetime/0,
    set_http_date/1,
    get_http_date/0,
    rescue_handler/1,
    is_valid_utf8/1
]).

-define(HIGH_BITS, 16#80808080808080).

identity(X) ->
  X.

rescue_handler(Func) ->
  try
    {ok, Func()}
  catch
    Class:Reason:Stacktrace ->
      Formatted = erl_error:format_exception(Class, Reason, Stacktrace),
      {error, unicode:characters_to_binary(Formatted)}
  end.

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

is_valid_utf8(Bin) when is_binary(Bin) ->
  case skip_ascii(Bin) of
    <<>> -> true;
    Rest -> is_binary(unicode:characters_to_binary(Rest, utf8))
  end;
is_valid_utf8(_Bits) ->
  false.

%% Tests seven bytes per word rather than eight since 56 bits is the widest that
%% still fits an immediate integer on a 64-bit VM so no word allocates.
skip_ascii(<<A:56, B:56, C:56, D:56, Rest/binary>>) when
    A band ?HIGH_BITS =:= 0,
    B band ?HIGH_BITS =:= 0,
    C band ?HIGH_BITS =:= 0,
    D band ?HIGH_BITS =:= 0
->
  skip_ascii(Rest);
skip_ascii(<<Word:56, Rest/binary>>) when Word band ?HIGH_BITS =:= 0 ->
  skip_ascii(Rest);
%% Tails shorter than a word, each masked to its own width.
skip_ascii(<<Word:48>>) when Word band 16#808080808080 =:= 0 -> <<>>;
skip_ascii(<<Word:40>>) when Word band 16#8080808080 =:= 0 -> <<>>;
skip_ascii(<<Word:32>>) when Word band 16#80808080 =:= 0 -> <<>>;
skip_ascii(<<Word:24>>) when Word band 16#808080 =:= 0 -> <<>>;
skip_ascii(<<Word:16>>) when Word band 16#8080 =:= 0 -> <<>>;
skip_ascii(<<Word:8>>) when Word band 16#80 =:= 0 -> <<>>;
skip_ascii(Rest) ->
  Rest.
