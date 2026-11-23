-module(database_test).
-include_lib("eunit/include/eunit.hrl").

%% The check's PostgreSQL service answers through DATABASE_URL. A service
%% would use its own client; psql keeps the example free of dependencies.
database_answers_test() ->
    Url = os:getenv("DATABASE_URL"),
    ?assertNotEqual(false, Url),
    Command = "psql --no-psqlrc --tuples-only --no-align --command 'select 40 + 2' '" ++ Url ++ "'",
    ?assertEqual("42\n", os:cmd(Command)).
