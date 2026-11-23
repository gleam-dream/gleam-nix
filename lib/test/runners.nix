{ lib }:
# A runner turns a compiled test tree into test results. Its `run` receives the
# root's OTP application name and test module and returns a shell fragment.
# The fragment runs from a copy of the root's source, with $GLEAM_NIX_ERL
# starting a VM that has the check's code, CA bundle and flags, and must exit
# with a failing status when a test fails. Each test module it runs reaches
# $GLEAM_NIX_TEST_REPORT through the eunit listener the check installs.
let
  main =
    { app, module }:
    ''
      "$GLEAM_NIX_ERL" -eval ${lib.escapeShellArg "'${app}@@main':run('${module}')"}
    '';

  shard =
    {
      index,
      count,
      setup ? null,
      pins ? { },
    }:
    let
      badPins = lib.filterAttrs (_: shard: !(builtins.isInt shard) || shard < 0 || shard >= count) pins;
      setupTarget =
        if setup == null then
          ""
        else
          let
            parts = lib.splitString "." setup;
          in
          if builtins.length parts != 2 then
            throw "gleam-nix: shard setup must name a Gleam function as module.function, not ${setup}."
          else
            "${builtins.replaceStrings [ "/" ] [ "@" ] (builtins.elemAt parts 0)}:${builtins.elemAt parts 1}";
      pinFile = lib.concatStrings (
        lib.mapAttrsToList (module: shard: "${module}\t${toString shard}\n") pins
      );
    in
    if !(builtins.isInt count) || count < 1 then
      throw "gleam-nix: a shard count must be a positive integer."
    else if index < 0 || index >= count then
      throw "gleam-nix: shard ${toString index} is outside 0 to ${toString (count - 1)}."
    else if badPins != { } then
      throw "gleam-nix: shard pins outside 0 to ${toString (count - 1)}: ${lib.concatStringsSep ", " (lib.attrNames badPins)}."
    else
      {
        name = "shard-${toString (index + 1)}-of-${toString count}";
        inherit index count;
        run =
          { app, ... }:
          ''
            export GLEAM_NIX_SHARD_PINS="$TMPDIR/gleam-nix-pins"
            printf %s ${lib.escapeShellArg pinFile} > "$GLEAM_NIX_SHARD_PINS"
            "$GLEAM_NIX_ERL" -eval ${lib.escapeShellArg ''gleam_nix_shard:write_selection(os:getenv("GLEAM_NIX_TEST_MODULES"), os:getenv("GLEAM_NIX_SHARD_PINS"), ${toString index}, ${toString count}, os:getenv("GLEAM_NIX_SHARD")), halt(0).''}
            export GLEAM_NIX_SHARD_SETUP=${lib.escapeShellArg setupTarget}
            ${main {
              inherit app;
              module = "gleam_nix_shard";
            }}
          '';
      };
in
{
  # Runs the package's own test main, exactly as `gleam test` does.
  default = {
    name = "test";
    run = { app, module }: main { inherit app module; };
  };

  inherit shard;

  # Every shard of one check, in order.
  shards =
    {
      count,
      setup ? null,
      pins ? { },
    }:
    builtins.genList (
      index:
      shard {
        inherit
          index
          count
          setup
          pins
          ;
      }
    ) count;
}
