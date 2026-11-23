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
      # The README's whole service setup, evaluated by the checks.
      service = (import ./examples/service/flake.nix).outputs {
        self = service;
        inherit nixpkgs;
        gleam-nix.lib = {
          inherit mkLib;
          ci = pkgs: import ./ci { inherit pkgs; };
        };
      };
    in
    {
      lib = {
        inherit mkLib;
        # The CI layer, apart from the Gleam scope and versioned on its own.
        ci = pkgs: import ./ci { inherit pkgs; };
      };
      # This repository's own CI declaration: two shards sharing a compile, the
      # default runner, and coverage derived from the shards.
      ci = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
        system:
        let
          checks = self.checks.${system};
          ci = import ./ci { pkgs = nixpkgs.legacyPackages.${system}; };
        in
        ci.declare {
          adapter = ci.adapters.local;
          checks = {
            inherit (checks) test-shard-1 test-shard-2 test-runner-default;
          };
          derived = {
            inherit (checks) test-coverage;
          };
        }
      );
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
          # Every declared result of the README's service builds: its shards
          # against PostgreSQL, the image, and coverage.
          service-example =
            let
              declaration = service.ci.${system};
              results = declaration.checks // declaration.derived;
            in
            pkgs.writeText "gleam-nix-service-example" (
              builtins.concatStringsSep "\n" (map (check: check.outPath) (builtins.attrValues results))
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
          ci = (import ./ci { inherit pkgs; }).commands;
          default = example.backend;
          frontend = example.assets;
          combined = example.combined;
        }
      );
      devShells = quickstart.devShells;
      formatter = forSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
