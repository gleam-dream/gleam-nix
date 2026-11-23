-module(served_ffi).
-export([start/0, sleep_forever/0, do/1]).

-include_lib("inets/include/httpd.hrl").

%% Serves /health and, from $ASSETS_DIR, /assets/<file>.
start() ->
    Port = list_to_integer(os:getenv("PORT", "8080")),
    Root = os:getenv("TMPDIR", "/tmp"),
    {ok, _} = inets:start(httpd, [{port, Port}, {server_name, "served"},
                                  {server_root, Root}, {document_root, Root},
                                  {bind_address, any}, {modules, [?MODULE]}]),
    nil.

do(#mod{request_uri = "/health"}) ->
    {proceed, [{response, {200, "ok"}}]};
do(#mod{request_uri = "/assets/" ++ Name}) ->
    case file:read_file(filename:join(os:getenv("ASSETS_DIR", "/nonexistent"), Name)) of
        {ok, Body} -> {proceed, [{response, {200, binary_to_list(Body)}}]};
        {error, _} -> {proceed, [{response, {404, "missing"}}]}
    end;
do(_) ->
    {proceed, [{response, {404, "not found"}}]}.

sleep_forever() ->
    timer:sleep(infinity).
