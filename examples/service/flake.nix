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
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      gleam = gleam-nix.lib.mkLib pkgs;
      ci = gleam-nix.lib.ci pkgs;
      tested = gleam.importProject {
        src = ./.;
        includeDev = true;
      };
      database = gleam.testServices.postgresql {
        package = pkgs.postgresql_17;
        aliases.DATABASE_URL = "postgresql://postgres@127.0.0.1:$SERVICE_PORT/postgres";
      };
      shards =
        map
          (
            runner:
            gleam.mkTestCheck {
              project = tested;
              inherit runner;
              services = [ database ];
            }
          )
          (
            gleam.testRunners.shards {
              count = 4;
              setup = "my_app_test.setup";
            }
          );
      release = gleam.buildRelease {
        project = gleam.importProject { src = ./.; };
        runtime = gleam.trimErlang {
          without = [
            "wx"
            "observer"
            "debugger"
            "et"
          ];
        };
      };
    in
    {
      checks.${system} = builtins.listToAttrs (
        pkgs.lib.imap1 (index: check: {
          name = "shard-${toString index}";
          value = check;
        }) shards
      );
      packages.${system}.image = gleam.buildImage {
        inherit release;
        name = "my-service";
        port = 8080;
        health = "/health";
        user = "app";
      };
      ci.${system} = ci.declare {
        adapter = ci.adapters.cachix {
          name = "my-cache";
          publicKey = "my-cache.cachix.org-1:...";
        };
        checks = self.checks.${system} // {
          image = self.packages.${system}.image;
        };
        derived.coverage = gleam.mkCoverageCheck { checks = shards; };
      };
    };
}
