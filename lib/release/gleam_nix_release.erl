%% Checks a release's application closure against its libraries and runtime.
-module(gleam_nix_release).

-export([check/1]).

%% Arguments: the root application, the release's lib directory, the
%% runtime's lib directory, then the applications the runtime removed.
check([Root, Release, Runtime | Removed]) ->
    Known = maps:from_list([read(File) || Directory <- [Release, Runtime],
                                          File <- filelib:wildcard(Directory ++ "/*/ebin/*.app")]),
    RemovedApps = [list_to_atom(Name) || Name <- Removed],
    case walk([list_to_atom(Root)], Known, #{}, []) of
        [] ->
            erlang:halt(0);
        Missing ->
            [report(Needer, Needed, lists:member(Needed, RemovedApps)) || {Needer, Needed} <- lists:sort(Missing)],
            erlang:halt(1)
    end.

read(File) ->
    {ok, [{application, Name, Properties}]} = file:consult(File),
    {Name, proplists:get_value(applications, Properties, [])
           ++ proplists:get_value(included_applications, Properties, [])}.

walk([], _Known, _Seen, Missing) ->
    Missing;
walk([App | Rest], Known, Seen, Missing) when is_map_key(App, Seen) ->
    walk(Rest, Known, Seen, Missing);
walk([App | Rest], Known, Seen, Missing) ->
    Needs = maps:get(App, Known, []),
    Absent = [{App, Needed} || Needed <- Needs, not is_map_key(Needed, Known)],
    walk(Rest ++ Needs, Known, Seen#{App => true}, Missing ++ Absent).

report(Needer, Needed, true) ->
    io:format(standard_error, "gleam-nix: ~ts needs ~ts, which the runtime removed.~n", [Needer, Needed]);
report(Needer, Needed, false) ->
    io:format(standard_error, "gleam-nix: ~ts needs ~ts, which neither the release nor the runtime has.~n",
              [Needer, Needed]).
