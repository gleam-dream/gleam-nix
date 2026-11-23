pkgs:
pkgs.lib.makeScope pkgs.newScope (self: {
  inherit (pkgs) gleam;
  beamPackages = pkgs.beamPackages;
  erlang = self.beamPackages.erlang;

  beam = self.callPackage ./beam.nix { };
  cleanSource = self.callPackage ./clean-source.nix { };
  gleamSource = self.callPackage ./gleam-source.nix { };
  readManifest = self.callPackage ./manifest.nix { };
  buildGleamPackage = self.callPackage ./build-package.nix { };
  importProject = self.callPackage ./import-project.nix { };
  warningsGate = self.callPackage ./warnings-gate.nix { };
  gitSources = self.callPackage ./git-sources.nix { };
  fromBeamPackage = self.beam.fromBeamPackage;

  # Test layer (D7 to D9).
  testSupport = self.callPackage ./test/support.nix { };
  testRunners = self.callPackage ./test/runners.nix { };
  testServices = self.callPackage ./test/services.nix { };
  mkTestCheck = self.callPackage ./test/check.nix { };
  mkCoverageCheck = self.callPackage ./test/coverage.nix { };

  # Release and image (D10). Unstable.
  trimErlang = self.callPackage ./release/trim-erlang.nix { };
  buildRelease = self.callPackage ./release/release.nix { };
  buildImage = self.callPackage ./release/image.nix { };

  # JavaScript entry point (D11). Unstable.
  buildJavascriptPackage = self.callPackage ./javascript.nix { };
})
