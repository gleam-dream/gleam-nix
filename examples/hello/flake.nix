{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.gleam-nix = {
    url = "github:gleam-dream/gleam-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      gleam-nix,
      ...
    }:
    let
      forSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
    in
    {
      packages = forSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          gleam = gleam-nix.lib.mkLib pkgs;
        in
        {
          default = (gleam.importProject { src = ./.; }).package;
        }
      );
      devShells = forSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          gleam = gleam-nix.lib.mkLib pkgs;
        in
        {
          default = pkgs.mkShell {
            nativeBuildInputs = [ gleam.erlang ];
            buildInputs = [ self.packages.${system}.default ];
          };
        }
      );
    };
}
