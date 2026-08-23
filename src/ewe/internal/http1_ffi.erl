-module(http1_ffi).

-on_load(init/0).
-export([
    init/0,
    find_lf/1,
    find_colon/1,
    find_space/1,
    find_question/1,
    find_close_bracket/1,
    find_unsafe_header_byte/1,
    split_comma/1,
    lowercase_ascii/1,
    bit_array_to_string/1,
    socket_error_reason/1
]).


init() ->
  persistent_term:put({?MODULE, lf}, binary:compile_pattern(<<"\n">>)),
  persistent_term:put({?MODULE, colon}, binary:compile_pattern(<<":">>)),
  persistent_term:put({?MODULE, space}, binary:compile_pattern(<<" ">>)),
  persistent_term:put({?MODULE, question}, binary:compile_pattern(<<"?">>)),
  persistent_term:put({?MODULE, comma}, binary:compile_pattern(<<",">>)),
  persistent_term:put({?MODULE, close_bracket}, binary:compile_pattern(<<"]">>)),
  persistent_term:put(
    {?MODULE, upper},
    binary:compile_pattern([<<C>> || C <- lists:seq($A, $Z)])
  ),
  persistent_term:put(
    {?MODULE, unsafe_header},
    binary:compile_pattern([<<"\r">>, <<"\n">>, <<0>>])
  ),
  ok.

find_lf(Bin) -> find(Bin, lf).
find_colon(Bin) -> find(Bin, colon).
find_space(Bin) -> find(Bin, space).
find_question(Bin) -> find(Bin, question).
find_close_bracket(Bin) -> find(Bin, close_bracket).
find_unsafe_header_byte(Bin) -> find(Bin, unsafe_header).

find(Bin, Key) ->
  case binary:match(Bin, persistent_term:get({?MODULE, Key})) of
    nomatch -> {error, nil};
    {Pos, _Len} -> {ok, Pos}
  end.

split_comma(Bin) ->
  binary:split(Bin, persistent_term:get({?MODULE, comma}), [global]).

lowercase_ascii(Bin) ->
  case binary:match(Bin, persistent_term:get({?MODULE, upper})) of
    nomatch -> Bin;
    _Match -> << <<(lower(Byte))>> || <<Byte>> <= Bin >>
  end.

lower(Byte) when Byte >= $A, Byte =< $Z -> Byte + 32;
lower(Byte) -> Byte.

socket_error_reason({_Tag, _Socket, Reason}) ->
  Reason.

bit_array_to_string(Bin) ->
  case ewe_ffi:is_valid_utf8(Bin) of
    true -> {ok, Bin};
    false -> {error, nil}
  end.

