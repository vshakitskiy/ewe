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
    list_to_bit_array/1,
    bit_array_to_string/1
]).

%% Compiles and caches match patterns once at module load.
init() ->
  persistent_term:put({?MODULE, lf}, binary:compile_pattern(<<"\n">>)),
  persistent_term:put({?MODULE, colon}, binary:compile_pattern(<<":">>)),
  persistent_term:put({?MODULE, space}, binary:compile_pattern(<<" ">>)),
  persistent_term:put({?MODULE, question}, binary:compile_pattern(<<"?">>)),
  persistent_term:put({?MODULE, comma}, binary:compile_pattern(<<",">>)),
  persistent_term:put({?MODULE, close_bracket}, binary:compile_pattern(<<"]">>)),
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

%% Splits on every comma in one call.
split_comma(Bin) ->
  binary:split(Bin, persistent_term:get({?MODULE, comma}), [global]).

%% Flattens a list of bytes into a binary in one pass.
list_to_bit_array(Bytes) ->
  erlang:list_to_binary(Bytes).

%% Validates UTF-8 via native BIFs and returns the bytes unchanged.
bit_array_to_string(Bin) ->
  case unicode:bin_is_7bit(Bin) of
    true ->
      {ok, Bin};
    false ->
      case unicode:characters_to_binary(Bin) of
        Out when is_binary(Out) -> {ok, Bin};
        _ -> {error, nil}
      end
  end.
