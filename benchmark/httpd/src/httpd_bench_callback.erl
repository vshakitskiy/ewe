-module(httpd_bench_callback).

-export([do/1]).

-include_lib("inets/include/httpd.hrl").
-include_lib("kernel/include/file.hrl").

-define(FILE_CHUNK_SIZE, 262144).

%% inets never sets TCP_NODELAY on accepted sockets and exposes no config for it, 
%% so every keep-alive response after the first eats a ~40ms Nagle and 
%% delayed-ACK stall.
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

%% httpd reads the full request body before calling the module, so there is
%% no incremental and chunked read to distinguish from a plain echo.
route("POST", "/echo", Info) ->
  {break, [{response, {200, entity_body(Info)}}]};

route("GET", "/stream", Info) ->
  send_stream(Info),
  {break, [{response, {already_sent, 200, 0}}]};

route("GET", "/file/small", Info) ->
  send_file(Info, "../priv/file_100kb.bin"),
  {break, [{response, {already_sent, 200, 0}}]};
route("GET", "/file/big", Info) ->
  send_file(Info, "../priv/file_1gb.bin"),
  {break, [{response, {already_sent, 200, 0}}]};

route(_Method, _Uri, Info) ->
  {proceed, Info#mod.data}.

entity_body(Info) ->
  case Info#mod.entity_body of
    undefined -> "";
    Body -> Body
  end.

send_stream(Info) ->
  #mod{socket_type = SocketType, socket = Socket} = Info,
  Head =
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: text/plain\r\n"
    "Transfer-Encoding: chunked\r\n"
    "Connection: keep-alive\r\n\r\n",
  httpd_socket:deliver(SocketType, Socket, Head),
  send_chunk(SocketType, Socket, "hello, "),
  send_chunk(SocketType, Socket, "Joe!"),
  httpd_socket:deliver(SocketType, Socket, "0\r\n\r\n").

send_chunk(SocketType, Socket, Data) ->
  Size = integer_to_list(length(Data), 16),
  httpd_socket:deliver(SocketType, Socket, [Size, "\r\n", Data, "\r\n"]).

%% There is no built-in equivalent of the other server's sendfile helpers
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
