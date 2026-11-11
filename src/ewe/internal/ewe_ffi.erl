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

    file_stat/1,
    file_open/1,
    file_size/1,
    file_read/3,
    file_read_range/3,
    file_close/1,
    sendfile/4,

    socket_payload/1,
    socket_error_reason/1,

    is_shutdown/1,
    recv_or_exit/1,
    recv_or_exit/2,

    split_breaks/1,
    strip_breaks/1
]).

init() ->
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
