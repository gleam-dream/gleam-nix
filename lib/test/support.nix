{ lib, runCommand }:
# Erlang modules the runners load, compiled with the project's own Erlang.
erlang:
runCommand "gleam-nix-test-support"
  {
    nativeBuildInputs = [ erlang ];
    passthru.main = ../gleam-main.erl;
  }
  ''
    mkdir -p "$out/ebin"
    erlc +deterministic -Werror -o "$out/ebin" ${./support}/*.erl
  ''
