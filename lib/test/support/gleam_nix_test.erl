%% Helpers every VM in a test check uses.
-module(gleam_nix_test).

-export([load_ca/0, discover/1]).

%% Loads the check's CA bundle, so TLS clients verify peers in the sandbox.
load_ca() ->
    case os:getenv("SSL_CERT_FILE") of
        false -> ok;
        File ->
            case public_key:cacerts_load(File) of
                ok -> ok;
                {error, Reason} ->
                    io:format(standard_error, "gleam-nix: cannot load CA bundle ~ts: ~p~n", [File, Reason]),
                    erlang:halt(2)
            end
    end.

%% Prints the test modules among the given modules: those exporting a zero-arity
%% function whose name ends in _test or _test_, as eunit discovers them.
discover([Ebin | Modules]) ->
    Found = [Module || Module <- Modules, has_tests(filename:join(Ebin, Module ++ ".beam"))],
    io:put_chars([[Module, $\n] || Module <- lists:sort(Found)]),
    erlang:halt(0).

has_tests(Beam) ->
    case beam_lib:chunks(Beam, [exports]) of
        {ok, {_, [{exports, Exports}]}} ->
            lists:any(fun({Name, 0}) ->
                              String = atom_to_list(Name),
                              lists:suffix("_test", String) orelse lists:suffix("_test_", String);
                         (_) -> false
                      end, Exports);
        _ -> false
    end.
