-module(pg_test).
-include_lib("eunit/include/eunit.hrl").

%% The server answers as the role, database and major version the check
%% expects, through PG* variables or DATABASE_URL.
connection_test() ->
    Query = "select current_user || ' ' || current_database() || ' ' || current_setting('server_version_num')::int / 10000",
    Target = case os:getenv("DATABASE_URL") of false -> ""; Url -> " " ++ Url end,
    Output = os:cmd("psql --no-psqlrc --tuples-only --no-align --command \"" ++ Query ++ "\"" ++ Target),
    ?assertEqual(os:getenv("EXPECTED") ++ "\n", Output).
