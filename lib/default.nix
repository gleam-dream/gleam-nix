pkgs:
pkgs.lib.makeScope pkgs.newScope (self: {
  inherit (pkgs) gleam;
  beamPackages = pkgs.beamPackages;
  erlang = self.beamPackages.erlang;

  beam = self.callPackage ./beam.nix { };
  cleanSource = self.callPackage ./clean-source.nix { };
  readManifest = self.callPackage ./manifest.nix { };
  buildGleamPackage = self.callPackage ./build-package.nix { };
  importProject = self.callPackage ./import-project.nix { };
  fromBeamPackage = self.beam.fromBeamPackage;
})
