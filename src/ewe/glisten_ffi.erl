-module(glisten_ffi).

-export([parse_address/1, rescue/1, to_erl_tcp_options/1,
  merge_type_list/2, socket_data/1, delete_file/1]).

parse_address(Address) ->
  case inet:parse_address(Address) of
    {ok, {A, B, C, D}} ->
      {ok, {ip_v4, A, B, C, D}};
    {ok, {A, B, C, D, E, F, G, H}} ->
      {ok, {ip_v6, A, B, C, D, E, F, G, H}};
    {error, _Reason} ->
      {error, nil}
  end.

rescue(Func) ->
  try
    Res = Func(),
    {ok, Res}
  catch
    Anything -> {error, Anything}
  end.

to_erl_tcp_options(Options) ->
  lists:map(fun(A) -> to_erl_tcp_option(A) end, Options).

to_erl_tcp_option({active_mode, once}) -> {active, once};
to_erl_tcp_option({active_mode, passive}) -> {active, false};
to_erl_tcp_option({active_mode, active}) -> {active, true};
to_erl_tcp_option({active_mode, {count, N}}) -> {active, N};
to_erl_tcp_option({ip, {address, {ip_v4, A, B, C, D}}}) ->
  {ip, {A, B, C, D}};
to_erl_tcp_option({ip, {address, {ip_v6, A, B, C, D, E, F, G, H}}}) ->
  {ip, {A, B, C, D, E, F, G, H}};
to_erl_tcp_option({ip, any}) -> {ip, any};
to_erl_tcp_option({ip, loopback}) -> {ip, loopback};
to_erl_tcp_option({ip, {unix_path, <<"@", Rest/binary>>}}) ->
  {ifaddr, {local, <<0, Rest/binary>>}};
to_erl_tcp_option({ip, {unix_path, Path}}) ->
  {ifaddr, {local, Path}};
to_erl_tcp_option(ipv6) -> inet6;
to_erl_tcp_option({cert_key_config, {cert_key_files, CertFile, KeyFile}}) ->
  {certs_keys, [#{certfile => CertFile, keyfile => KeyFile}]};
to_erl_tcp_option({cert_key_config, {cert_key_pem, Cert, Key}}) ->
  [{_, DerCert, _}|_] = public_key:pem_decode(Cert),
  [{KeyType, DerKey, _}|_] = public_key:pem_decode(Key),
  {certs_keys, [#{cert => [DerCert], key => {KeyType, DerKey}}]};
to_erl_tcp_option({cert_key_config, {cert_key_der, Cert, KeyType, Key}}) ->
  ErlKeyType = key_type_to_erl(KeyType),
  {certs_keys, [#{cert => [Cert], key => {ErlKeyType, Key}}]};
to_erl_tcp_option({verify, verify_peer}) -> {verify, verify_peer};
to_erl_tcp_option({verify, verify_none}) -> {verify, verify_none};
to_erl_tcp_option({ca_cert_file, Path}) -> {cacertfile, Path};
to_erl_tcp_option({ca_certs, Certs}) -> {cacerts, Certs};
to_erl_tcp_option({fail_if_no_peer_cert, V}) -> {fail_if_no_peer_cert, V};
to_erl_tcp_option(Other) -> Other.

key_type_to_erl(rsa_private_key)  -> 'RSAPrivateKey';
key_type_to_erl(ec_private_key)   -> 'ECPrivateKey';
key_type_to_erl(dsa_private_key)  -> 'DSAPrivateKey';
key_type_to_erl(private_key_info) -> 'PrivateKeyInfo'.

merge_type_list(Original, Override) ->
  NewKeys = get_type_keys(Override),
  KeepFromOriginal =
  lists:foldl(
    fun(Value, Accu) -> insert_value(Value, Accu, NewKeys) end,
    [],
    Original),
  KeepFromOriginal ++ Override.

insert_value(Value, Accu, NewKeys) ->
  case lists:member(get_type_key(Value), NewKeys) of
    true -> Accu;
    false -> [ Value | Accu ]
  end.

get_type_keys(TypeList) ->
  lists:map(
    fun(Type) -> get_type_key(Type) end,
    TypeList).

get_type_key(Type) when is_atom(Type) -> Type;
get_type_key(Type) when is_tuple(Type) -> element(1, Type).

socket_data({tcp, _Socket, Data}) -> Data;
socket_data({ssl, _Socket, Data}) -> Data;
socket_data({tcp_error, _Socket, Reason}) -> Reason;
socket_data({ssl_error, _Socket, Reason}) -> Reason.

delete_file(Path) ->
  case file:delete(Path) of
    ok -> {ok, nil};
    {error, enoent} -> {ok, nil};
    {error, Reason} -> {error, Reason}
  end.