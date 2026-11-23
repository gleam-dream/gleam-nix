# The CI layer (D12, D13). It contains no Gleam: it reads only a CI
# declaration and a cache adapter, and carries its own compatibility version.
{ pkgs }:
let
  inherit (pkgs) lib;
  version = "1";

  commands =
    pkgs.runCommand "gleam-nix-ci-${version}"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        passthru.evaluator = pkgs.nix-eval-jobs;
        meta.mainProgram = "gleam-nix-ci";
      }
      ''
        mkdir -p "$out/bin"
        install -m 755 ${./gleam-nix-ci.sh} "$out/bin/gleam-nix-ci"
        patchShebangs "$out/bin/gleam-nix-ci"
        wrapProgram "$out/bin/gleam-nix-ci" \
          --prefix PATH : ${
            lib.makeBinPath [
              pkgs.jq
              pkgs.coreutils
              pkgs.gawk
            ]
          } \
          --set-default GLEAM_NIX_CI_EVAL ${pkgs.nix-eval-jobs}/bin/nix-eval-jobs
      '';

  # A cache adapter: adapter.json (name, substituter, public key, declared
  # scope) and bin/setup, bin/push and bin/teardown. setup exits 0 when the
  # run can push and 3 when it can only read.
  mkAdapter =
    {
      name,
      substituter,
      publicKey ? null,
      scope,
      setup,
      push,
      teardown ? "",
      runtimeInputs ? [ ],
    }:
    let
      script =
        part: text:
        pkgs.writeShellApplication {
          name = part;
          inherit runtimeInputs text;
        };
    in
    pkgs.runCommand "gleam-nix-ci-adapter-${name}"
      {
        passthru = { inherit name scope; };
      }
      ''
        mkdir -p "$out/bin"
        cp ${
          pkgs.writeText "adapter.json" (
            builtins.toJSON {
              inherit
                name
                substituter
                publicKey
                scope
                ;
            }
          )
        } "$out/adapter.json"
        ln -s ${script "setup" setup}/bin/setup "$out/bin/setup"
        ln -s ${script "push" push}/bin/push "$out/bin/push"
        ln -s ${
          script "teardown" (if teardown == "" then "true" else teardown)
        }/bin/teardown "$out/bin/teardown"
      '';

  adapters = {
    inherit mkAdapter;

    # Cachix: public caches need no secret to read; CACHIX_AUTH_TOKEN writes.
    cachix =
      { name, publicKey }:
      mkAdapter {
        name = "cachix:${name}";
        substituter = "https://${name}.cachix.org";
        inherit publicKey;
        scope = {
          read = "anyone the cache admits (a public cache needs no secret)";
          write = "a holder of the cache's write token";
          mergeHit = true;
        };
        runtimeInputs = [ pkgs.cachix ];
        setup = ''
          if [ -n "''${CACHIX_AUTH_TOKEN:-}" ]; then exit 0; fi
          exit 3
        '';
        push = ''
          cachix push ${lib.escapeShellArg name} "$@"
        '';
      };

    # Attic: ATTIC_TOKEN with push rights on the cache writes.
    attic =
      {
        server,
        cache,
        publicKey,
      }:
      mkAdapter {
        name = "attic:${cache}";
        substituter = "${lib.removeSuffix "/" server}/${cache}";
        inherit publicKey;
        scope = {
          read = "anyone the cache admits";
          write = "a holder of a token with push rights on the cache";
          mergeHit = true;
        };
        runtimeInputs = [ pkgs.attic-client ];
        setup = ''
          if [ -z "''${ATTIC_TOKEN:-}" ]; then exit 3; fi
          attic login gleam-nix-ci ${lib.escapeShellArg server} "$ATTIC_TOKEN" > /dev/null
        '';
        push = ''
          attic push ${lib.escapeShellArg "gleam-nix-ci:${cache}"} "$@"
        '';
      };

    # A store local to one workflow run, carried between its jobs as workflow
    # artifacts in $GLEAM_NIX_CI_LOCAL_STORE. Every run of it is degraded.
    local = mkAdapter {
      name = "run-local";
      substituter = "local";
      scope = {
        read = "jobs of the same workflow run";
        write = "jobs of the same workflow run";
        mergeHit = false;
      };
      setup = "exit 3";
      push = "exit 3";
    };
  };

  # A CI declaration: the checks to plan, the checks that always run, the
  # derived checks built from them in verify, and the external jobs planning
  # gates. Job names are the attribute names.
  declare =
    {
      adapter,
      checks ? { },
      always ? { },
      derived ? { },
      external ? { },
    }:
    let
      jobs = lib.attrNames checks ++ lib.attrNames always ++ lib.attrNames external;
      repeated = lib.attrNames (
        lib.filterAttrs (_: names: builtins.length names > 1) (lib.groupBy (n: n) jobs)
      );
      reserved = builtins.filter (name: name == "shared") jobs;
    in
    if repeated != [ ] then
      throw "gleam-nix-ci: job names must be distinct across checks, always and external: ${lib.concatStringsSep ", " repeated}."
    else if reserved != [ ] then
      throw "gleam-nix-ci: the job name shared is reserved for shared builds."
    else
      {
        inherit
          version
          adapter
          checks
          always
          derived
          external
          ;
      };

  # The result an external job pushes when it passes. Its inputs decide its
  # store path, so an unchanged input set finds it cached and plan skips the
  # job. Its presence is trusted by convention, not proved.
  externalMarker =
    { name, inputs }:
    pkgs.runCommand "gleam-nix-ci-external-${name}" { inherit inputs; } ''
      printf '%s\n' $inputs > "$out"
    '';
in
{
  inherit
    version
    commands
    adapters
    declare
    externalMarker
    ;
}
