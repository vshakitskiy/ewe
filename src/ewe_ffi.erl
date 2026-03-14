-module(ewe_ffi).

-export([close_file/1, decode_packet/3, init_clock_storage/0, lookup_http_date/0, now/0,
         now_microseconds/0, open_file/1, set_http_date/1, validate_field_value/1,
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

validate_field_value(Value) ->
  case do_validate_field_value(Value) of
    true ->
      {ok, Value};
    false ->
      {error, nil}
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
