-module(ewe_ffi).

-export([close_file/1, decode_packet/3, init_clock_storage/0, lookup_http_date/0, now/0,
         now_microseconds/0, open_file/1, set_http_date/1, validate_lowercase_field/1,
         validate_field_value/1, validate_lowercase_field_value/1, sanitize_header_value/1,
         coerce_tcp_message/1, parse_path/1]).

% Socket
% -----------------------------------------------------------------------------

coerce_tcp_message({tcp, _Socket, Data}) ->
  Data;
coerce_tcp_message({ssl, _Socket, Data}) ->
  Data.

% HTTP
% -----------------------------------------------------------------------------

decode_packet(Type, Packet, Options) ->
  case erlang:decode_packet(Type, Packet, Options) of
    {ok, {http_request, <<"PRI">>, '*', {2, 0}}, Rest} ->
      {ok, {packet, http2_upgrade, Rest}};
    {ok, {http_request, Method, Uri, Version}, Rest} ->
      {ok, {packet, {http_request, atom_to_binary(Method), Uri, Version}, Rest}};
    {ok, {http_header, Idx, _, Field, Value}, Rest} ->
      {ok, {packet, {http_header, Idx, Field, Value}, Rest}};
    {ok, Bin, Rest} ->
      {ok, {packet, Bin, Rest}};
    {more, undefined} ->
      {ok, {more, none}};
    {more, Length} ->
      {ok, {more, {some, Length}}};
    {error, Reason} ->
      {error, Reason}
  end.

parse_path(Value) ->
  case uri_string:parse(Value) of
    {error, _, _} ->
      {error, nil};
    Uri ->
      Query =
        try
          {some, maps:get(query, Uri)}
        catch
          _:_ ->
            none
        end,
      {ok, {maps:get(path, Uri), Query}}
  end.

validate_lowercase_field(<<>>) ->
  {error, invalid_headers};
validate_lowercase_field(Value) ->
  validate_lowercase_field(Value, <<>>).

validate_lowercase_field(<<>>, Acc) ->
  {ok, Acc};
validate_lowercase_field(<<C, Rest/bits>>, Acc) when C >= $A, C =< $Z ->
  validate_lowercase_field(Rest, <<Acc/binary, (C + 32)>>);
validate_lowercase_field(<<C, Rest/bits>>, Acc)
  when C >= $a, C =< $z;
       C >= $0, C =< $9;
       C =:= $!;
       C =:= $#;
       C =:= $$;
       C =:= $%;
       C =:= $&;
       C =:= $';
       C =:= $*;
       C =:= $+;
       C =:= $-;
       C =:= $.;
       C =:= $^;
       C =:= $_;
       C =:= $`;
       C =:= $|;
       C =:= $~ ->
  validate_lowercase_field(Rest, <<Acc/binary, C>>);
validate_lowercase_field(_, _) ->
  {error, invalid_headers}.

validate_field_value(Value) ->
  case do_validate_field_value(Value) of
    true ->
      {ok, Value};
    false ->
      {error, invalid_headers}
  end.

% HTTP field values can contain:
% - VCHAR: 0x21-0x7E (visible ASCII characters)
% - WSP: 0x20 (space), 0x09 (tab)
% - obs-text: 0x80-0xFF (for backward compatibility)
% Invalid: control characters 0x00-0x08, 0x0A-0x1F, 0x7F
do_validate_field_value(Value) ->
  case Value of
    <<>> ->
      true;
    <<C, Rest/bitstring>>
      when C =:= 16#09
           orelse C >= 16#20 andalso C =< 16#7E
           orelse C >= 16#80 andalso C =< 16#FF ->
      do_validate_field_value(Rest);
    _ ->
      false
  end.

validate_lowercase_field_value(Value) ->
  do_validate_lowercase_field_value(Value, <<>>).

do_validate_lowercase_field_value(<<>>, Acc) ->
  {ok, Acc};
do_validate_lowercase_field_value(<<C, Rest/bits>>, Acc) when C >= $A, C =< $Z ->
  do_validate_lowercase_field_value(Rest, <<Acc/binary, (C + 32)>>);
do_validate_lowercase_field_value(<<C, Rest/bits>>, Acc)
  when C =:= 16#09
       orelse C >= 16#20 andalso C =< 16#7E
       orelse C >= 16#80 andalso C =< 16#FF ->
  do_validate_lowercase_field_value(Rest, <<Acc/binary, C>>);
do_validate_lowercase_field_value(_, _) ->
  {error, invalid_headers}.

sanitize_header_value(Value) ->
  sanitize_header_value(Value, <<>>).

sanitize_header_value(<<>>, Acc) ->
  Acc;
sanitize_header_value(<<C, Rest/bitstring>>, Acc) when C =:= 16#0D; C =:= 16#0A ->
  sanitize_header_value(Rest, Acc);
sanitize_header_value(<<C, Rest/bitstring>>, Acc) ->
  sanitize_header_value(Rest, <<Acc/binary, C>>).

% CLOCK
% -----------------------------------------------------------------------------

now() ->
  Timestamp = os:system_time(microsecond),
  {Date, Time} = calendar:system_time_to_universal_time(Timestamp, microsecond),
  Weekday = calendar:day_of_the_week(Date),
  {Weekday, Date, Time}.

now_microseconds() ->
  os:system_time(microsecond).

init_clock_storage() ->
  ets:new(ewe_clock, [set, protected, named_table, {read_concurrency, true}]).

set_http_date(Value) ->
  ets:insert(ewe_clock, {http_date, Value}).

lookup_http_date() ->
  try
    {ok, ets:lookup_element(ewe_clock, http_date, 2)}
  catch
    _:badarg ->
      {error, nil}
  end.

% FILES
% -----------------------------------------------------------------------------

open_file(Path) ->
  case file:open(Path, [binary, raw]) of
    {ok, IoDevice} ->
      {ok, {file, IoDevice, filelib:file_size(Path)}};
    {error, enoent} ->
      {error, enoent};
    {error, eacces} ->
      {error, eacces};
    {error, eisdir} ->
      {error, eisdir};
    {error, enotdir} ->
      {error, enoent};
    {error, Err} ->
      {error, {eunknown, Err}}
  end.

close_file(File) ->
  case file:close(File) of
    ok ->
      {ok, nil};
    {error, enoent} ->
      {error, enoent};
    {error, eacces} ->
      {error, eacces};
    {error, eisdir} ->
      {error, eisdir};
    {error, enotdir} ->
      {error, enoent};
    {error, _} ->
      {error, eunknown}
  end.
