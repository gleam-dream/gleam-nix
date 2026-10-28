{ lib }:
src:
# Prepared sources and store-context strings stay opaque at evaluation time.
if !(builtins.isPath src) then
  src
else
  lib.cleanSourceWith {
    inherit src;
    filter =
      path: type:
      lib.cleanSourceFilter path type
      && !(
        type == "directory"
        && dirOf path == toString src
        && builtins.elem (baseNameOf path) [
          "build"
          "_build"
          "node_modules"
          ".direnv"
        ]
      );
  }
