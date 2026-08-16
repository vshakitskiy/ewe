-module(websocket_ffi).

-export([socket_payload/1]).

socket_payload({_Tag, _Socket, Data}) ->
  Data.
