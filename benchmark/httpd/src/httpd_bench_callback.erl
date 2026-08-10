-module(httpd_bench_callback).

-export([do/1]).

-include_lib("inets/include/httpd.hrl").
-include_lib("kernel/include/file.hrl").

-define(FILE_CHUNK_SIZE, 262144).

-define(SMALL_COUNT, 100).
-define(BIG_COUNT, 64).

do(Info) ->
  #mod{socket_type = SocketType, socket = Socket} = Info,
  ensure_nodelay(SocketType, Socket),
  route(Info#mod.method, Info#mod.request_uri, Info).

ensure_nodelay(ip_comm, Socket) ->
  inet:setopts(Socket, [{nodelay, true}]);
ensure_nodelay(_SocketType, _Socket) ->
  ok.

route("GET", "/hello", _Info) ->
  {break, [{response, {200, "Hello, Joe!"}}]};

route("POST", "/echo", Info) ->
  {break, [{response, {200, entity_body(Info)}}]};

route("GET", "/stream", Info) ->
  send_stream(Info),
  {break, [{response, {already_sent, 200, 0}}]};

route("GET", "/stream/small", Info) ->
  send_burst(Info, "text/plain", small_chunk, ?SMALL_COUNT);
route("GET", "/stream/big", Info) ->
  send_burst(Info, "application/octet-stream", big_chunk, ?BIG_COUNT);

route("GET", "/file/tiny", Info) ->
  send_file(Info, "../priv/file_1kb.bin"),
  {break, [{response, {already_sent, 200, 0}}]};
route("GET", "/file/small", Info) ->
  send_file(Info, "../priv/file_100kb.bin"),
  {break, [{response, {already_sent, 200, 0}}]};
route("GET", "/file/big", Info) ->
  send_file(Info, "../priv/file_5mb.bin"),
  {break, [{response, {already_sent, 200, 0}}]};

route(_Method, _Uri, Info) ->
  {proceed, Info#mod.data}.

entity_body(Info) ->
  case Info#mod.entity_body of
    undefined -> "";
    Body -> Body
  end.

chunked_head(ContentType) ->
  [
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: ", ContentType, "\r\n"
    "Transfer-Encoding: chunked\r\n"
    "Connection: keep-alive\r\n\r\n"
  ].

send_stream(Info) ->
  #mod{socket_type = SocketType, socket = Socket} = Info,
  httpd_socket:deliver(SocketType, Socket, chunked_head("text/plain")),
  send_chunk(SocketType, Socket, <<"hello, ">>),
  send_chunk(SocketType, Socket, <<"Joe!">>),
  httpd_socket:deliver(SocketType, Socket, "0\r\n\r\n").

send_burst(Info, ContentType, Key, Count) ->
  #mod{socket_type = SocketType, socket = Socket} = Info,
  httpd_socket:deliver(SocketType, Socket, chunked_head(ContentType)),
  deliver_burst(SocketType, Socket, httpd_bench_app:payload(Key), Count),
  httpd_socket:deliver(SocketType, Socket, "0\r\n\r\n"),
  {break, [{response, {already_sent, 200, 0}}]}.

deliver_burst(_SocketType, _Socket, _Chunk, 0) ->
  ok;
deliver_burst(SocketType, Socket, Chunk, Remaining) ->
  send_chunk(SocketType, Socket, Chunk),
  deliver_burst(SocketType, Socket, Chunk, Remaining - 1).

send_chunk(SocketType, Socket, Data) ->
  Size = integer_to_list(byte_size(Data), 16),
  httpd_socket:deliver(SocketType, Socket, [Size, "\r\n", Data, "\r\n"]).

send_file(Info, Path) ->
  #mod{socket_type = SocketType, socket = Socket} = Info,
  {ok, #file_info{size = Size}} = file:read_file_info(Path),
  Head =
    io_lib:format(
      "HTTP/1.1 200 OK\r\n"
      "Content-Type: application/octet-stream\r\n"
      "Content-Length: ~b\r\n"
      "Connection: keep-alive\r\n\r\n",
      [Size]
    ),
  httpd_socket:deliver(SocketType, Socket, Head),
  {ok, Fd} = file:open(Path, [read, raw, binary]),
  deliver_file(SocketType, Socket, Fd),
  file:close(Fd).

deliver_file(SocketType, Socket, Fd) ->
  case file:read(Fd, ?FILE_CHUNK_SIZE) of
    {ok, Data} ->
      httpd_socket:deliver(SocketType, Socket, Data),
      deliver_file(SocketType, Socket, Fd);
    eof ->
      ok
  end.
