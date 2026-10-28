{ pkgs, gleam }:
let
  inherit (gleam) beamPackages;
  project = import ../examples/beam-composition.nix {
    inherit gleam;
    src = ./fixtures/mixed;
  };
  libraries = pkgs.lib.concatMapStringsSep ":" (package: "${package}/lib/erlang/lib") (
    gleam.beam.closure [ project.package ]
  );
in
pkgs.runCommand "gleam-nix-beam-composition"
  {
    nativeBuildInputs = [ beamPackages.elixir ];
  }
  ''
    ERL_LIBS=${pkgs.lib.escapeShellArg libraries} elixir -e '
      23 = :mixed.answer()
      {:ok, _} = Application.ensure_all_started(:mixed)
      {:ok, applications} = :application.get_key(:mixed, :applications)
      true = :actual_native in applications
      false = :native_math in applications
    '
    touch "$out"
  ''
