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
      # The README's whole service setup, built by the checks.
      service = (import ./examples/service/flake.nix).outputs {
        self = service;
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
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          # The README's service: its shards against PostgreSQL, coverage and
          # image all build.
          service-example = pkgs.writeText "gleam-nix-service-example" (
            builtins.concatStringsSep "\n" (
              map (result: result.outPath) (
                builtins.attrValues service.checks.${system} ++ [ service.packages.${system}.image ]
              )
            )
          );
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
