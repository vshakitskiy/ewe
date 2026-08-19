-module(http2_ffi).

-on_load(init/0).
-export([
    init/0,
    validate_header_name/2,
    validate_header_value/2,
    monotonic_ms/0,
    split_once/2,
    has_forbidden_header_bytes/2,
    name_pattern/0,
    forbidden_header_pattern/0,
    query_pattern/0,
    colon_pattern/0,
    exit_self/1,
    recv_or_exit/1,
    recv_or_exit/2,
    parent_pid/0,
    is_shutdown/1
]).


%% Compiles and caches match patterns once at module load.
init() ->
  persistent_term:put(
    {?MODULE, name},
    binary:compile_pattern([<<C>> || C <- lists:seq($A, $Z)] ++ [<<0>>, <<"\r">>, <<"\n">>])
  ),
  persistent_term:put(
    {?MODULE, forbidden_header},
    binary:compile_pattern([<<0>>, <<"\r">>, <<"\n">>])
  ),
  persistent_term:put({?MODULE, query}, binary:compile_pattern(<<"?">>)),
  persistent_term:put({?MODULE, colon}, binary:compile_pattern(<<":">>)),
  ok.

name_pattern() -> persistent_term:get({?MODULE, name}).
forbidden_header_pattern() -> persistent_term:get({?MODULE, forbidden_header}).
query_pattern() -> persistent_term:get({?MODULE, query}).
colon_pattern() -> persistent_term:get({?MODULE, colon}).

monotonic_ms() ->
  erlang:monotonic_time(millisecond).

exit_self(Reason) ->
  erlang:exit(Reason).

parent_pid() ->
  case erlang:process_info(self(), parent) of
    {parent, Pid} when is_pid(Pid) -> {ok, Pid};
    _Other -> {error, nil}
  end.

is_shutdown(shutdown) -> true;
is_shutdown(_Reason) -> false.

recv_or_exit(Ref) ->
  receive
    {Ref, Message} -> {ok, Message};
    {'EXIT', _Pid, Reason} -> {error, classify_exit(Reason)}
  end.

recv_or_exit(Ref, Timeout) ->
  receive
    {Ref, Message} -> {ok, Message};
    {'EXIT', _Pid, Reason} -> {error, classify_exit(Reason)}
  after Timeout ->
    {error, timed_out}
  end.

classify_exit(<<"stream_reset">>) -> stream_reset;
classify_exit(_Reason) -> connection_closed.

validate_header_name(_Pattern, <<>>) ->
  {error, invalid_utf8};
validate_header_name(Pattern, Bin) when is_binary(Bin) ->
  case ewe_ffi:is_valid_utf8(Bin) of
    false -> {error, invalid_utf8};
    true -> classify_name_match(binary:match(Bin, Pattern), Bin)
  end;
validate_header_name(_Pattern, _Bits) ->
  {error, invalid_utf8}.

%% We do one scan for both `has an uppercase letter` and `has a forbidden byte`.
%% We only need to know which kind of bad byte it was once we've found one.
classify_name_match(nomatch, Bin) ->
  {ok, Bin};
classify_name_match({Pos, _Len}, Bin) ->
  case binary:at(Bin, Pos) of
    C when C >= $A, C =< $Z -> {error, uppercase_header_name};
    _Byte -> {error, malformed_header_bytes}
  end.

validate_header_value(Pattern, Bin) when is_binary(Bin) ->
  case ewe_ffi:is_valid_utf8(Bin) of
    false ->
      {error, invalid_utf8};
    true ->
      case has_forbidden_header_bytes(Pattern, Bin) of
        true -> {error, malformed_header_bytes};
        false -> {ok, Bin}
      end
  end;
validate_header_value(_Pattern, _Bits) ->
  {error, invalid_utf8}.

has_forbidden_header_bytes(Pattern, Bin) ->
  binary:match(Bin, Pattern) =/= nomatch.

split_once(Bin, Pattern) ->
  case binary:split(Bin, Pattern) of
    [Before, After] -> {ok, {Before, After}};
    _Parts -> {error, nil}
  end.
