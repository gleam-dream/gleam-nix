# Checks of the test layer (D7 to D9). Test checks run on Linux only.
{ pkgs, gleam }:
let
  inherit (pkgs) lib;
  import' =
    src:
    gleam.importProject {
      inherit src;
      includeDev = true;
    };
  tested = import' ./fixtures/tested;
  shards = gleam.testRunners.shards {
    count = 2;
    setup = "tested_test.setup";
    # A pinned module makes each shard's content known to the coverage checks.
    pins."tested/alpha_test" = 1;
  };
  default = gleam.mkTestCheck { project = tested; };
  sharded = map (
    runner:
    gleam.mkTestCheck {
      project = tested;
      inherit runner;
    }
  ) shards;

  # The same fixture with one file left out, as a realized flake source.
  without =
    name:
    import' (
      /.
      + builtins.unsafeDiscardStringContext (
        builtins.path {
          path = ./fixtures;
          name = "fixtures-without-${baseNameOf name}";
          filter = path: _: !(lib.hasSuffix name path);
        }
      )
      + "/tested"
    );
  withoutAgents = gleam.mkTestCheck { project = without "tested/AGENTS.md"; };
  withoutAlpha = gleam.mkTestCheck { project = without "tested/test/tested/alpha_test.gleam"; };

  postgresql =
    args:
    gleam.mkTestCheck (
      {
        project = import' ./fixtures/with_postgres;
      }
      // args
    );
  roleAndDatabases = postgresql {
    services = [
      (gleam.testServices.postgresql {
        package = pkgs.postgresql_16;
        init = ''
          create role app login;
          create database app_test owner app;
          create database app_dev owner app;
        '';
        env = {
          PGHOST = "127.0.0.1";
          PGPORT = "$SERVICE_PORT";
          PGUSER = "app";
          PGDATABASE = "app_test";
        };
      })
    ];
    env.EXPECTED = "app app_test 16";
  };
  connectionUrl = postgresql {
    services = [
      (gleam.testServices.postgresql {
        package = pkgs.postgresql_17;
        env = { };
        aliases.DATABASE_URL = "postgresql://postgres@127.0.0.1:$SERVICE_PORT/postgres";
      })
    ];
    env.EXPECTED = "postgres postgres 17";
  };
  failingWithService = postgresql {
    services = [ (gleam.testServices.postgresql { package = pkgs.postgresql_17; }) ];
    env.EXPECTED = "nobody nowhere 0";
  };

  failures = lib.runTests {
    testShardsShareOneCompile = {
      expr = lib.unique (map (check: check.compiled.drvPath) (sharded ++ [ default ]));
      expected = [ default.compiled.drvPath ];
    };
    # Only what the build and the tests read is an input: a README or a docs
    # directory edit rebuilds neither the test check nor the root package.
    testDocumentationLeavesChecksCached = {
      expr = map (name: (gleam.mkTestCheck { project = without name; }).drvPath) [
        "tested/README.md"
        "tested/docs/notes.md"
      ];
      expected = [
        default.drvPath
        default.drvPath
      ];
    };
    testDocumentationLeavesPackageCached = {
      expr = map (name: (without name).package.drvPath) [
        "tested/README.md"
        "tested/docs/notes.md"
      ];
      expected = [
        tested.package.drvPath
        tested.package.drvPath
      ];
    };
    testAgentDocumentsLeaveChecksCached = {
      expr = withoutAgents.drvPath;
      expected = default.drvPath;
    };
    testTestEditRebuildsOnlyTheRoot = {
      expr = {
        root = withoutAlpha.compiled.drvPath != default.compiled.drvPath;
        dependencies = lib.mapAttrs (
          _: package: package.drvPath
        ) (without "tested/test/tested/alpha_test.gleam").packages;
      };
      expected = {
        root = true;
        dependencies = lib.mapAttrs (_: package: package.drvPath) tested.packages;
      };
    };
  };

  # A build expected to fail, and what its log must say.
  failsWith =
    name: derivation: patterns:
    let
      failure = pkgs.testers.testBuildFailure derivation;
    in
    pkgs.runCommand "gleam-nix-${name}" { } ''
      log=${failure}/testBuildFailure.log
      test "$(cat ${failure}/testBuildFailure.exit)" -ne 0
      ${lib.concatMapStrings (pattern: ''
        if ! grep -qF -- ${lib.escapeShellArg pattern} "$log"; then
          echo "missing from the failure log: "${lib.escapeShellArg pattern} >&2
          cat "$log" >&2
          exit 1
        fi
      '') patterns}
      touch "$out"
    '';
  reportOf = check: "${check}/report";
  panicking = import' ./fixtures/panicking;
in
{
  test-layer-evaluation =
    assert failures == [ ];
    pkgs.runCommand "gleam-nix-test-layer-evaluation" { } ''
      touch "$out"
    '';

  test-runner-default = default;

  # Both runners run the same modules with the same verdicts, and the shard
  # runner's setup hook does the work of the test main.
  test-runners-agree = pkgs.runCommand "gleam-nix-test-runners-agree" { } ''
    cut -f1,2 ${reportOf default} > default
    cat ${lib.concatMapStringsSep " " reportOf sharded} | cut -f1,2 | LC_ALL=C sort > sharded
    diff default sharded
    grep -Fx 'tested@alpha_test	passed' default
    grep -Fx 'beta_test	passed' default
    # The pinned module sits in its shard.
    grep -Fx 'tested@alpha_test' ${builtins.elemAt sharded 1}/shard
    touch "$out"
  '';

  test-coverage = gleam.mkCoverageCheck { checks = sharded; };
  test-coverage-missing =
    failsWith "test-coverage-missing"
      (gleam.mkCoverageCheck {
        name = "coverage-missing";
        checks = [ (builtins.head sharded) ];
      })
      [
        "ran in no check:"
        "  tested@alpha_test"
      ];
  test-coverage-duplicated =
    failsWith "test-coverage-duplicated"
      (gleam.mkCoverageCheck {
        name = "coverage-duplicated";
        checks = sharded ++ [ default ];
      })
      [
        "ran in more than one check:"
        "  tested@alpha_test (tested-shard-2-of-2, tested-test)"
      ];

  # Adding a module moves no other module between shards.
  # Adding a test module moves no other module between shards: the same
  # project with and without tested/alpha_test, through each check's own
  # shard output.
  test-shard-membership =
    let
      shardsOf =
        project:
        map (runner: gleam.mkTestCheck { inherit project runner; }) (
          gleam.testRunners.shards {
            count = 3;
            setup = "tested_test.setup";
          }
        );
      before = shardsOf (without "tested/test/tested/alpha_test.gleam");
      after = shardsOf tested;
    in
    pkgs.runCommand "gleam-nix-test-shard-membership" { } (
      lib.concatStrings (
        lib.zipListsWith (old: new: ''
          { grep -vFx tested@alpha_test ${new}/shard || [ "$?" -eq 1 ]; } | diff ${old}/shard -
        '') before after
      )
      + ''
        cat ${lib.concatMapStringsSep " " (check: "${check}/shard") after} | grep -Fx tested@alpha_test
        touch "$out"
      ''
    );

  # A pin that names no test module fails the shard instead of being dropped.
  test-shard-unmatched-pin = failsWith "test-shard-unmatched-pin" (gleam.mkTestCheck {
    project = tested;
    runner = gleam.testRunners.shard {
      index = 0;
      count = 2;
      setup = "tested_test.setup";
      pins."tested/alfa_test" = 1;
    };
  }) [ "gleam-nix: shard pins name no test module: tested@alfa_test." ];

  test-gleam-warnings =
    failsWith "test-gleam-warnings"
      (gleam.mkTestCheck {
        project = import' ./fixtures/warn_gleam;
      }).compiled
      [
        "warning: Unused variable"
        "gleam-nix: Gleam warnings in warn_gleam fail its test check."
      ];
  test-erlang-warnings =
    failsWith "test-erlang-warnings"
      (gleam.mkTestCheck {
        project = import' ./fixtures/warn_erlang;
      }).compiled
      [
        "variable 'Unused' is unused"
        "gleam-nix: Erlang warnings in warn_erlang fail its test check."
      ];

  test-panic-default = failsWith "test-panic-default" (gleam.mkTestCheck { project = panicking; }) [
    "boom from a fixture"
    "exploding_test"
    "gleam-nix: tests of panicking failed under test."
  ];
  test-panic-shard =
    failsWith "test-panic-shard"
      (gleam.mkTestCheck {
        project = panicking;
        runner = gleam.testRunners.shard {
          index = 0;
          count = 1;
        };
      })
      [
        "boom from a fixture"
        "exploding_test"
        "gleam-nix: tests of panicking failed under shard-1-of-1."
      ];

  # A panic outside any test prints Gleam's runtime error with its stack trace.
  test-main-panic-default =
    failsWith "test-main-panic-default"
      (gleam.mkTestCheck {
        project = panicking;
        env.PANIC_IN_MAIN = "1";
      })
      [
        "runtime error"
        "setup failed in a fixture"
        "stacktrace:"
        "panicking_test.main"
        "test/panicking_test.gleam:12"
      ];
  test-main-panic-shard =
    failsWith "test-main-panic-shard"
      (gleam.mkTestCheck {
        project = panicking;
        runner = gleam.testRunners.shard {
          index = 0;
          count = 1;
          setup = "panicking_test.fail_setup";
        };
      })
      [
        "runtime error"
        "setup failed in a fixture"
        "stacktrace:"
        "panicking_test.fail_setup"
      ];

  test-postgresql-role = roleAndDatabases;
  test-postgresql-url = connectionUrl;
  test-service-log = failsWith "test-service-log" failingWithService [
    "gleam-nix: log of service postgresql:"
    "database system is ready to accept connections"
  ];

  # Brittle surfaces the runners copy: Gleam's generated entry module and
  # gleeunit's eunit options. A Gleam or gleeunit release that changes either
  # fails here, not in an adopter.
  test-pins =
    pkgs.runCommand "gleam-nix-test-pins"
      {
        nativeBuildInputs = [
          gleam.gleam
          gleam.erlang
        ];
      }
      ''
        export HOME="$TMPDIR"
        cp -R ${./fixtures/main_pin} main_pin
        chmod -R u+w main_pin
        (cd main_pin && gleam run > /dev/null)
        tail -n +3 ${../lib/gleam-main.erl} | sed 's/__GLEAM_APP__/main_pin/g' > expected
        diff expected main_pin/build/dev/erlang/main_pin/_gleam_artefacts/main_pin@@main.erl

        options() { tr -d ' \n' | grep -o '\[verbose,no_tty,[^]]*\]'; }
        upstream=$(options < ${tested.packages.gleeunit}/src/src/gleeunit.erl)
        copied=$(options < ${../lib/test/support/gleam_nix_shard.erl})
        test -n "$upstream"
        test "$upstream" = "$copied"
        touch "$out"
      '';
}
