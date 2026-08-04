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

-define(HIGH_BITS, 16#80808080808080).

%% Compiles and caches match patterns once at module load.
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

%% Splits on every comma in one call.
split_comma(Bin) ->
  binary:split(Bin, persistent_term:get({?MODULE, comma}), [global]).

%% Scans for uppercase natively so an already lowercase binary is returned
%% untouched, and rewrites in one pass otherwise.
lowercase_ascii(Bin) ->
  case binary:match(Bin, persistent_term:get({?MODULE, upper})) of
    nomatch -> Bin;
    _Match -> << <<(lower(Byte))>> || <<Byte>> <= Bin >>
  end.

lower(Byte) when Byte >= $A, Byte =< $Z -> Byte + 32;
lower(Byte) -> Byte.

%% Reason carried by a `{tcp_error, Socket, Reason}` message.
socket_error_reason({_Tag, _Socket, Reason}) ->
  Reason.

%% Validates UTF-8 and returns the bytes unchanged. Everything skip_ascii walks
%% past is ASCII which is valid UTF-8 and never part of a multi-byte sequence
%% so whatever it stops on still starts on a character boundary and can be
%% validated on its own.
bit_array_to_string(Bin) when is_binary(Bin) ->
  case skip_ascii(Bin) of
    <<>> ->
      {ok, Bin};
    Rest ->
      case unicode:characters_to_binary(Rest, utf8) of
        Out when is_binary(Out) -> {ok, Bin};
        _Invalid -> {error, nil}
      end
  end;
bit_array_to_string(_Bits) ->
  {error, nil}.

%% Tests seven bytes per word rather than eight, since 56 bits is the widest that
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
