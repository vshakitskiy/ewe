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
    split_line/2,
    header_field/1,
    trim_whitespace/1,
    has_userinfo/1,
    split_query/1,
    is_shutdown/1,
    recv_or_exit/1,
    recv_or_exit/2,

    split_breaks/1,
    strip_breaks/1
]).

-define(HIGH_BITS, 16#80808080808080).
-define(LOW_BITS, 16#01010101010101).
-define(IS_WHITESPACE(Byte), (Byte =:= $\s orelse Byte =:= $\t)).

-define(HAS_LESS(W, Limit), (((W) - (Limit) * ?LOW_BITS) band (bnot (W)) band ?HIGH_BITS)).

-define(HAS_BYTE(W, Byte), ?HAS_LESS((W) bxor ((Byte) * ?LOW_BITS), 1)).

-define(IS_NAME_BYTE(Byte), (Byte > $\s andalso Byte < 16#7f andalso Byte =/= $:)).

-define(LONG_TEXT, 56).

init() ->
  pattern(lf, <<"\n">>),
  pattern(colon, <<":">>),
  pattern(space, <<" ">>),
  pattern(question, <<"?">>),
  pattern(comma, <<",">>),
  pattern(close_bracket, <<"]">>),
  pattern(authority_end, [<<"/">>, <<"?">>]),
  pattern(at, <<"@">>),
  pattern(unsafe_header, [<<"\r">>, <<"\n">>, <<0>>]),
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
  case has_uppercase(Bin) of
    false -> Bin;
    true -> << <<(lower(Byte))>> || <<Byte>> <= Bin >>
  end.

has_uppercase(<<Byte, _Rest/binary>>) when Byte >= $A, Byte =< $Z -> true;
has_uppercase(<<_Byte, Rest/binary>>) -> has_uppercase(Rest);
has_uppercase(<<>>) -> false.

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
  is_lowercase_name(Name).

is_lowercase_name(<<Byte, Rest/binary>>)
    when ?IS_NAME_BYTE(Byte), (Byte < $A orelse Byte > $Z) ->
  is_lowercase_name(Rest);
is_lowercase_name(<<>>) ->
  true;
is_lowercase_name(_Name) ->
  false.

is_field_value(<<>>) ->
  true;
is_field_value(<<First, _/binary>> = Value) when not ?IS_WHITESPACE(First) ->
  Last = binary:last(Value),
  not ?IS_WHITESPACE(Last) andalso is_valid_value(Value);
is_field_value(_Value) ->
  false.

split_line(Buffer, MaxLen) ->
  case find_line_feed(Buffer, min(byte_size(Buffer), MaxLen + 2)) of
    nomatch when byte_size(Buffer) > MaxLen -> line_too_long;
    nomatch -> need_more;
    0 -> bad_framing;
    Lf ->
      case binary:at(Buffer, Lf - 1) of
        $\r ->
          Rest = binary:part(Buffer, Lf + 1, byte_size(Buffer) - Lf - 1),
          {line, binary:part(Buffer, 0, Lf - 1), Rest};
        _Byte ->
          bad_framing
      end
  end.

find_line_feed(Buffer, Limit) ->
  case scan_line_feed(Buffer, 0, min(Limit, ?LONG_TEXT)) of
    nomatch when Limit > ?LONG_TEXT ->
      case binary:match(Buffer, pattern(lf), [{scope, {?LONG_TEXT, Limit - ?LONG_TEXT}}]) of
        {Pos, _Length} -> Pos;
        nomatch -> nomatch
      end;
    Found ->
      Found
  end.

scan_line_feed(<<Word:56, Rest/binary>>, Pos, Limit)
    when Pos + 7 =< Limit, ?HAS_BYTE(Word, $\n) =:= 0 ->
  scan_line_feed(Rest, Pos + 7, Limit);
scan_line_feed(<<$\n, _Rest/binary>>, Pos, Limit) when Pos < Limit ->
  Pos;
scan_line_feed(<<_Byte, Rest/binary>>, Pos, Limit) when Pos < Limit ->
  scan_line_feed(Rest, Pos + 1, Limit);
scan_line_feed(_Buffer, _Pos, _Limit) ->
  nomatch.

header_field(Line) ->
  case name_end(Line, 0) of
    Colon when is_integer(Colon), Colon > 0 ->
      Value = trim(Line, Colon + 1, byte_size(Line)),
      case is_valid_value(Value) of
        true -> {field, lowercase_ascii(binary:part(Line, 0, Colon)), Value};
        false -> invalid_field
      end;
    _Invalid ->
      invalid_field
  end.

name_end(<<$:, _Rest/binary>>, Pos) -> Pos;
name_end(<<Byte, Rest/binary>>, Pos) when ?IS_NAME_BYTE(Byte) -> name_end(Rest, Pos + 1);
name_end(_Line, _Pos) -> invalid.

trim_whitespace(Bin) ->
  trim(Bin, 0, byte_size(Bin)).

trim(Bin, Start, End) ->
  From = skip_leading_whitespace(Bin, Start, End),
  To = skip_trailing_whitespace(Bin, From, End),
  binary:part(Bin, From, To - From).

skip_leading_whitespace(Bin, Pos, End) when Pos < End ->
  case binary:at(Bin, Pos) of
    Byte when ?IS_WHITESPACE(Byte) -> skip_leading_whitespace(Bin, Pos + 1, End);
    _Byte -> Pos
  end;
skip_leading_whitespace(_Bin, Pos, _End) ->
  Pos.

skip_trailing_whitespace(Bin, Start, End) when End > Start ->
  case binary:at(Bin, End - 1) of
    Byte when ?IS_WHITESPACE(Byte) -> skip_trailing_whitespace(Bin, Start, End - 1);
    _Byte -> End
  end;
skip_trailing_whitespace(_Bin, _Start, End) ->
  End.

is_valid_value(Value) ->
  case value_bytes(Value, ascii) of
    ascii -> true;
    unicode -> is_binary(unicode:characters_to_binary(Value));
    invalid -> false
  end.

value_bytes(<<A:56, B:56, C:56, D:56, Rest/binary>>, Kind)
    when ((A - 14 * ?LOW_BITS) bor A bor (B - 14 * ?LOW_BITS) bor B
          bor (C - 14 * ?LOW_BITS) bor C bor (D - 14 * ?LOW_BITS) bor D) band ?HIGH_BITS =:= 0 ->
  value_bytes(Rest, Kind);
value_bytes(<<A:56, B:56, C:56, D:56, Rest/binary>>, Kind)
    when (?HAS_LESS(A, 14) bor ?HAS_LESS(B, 14) bor ?HAS_LESS(C, 14)
          bor ?HAS_LESS(D, 14)) =:= 0 ->
  value_bytes(Rest, text_kind(Kind, (A bor B bor C bor D) band ?HIGH_BITS));
value_bytes(<<Word:56, Rest/binary>>, Kind) when ?HAS_LESS(Word, 14) =:= 0 ->
  value_bytes(Rest, text_kind(Kind, Word band ?HIGH_BITS));
value_bytes(<<Byte, Rest/binary>>, Kind) when Byte =/= 0, Byte =/= $\n, Byte =/= $\r ->
  value_bytes(Rest, text_kind(Kind, Byte band 16#80));
value_bytes(<<>>, Kind) ->
  Kind;
value_bytes(_Value, _Kind) ->
  invalid.

text_kind(ascii, 0) -> ascii;
text_kind(_Kind, _HighBits) -> unicode.

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
