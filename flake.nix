{
  description = "Independent, cacheable Gleam package builds from manifest.toml";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forSystems = nixpkgs.lib.genAttrs systems;
      mkLib = import ./lib;
      quickstart = (import ./examples/hello/flake.nix).outputs {
        self = quickstart;
        inherit nixpkgs;
        gleam-nix.lib.mkLib = mkLib;
      };
    in
    {
      lib = { inherit mkLib; };
      checks = forSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        import ./tests {
          inherit pkgs;
          gleam = mkLib pkgs;
          exampleShell = quickstart.devShells.${system}.default;
        }
      );
      packages = forSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          example = import ./examples/composition.nix {
            inherit pkgs;
            gleam = mkLib pkgs;
          };
        in
        {
          default = example.backend;
          frontend = example.assets;
          combined = example.combined;
        }
      );
      devShells = quickstart.devShells;
      formatter = forSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
