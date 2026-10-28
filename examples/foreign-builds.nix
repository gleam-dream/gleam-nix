{ pkgs, src }:
let
  gleam = import ../default.nix { inherit pkgs; };
in
gleam.importProject {
  inherit src;
  buildForeign = true;
  # esqlite's native build uses the Rebar3 port compiler plugin.
  foreignArgs.esqlite.buildPlugins = [ pkgs.beamPackages.pc ];
}
