-module(websocket_ffi).

-export([socket_payload/1]).

%% Payload carried by a `{tcp, Socket, Data}` message.
socket_payload({_Tag, _Socket, Data}) ->
  Data.
