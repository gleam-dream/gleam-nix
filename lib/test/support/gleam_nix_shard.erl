%% The shard runner's test module: runs one shard's modules through eunit with
%% gleeunit's options. Gleam's <app>@@main calls main/0, as it calls a test
%% package's main under `gleam test`.
-module(gleam_nix_shard).

-export([main/0, select/4, write_selection/5]).

%% Copied from gleeunit's main; the pins check compares them.
gleeunit_options() ->
    [verbose,
     no_tty,
     {report, {gleeunit_progress, [{colored, true}]}},
     {scale_timeouts, 10}].

main() ->
    Modules = [binary_to_atom(Name) || Name <- lines(os:getenv("GLEAM_NIX_SHARD"))],
    case os:getenv("GLEAM_NIX_SHARD_SETUP") of
        false -> ok;
        "" -> ok;
        Setup ->
            [Module, Function] = string:split(Setup, ":"),
            erlang:apply(list_to_atom(Module), list_to_atom(Function), [])
    end,
    Code = case eunit:test(Modules, gleeunit_options()) of
        ok -> 0;
        _ -> 1
    end,
    erlang:halt(Code).

%% A module's shard is the CRC-32 of its name modulo the count, unless pinned.
%% Adding a module never moves another one.
select(Modules, Index, Count, Pins) ->
    [Module || Module <- Modules,
               maps:get(Module, Pins, erlang:crc32(Module) rem Count) =:= Index].

write_selection(ModulesFile, PinsFile, Index, Count, Out) ->
    Pins = maps:from_list([list_to_tuple(Pin) || Line <- lines(PinsFile),
                           Pin <- [pin(Line)]]),
    Selected = select(lines(ModulesFile), Index, Count, Pins),
    ok = file:write_file(Out, [[Module, $\n] || Module <- Selected]).

pin(Line) ->
    [Module, Shard] = binary:split(Line, <<"\t">>),
    [Module, binary_to_integer(Shard)].

lines(File) ->
    {ok, Content} = file:read_file(File),
    [Line || Line <- binary:split(Content, <<"\n">>, [global]), Line =/= <<>>].
