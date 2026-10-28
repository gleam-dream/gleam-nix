{ pkgs, gleam }:
let
  backend = (gleam.importProject { src = ./hello; }).package;
  assets = pkgs.buildNpmPackage {
    pname = "gleam-nix-assets";
    version = "0.1.0";
    src = ./assets;
    npmDeps = pkgs.importNpmLock { npmRoot = ./assets; };
    npmConfigHook = pkgs.importNpmLock.npmConfigHook;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp dist/index.html "$out/"
      runHook postInstall
    '';
  };
  combined = pkgs.symlinkJoin {
    name = "gleam-nix-composition";
    paths = [ backend ];
    postBuild = ''
      mkdir -p "$out/share/www"
      ln -s ${assets}/index.html "$out/share/www/index.html"
    '';
  };
in
{
  inherit backend assets combined;
}
