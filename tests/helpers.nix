{ pkgs }:
let
  inherit (pkgs) lib;
in
{
  # A build expected to fail, and what its log must say.
  failsWith =
    name: derivation: patterns:
    let
      failure = pkgs.testers.testBuildFailure derivation;
    in
    pkgs.runCommand "gleam-nix-${name}" { } ''
      log=${failure}/testBuildFailure.log
      test "$(cat ${failure}/testBuildFailure.exit)" -ne 0
      ${lib.concatMapStrings (pattern: ''
        if ! grep -qF -- ${lib.escapeShellArg pattern} "$log"; then
          echo "missing from the failure log: "${lib.escapeShellArg pattern} >&2
          cat "$log" >&2
          exit 1
        fi
      '') patterns}
      touch "$out"
    '';
}
