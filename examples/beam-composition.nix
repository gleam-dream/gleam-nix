{ gleam, src }:
let
  inherit (gleam) beamPackages;
  project = gleam.importProject {
    inherit src;
    packageOverrides = _final: _prev: {
      native_math = gleam.fromBeamPackage {
        pname = "native_math";
        version = "0.1.0";
        otpAppName = "actual_native";
        package = beamPackages.buildRebar3 {
          name = "actual_native";
          version = "0.1.0";
          src = project.sources.native_math;
        };
      };
      elixir_math = gleam.fromBeamPackage {
        pname = "elixir_math";
        version = "0.1.0";
        package = beamPackages.buildMix {
          name = "elixir_math";
          version = "0.1.0";
          src = project.sources.elixir_math;
        };
      };
    };
  };
in
project
