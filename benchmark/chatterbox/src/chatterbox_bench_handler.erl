-module(chatterbox_bench_handler).

-behaviour(h2_stream).

-export([
    init/3,
    on_receive_request_headers/2,
    on_send_push_promise/2,
    on_receive_request_data/2,
    on_request_end_stream/1
]).

-define(SMALL_COUNT, 100).
-define(BIG_COUNT, 64).

-record(state, {
    conn_pid :: pid(),
    stream_id :: non_neg_integer(),
    path = undefined :: binary() | undefined,
    buffer = <<>> :: binary()
}).

init(ConnPid, StreamId, _Opts) ->
    {ok, #state{conn_pid = ConnPid, stream_id = StreamId}}.

on_receive_request_headers(Headers, State) ->
    Path = proplists:get_value(<<":path">>, Headers),
    {ok, State#state{path = Path}}.

on_send_push_promise(_Headers, State) ->
    {ok, State}.

on_receive_request_data(Data, State = #state{buffer = Buffer}) ->
    {ok, State#state{buffer = <<Buffer/binary, Data/binary>>}}.

on_request_end_stream(
    State = #state{conn_pid = ConnPid, stream_id = StreamId, path = Path, buffer = Buffer}
) ->
    respond(Path, Buffer, ConnPid, StreamId, State).

respond(<<"/hello">>, _Body, ConnPid, StreamId, State) ->
    send(ConnPid, StreamId, 200, <<"text/plain">>, <<"Hello, Joe!">>),
    {ok, State};
respond(<<"/echo">>, Body, ConnPid, StreamId, State) ->
    send(ConnPid, StreamId, 200, <<"application/octet-stream">>, Body),
    {ok, State};
respond(<<"/echo/chunked">>, Body, ConnPid, StreamId, State) ->
    send(ConnPid, StreamId, 200, <<"application/octet-stream">>, Body),
    {ok, State};
respond(<<"/file/tiny">>, _Body, ConnPid, StreamId, State) ->
    send_file(ConnPid, StreamId, "../priv/file_1kb.bin"),
    {ok, State};
respond(<<"/file/small">>, _Body, ConnPid, StreamId, State) ->
    send_file(ConnPid, StreamId, "../priv/file_100kb.bin"),
    {ok, State};
respond(<<"/file/big">>, _Body, ConnPid, StreamId, State) ->
    send_file(ConnPid, StreamId, "../priv/file_5mb.bin"),
    {ok, State};
respond(<<"/stream">>, _Body, ConnPid, StreamId, State) ->
    send_headers(ConnPid, StreamId, [{<<"content-type">>, <<"text/plain">>}]),
    h2_connection:send_body(ConnPid, StreamId, <<"hello, ">>, [{send_end_stream, false}]),
    h2_connection:send_body(ConnPid, StreamId, <<"Joe!">>),
    {ok, State};
respond(<<"/stream/small">>, _Body, ConnPid, StreamId, State) ->
    send_stream(ConnPid, StreamId, <<"text/plain">>, small_chunk, ?SMALL_COUNT),
    {ok, State};
respond(<<"/stream/big">>, _Body, ConnPid, StreamId, State) ->
    send_stream(ConnPid, StreamId, <<"application/octet-stream">>, big_chunk, ?BIG_COUNT),
    {ok, State};
respond(_Path, _Body, ConnPid, StreamId, State) ->
    send(ConnPid, StreamId, 404, <<"text/plain">>, <<"not found">>),
    {ok, State}.

send_file(ConnPid, StreamId, Path) ->
    case file:read_file(Path) of
        {ok, Data} -> send(ConnPid, StreamId, 200, <<"application/octet-stream">>, Data);
        {error, _Reason} -> send(ConnPid, StreamId, 404, <<"text/plain">>, <<"not found">>)
    end.

send_headers(ConnPid, StreamId, Headers) ->
    h2_connection:send_headers(ConnPid, StreamId, [{<<":status">>, <<"200">>} | Headers]).

send(ConnPid, StreamId, Status, ContentType, Body) ->
    Headers = [
        {<<":status">>, integer_to_binary(Status)},
        {<<"content-type">>, ContentType},
        {<<"content-length">>, integer_to_binary(iolist_size(Body))}
    ],
    h2_connection:send_headers(ConnPid, StreamId, Headers),
    h2_connection:send_body(ConnPid, StreamId, iolist_to_binary(Body)).

send_stream(ConnPid, StreamId, ContentType, Key, Count) ->
    send_headers(ConnPid, StreamId, [{<<"content-type">>, ContentType}]),
    send_chunks(ConnPid, StreamId, chatterbox_bench_app:payload(Key), Count).

send_chunks(ConnPid, StreamId, Chunk, 1) ->
    h2_connection:send_body(ConnPid, StreamId, Chunk);
send_chunks(ConnPid, StreamId, Chunk, N) ->
    h2_connection:send_body(ConnPid, StreamId, Chunk, [{send_end_stream, false}]),
    send_chunks(ConnPid, StreamId, Chunk, N - 1).
