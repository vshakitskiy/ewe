-module(ewe_ffi).

-include_lib("kernel/include/file.hrl").

-on_load(init/0).
-export([
    init/0,

    identity/1,
    rescue_handler/1,
    parent_pid/0,
    exit_self/1,
    monotonic_ms/0,
    message_queue_length/0,
    queue_pop/1,
    is_valid_utf8/1,

    now_datetime/0,
    set_http_date/1,
    get_http_date/0,

    file_stat/1,
    file_open/1,
    file_size/1,
    file_read/3,
    file_read_range/3,
    file_close/1,
    sendfile/4,

    socket_payload/1,
    socket_error_reason/1,

    find_lf/1,
    find_colon/1,
    find_space/1,
    find_question/1,
    find_close_bracket/1,
    find_authority_end/1,
    find_unsafe_header_byte/1,
    split_comma/1,
    lowercase_ascii/1,
    bit_array_to_string/1,

    is_field_name/1,
    is_field_value/1,
    has_userinfo/1,
    split_query/1,
    is_shutdown/1,
    recv_or_exit/1,
    recv_or_exit/2,

    split_breaks/1,
    strip_breaks/1
]).

-define(HIGH_BITS, 16#80808080808080).
-define(IS_WHITESPACE(Byte), (Byte =:= $\s orelse Byte =:= $\t)).

init() ->
  pattern(lf, <<"\n">>),
  pattern(colon, <<":">>),
  pattern(space, <<" ">>),
  pattern(question, <<"?">>),
  pattern(comma, <<",">>),
  pattern(close_bracket, <<"]">>),
  pattern(authority_end, [<<"/">>, <<"?">>]),
  pattern(at, <<"@">>),
  pattern(upper, [<<Byte>> || Byte <- lists:seq($A, $Z)]),
  pattern(unsafe_header, [<<"\r">>, <<"\n">>, <<0>>]),
  pattern(field_value, [<<0>>, <<"\n">>, <<"\r">>]),
  pattern(
    field_name,
    [<<Byte>> || Byte <- lists:seq(16#00, 16#20) ++ lists:seq($A, $Z) ++ [$:]
                         ++ lists:seq(16#7f, 16#ff)]
  ),
  pattern(break, [<<"\r\n">>, <<"\r">>, <<"\n">>]),
  ok.

pattern(Key, Pattern) ->
  persistent_term:put({?MODULE, Key}, binary:compile_pattern(Pattern)).

pattern(Key) ->
  persistent_term:get({?MODULE, Key}).

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

parent_pid() ->
  case erlang:process_info(self(), parent) of
    {parent, Pid} when is_pid(Pid) -> {ok, Pid};
    _Other -> {error, nil}
  end.

exit_self(Reason) ->
  erlang:exit(Reason).

monotonic_ms() ->
  erlang:monotonic_time(millisecond).

message_queue_length() ->
  {message_queue_len, Length} = erlang:process_info(self(), message_queue_len),
  Length.

queue_pop(Queue) ->
  case queue:out(Queue) of
    {{value, Item}, Rest} -> {ok, {Item, Rest}};
    {empty, _Queue} -> {error, nil}
  end.

is_valid_utf8(Bin) when is_binary(Bin) ->
  case skip_ascii(Bin) of
    <<>> -> true;
    Rest -> is_binary(unicode:characters_to_binary(Rest, utf8))
  end;
is_valid_utf8(_Bits) ->
  false.

skip_ascii(<<A:56, B:56, C:56, D:56, Rest/binary>>) when
    A band ?HIGH_BITS =:= 0,
    B band ?HIGH_BITS =:= 0,
    C band ?HIGH_BITS =:= 0,
    D band ?HIGH_BITS =:= 0
->
  skip_ascii(Rest);
skip_ascii(<<Word:56, Rest/binary>>) when Word band ?HIGH_BITS =:= 0 ->
  skip_ascii(Rest);
skip_ascii(<<Word:48>>) when Word band 16#808080808080 =:= 0 -> <<>>;
skip_ascii(<<Word:40>>) when Word band 16#8080808080 =:= 0 -> <<>>;
skip_ascii(<<Word:32>>) when Word band 16#80808080 =:= 0 -> <<>>;
skip_ascii(<<Word:24>>) when Word band 16#808080 =:= 0 -> <<>>;
skip_ascii(<<Word:16>>) when Word band 16#8080 =:= 0 -> <<>>;
skip_ascii(<<Word:8>>) when Word band 16#80 =:= 0 -> <<>>;
skip_ascii(Rest) ->
  Rest.

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

file_stat(Path) ->
  case file:read_file_info(Path, [raw, {time, posix}]) of
    {ok, #file_info{type = directory}} -> {error, is_directory};
    {ok, #file_info{size = Size}} -> {ok, Size};
    {error, enoent} -> {error, not_found};
    {error, eacces} -> {error, access_denied};
    {error, _Reason} -> {error, unknown_error}
  end.

file_open(Path) ->
  case file:open(Path, [raw, binary, read]) of
    {ok, Fd} -> {ok, Fd};
    {error, enoent} -> {error, not_found};
    {error, eisdir} -> {error, is_directory};
    {error, eacces} -> {error, access_denied};
    {error, _Reason} -> {error, unknown_error}
  end.

file_size(Fd) ->
  case file:position(Fd, eof) of
    {ok, Size} -> {ok, Size};
    {error, _Reason} -> {error, unknown_error}
  end.

file_read(_Fd, _Offset, 0) ->
  {ok, <<>>};
file_read(Fd, Offset, Length) ->
  case file:pread(Fd, Offset, Length) of
    {ok, Data} when byte_size(Data) =:= Length -> {ok, Data};
    {ok, _Short} -> {error, unknown_error};
    eof -> {error, unknown_error};
    {error, _Reason} -> {error, unknown_error}
  end.

file_read_range(_Path, _Offset, 0) ->
  {ok, <<>>};
file_read_range(Path, Offset, Length) ->
  case file_open(Path) of
    {ok, Fd} ->
      Result = file_read(Fd, Offset, Length),
      file:close(Fd),
      Result;
    {error, Reason} ->
      {error, Reason}
  end.

file_close(Fd) ->
  file:close(Fd),
  nil.

sendfile(Fd, Socket, Offset, Bytes) ->
  try file:sendfile(Fd, Socket, Offset, Bytes, []) of
    {ok, Bytes} -> {ok, nil};
    {ok, _Short} -> {error, closed};
    {error, Reason} -> {error, tup_socket_ffi:reason(Reason)}
  catch
    error:{badmatch, undefined} -> {error, closed}
  end.

socket_payload({_Tag, _Socket, Data}) ->
  Data.

socket_error_reason({_Tag, _Socket, Reason}) ->
  tup_socket_ffi:reason(Reason).

find_lf(Bin) -> find(Bin, lf).
find_colon(Bin) -> find(Bin, colon).
find_space(Bin) -> find(Bin, space).
find_question(Bin) -> find(Bin, question).
find_close_bracket(Bin) -> find(Bin, close_bracket).
find_authority_end(Bin) -> find(Bin, authority_end).
find_unsafe_header_byte(Bin) -> find(Bin, unsafe_header).

find(Bin, Key) ->
  case binary:match(Bin, pattern(Key)) of
    nomatch -> {error, nil};
    {Pos, _Len} -> {ok, Pos}
  end.

split_comma(Bin) ->
  binary:split(Bin, pattern(comma), [global]).

lowercase_ascii(Bin) ->
  case binary:match(Bin, pattern(upper)) of
    nomatch -> Bin;
    _Match -> << <<(lower(Byte))>> || <<Byte>> <= Bin >>
  end.

lower(Byte) when Byte >= $A, Byte =< $Z -> Byte + 32;
lower(Byte) -> Byte.

bit_array_to_string(Bin) ->
  case is_valid_utf8(Bin) of
    true -> {ok, Bin};
    false -> {error, nil}
  end.

is_field_name(<<>>) ->
  false;
is_field_name(Name) ->
  binary:match(Name, pattern(field_name)) =:= nomatch.

is_field_value(<<>>) ->
  true;
is_field_value(<<First, _/binary>> = Value) when not ?IS_WHITESPACE(First) ->
  Last = binary:last(Value),
  not ?IS_WHITESPACE(Last)
    andalso binary:match(Value, pattern(field_value)) =:= nomatch
    andalso is_valid_utf8(Value);
is_field_value(_Value) ->
  false.

has_userinfo(Authority) ->
  binary:match(Authority, pattern(at)) =/= nomatch.

split_query(Path) ->
  case binary:split(Path, pattern(question)) of
    [Before, After] -> {ok, {Before, After}};
    _Parts -> {error, nil}
  end.

is_shutdown(shutdown) -> true;
is_shutdown(_Reason) -> false.

recv_or_exit(Ref) ->
  recv_or_exit(Ref, infinity).

recv_or_exit(Ref, Timeout) ->
  {ok, Connection} = parent_pid(),
  receive
    {Ref, Message} -> {ok, Message};
    {'EXIT', Connection, Reason} = Exit ->
      self() ! Exit,
      {error, classify_exit(Reason)}
  after Timeout ->
    {error, timed_out}
  end.

classify_exit(<<"stream_reset">>) -> stream_reset;
classify_exit(_Reason) -> connection_closed.

split_breaks(Bin) ->
  case has_break(Bin) of
    false -> [Bin];
    true -> binary:split(Bin, pattern(break), [global])
  end.

strip_breaks(Bin) ->
  case has_break(Bin) of
    false -> Bin;
    true -> binary:replace(Bin, pattern(break), <<>>, [global])
  end.

has_break(Bin) ->
  binary:match(Bin, <<"\n">>) =/= nomatch orelse
    binary:match(Bin, <<"\r">>) =/= nomatch.
