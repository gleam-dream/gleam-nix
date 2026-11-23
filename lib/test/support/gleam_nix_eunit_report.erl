%% An eunit listener that writes one line per test module to a declared file:
%% module, verdict (passed or failed), test count and milliseconds.
-module(gleam_nix_eunit_report).
-behaviour(eunit_listener).

-export([start/0, start/1]).
-export([init/1, handle_begin/3, handle_end/3, handle_cancel/3, terminate/2]).

start() -> start([]).

start(Options) -> eunit_listener:start(?MODULE, Options).

init(Options) ->
    File = proplists:get_value(file, Options, os:getenv("GLEAM_NIX_TEST_REPORT")),
    #{file => File, modules => #{}}.

handle_begin(_Kind, _Data, State) -> State.

handle_end(test, Data, State) ->
    Verdict = case proplists:get_value(status, Data) of
        ok -> passed;
        _ -> failed
    end,
    record(module_of(Data), Verdict, proplists:get_value(time, Data, 0), State);
handle_end(_Kind, _Data, State) -> State.

handle_cancel(_Kind, Data, State) ->
    record(module_of(Data), failed, 0, State).

terminate(_Result, #{file := File, modules := Modules}) when is_list(File) ->
    Lines = [io_lib:format("~ts\t~ts\t~b\t~b~n", [Module, Verdict, Count, Time])
             || {Module, {Verdict, Count, Time}} <- lists:sort(maps:to_list(Modules))],
    ok = file:write_file(File, Lines);
terminate(_Result, _State) -> ok.

module_of(Data) ->
    case proplists:get_value(source, Data) of
        {Module, _Function, _Arity} -> atom_to_binary(Module);
        _ -> module_of_description(proplists:get_value(desc, Data))
    end.

%% A cancelled group, such as a module that fails to load, names its module
%% only in its description.
module_of_description(Description) when is_binary(Description); is_list(Description) ->
    case re:run(Description, "^module '([^']+)'", [{capture, all_but_first, binary}, unicode]) of
        {match, [Module]} -> Module;
        nomatch -> undefined
    end;
module_of_description(_) -> undefined.

record(undefined, _Verdict, _Time, State) -> State;
record(Module, Verdict, Time, #{modules := Modules} = State) ->
    {Previous, Count, Total} = maps:get(Module, Modules, {passed, 0, 0}),
    Combined = case {Previous, Verdict} of
        {passed, passed} -> passed;
        _ -> failed
    end,
    State#{modules := Modules#{Module => {Combined, Count + 1, Total + Time}}}.
