-module(beta_test).
-include_lib("eunit/include/eunit.hrl").

ca_bundle_loaded_test() ->
    ?assert(length(public_key:cacerts_get()) > 0).

setup_ran_test() ->
    ?assertEqual(<<"ready">>, persistent_term:get(<<"tested">>, missing)).
