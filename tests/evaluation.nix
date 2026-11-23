{ pkgs, gleam }:
let
  inherit (pkgs) lib;
  a = gleam.importProject { src = ./fixtures/app_a; };
  b = gleam.importProject { src = ./fixtures/app_b; };
  changed = gleam.importProject { src = ./fixtures/app_a_changed; };
  dev = gleam.importProject {
    src = ./fixtures/app_a;
    includeDev = true;
  };
  sourceChanged = gleam.importProject {
    src = ./fixtures/app_a;
    sourceOverrides.shared_lib = ./fixtures/shared_lib_changed;
  };
  rejects =
    args:
    !(builtins.tryEval
      (gleam.importProject (
        {
          src = ./fixtures/app_a;
        }
        // args
      )).package.drvPath
    ).success;
  rejectsManifest = file: rejects { manifest = ./invalid + "/${file}.toml"; };
  conflicting = gleam.buildGleamPackage {
    pname = "conflicting";
    version = "0.1.0";
    src = ./fixtures/app_a;
    beamDeps = [
      a.packages.shared_lib
      sourceChanged.packages.shared_lib
    ];
  };
  otpConflicting = gleam.buildGleamPackage {
    pname = "conflicting";
    version = "0.1.0";
    src = ./fixtures/app_a;
    beamDeps = [
      a.packages.shared_lib
      (gleam.fromBeamPackage {
        package = pkgs.emptyDirectory;
        pname = "another_package";
        version = "0.1.0";
        otpAppName = "shared_lib";
      })
    ];
  };
  differentCompiler = gleam.overrideScope (
    _: prev: {
      gleam = prev.gleam.overrideAttrs (_: {
        pname = "gleam-other";
      });
    }
  );
  incompatible = differentCompiler.buildGleamPackage {
    pname = "incompatible";
    version = "0.1.0";
    src = ./fixtures/app_a;
    beamDeps = [ a.packages.shared_lib ];
  };
  ordered =
    dependencies:
    gleam.buildGleamPackage {
      pname = "order_probe";
      version = "0.1.0";
      src = ./fixtures/app_a;
      beamDeps = dependencies;
    };
  aliasConflicting = gleam.buildGleamPackage {
    pname = "alias_probe";
    version = "0.1.0";
    src = ./fixtures/app_a;
    beamDeps = [
      a.packages.shared_lib
      (gleam.fromBeamPackage {
        package = a.packages.shared_lib;
        pname = "alias";
        version = "0.1.0";
        otpAppName = "shared_lib";
      })
    ];
  };
  metadataConflicting = gleam.buildGleamPackage {
    pname = "metadata_probe";
    version = "0.1.0";
    src = ./fixtures/app_a;
    beamDeps = [
      a.packages.shared_lib
      (a.packages.shared_lib // { beamDeps = [ ]; })
    ];
  };
  opaqueSource = gleam.buildGleamPackage {
    pname = "opaque_probe";
    version = "0.1.0";
    src = "${pkgs.runCommand "source-must-not-build-at-evaluation" { } "exit 99"}/nested";
  };
  foreign =
    args:
    gleam.importProject (
      {
        src = ./fixtures/mixed;
        buildForeign = true;
      }
      // args
    );
  rejectsForeign = args: !(builtins.tryEval (foreign args).package.drvPath).success;
  foreignSources =
    filter:
    # Model a path literal within each realized flake source, rather than an
    # opaque store-context string supplied as an already prepared source.
    /.
    + builtins.unsafeDiscardStringContext (
      builtins.path {
        path = ./fixtures;
        name = "foreign-consumer";
        inherit filter;
      }
    );
  originalForeign = foreign {
    src = foreignSources (_: _: true) + "/mixed";
  };
  editedForeign = foreign {
    src = foreignSources (path: _: path != toString ./fixtures/mixed/src/mixed.gleam) + "/mixed";
  };
  foreignWithoutBuildCache = foreign {
    src = foreignSources (path: _: path != toString ./fixtures/native_math/_build) + "/mixed";
  };
  orderedForeign =
    requirements:
    foreign {
      manifest = builtins.toFile "foreign-order.toml" ''
        packages = [
          { name = "native_math", version = "0.1.0", source = "local", path = "../native_math", build_tools = ["rebar3"], requirements = [], otp_app = "actual_native" },
          { name = "dev_only", version = "0.1.0", source = "local", path = "../dev_only", build_tools = ["gleam"], requirements = [] },
          { name = "elixir_math", version = "0.1.0", source = "local", path = "../elixir_math", build_tools = ["mix"], requirements = ${builtins.toJSON requirements} },
        ]
      '';
    };
  opaqueForeign = foreign {
    sourceOverrides = {
      native_math = pkgs.runCommand "foreign-source-must-not-build-at-evaluation" { } "exit 99";
      elixir_math = "${pkgs.runCommand "mix-source-must-not-build-at-evaluation" { } "exit 99"}/nested";
    };
  };
  gitHashes = import ./fixtures/git_consumer/git-hashes.nix;
  gitConsumer =
    registry:
    gleam.importProject {
      src = ./fixtures/git_consumer;
      sourceOverrides = gleam.gitSources {
        manifest = ./fixtures/git_consumer/manifest.toml;
        inherit registry;
      };
    };
  rejectsGit = registry: !(builtins.tryEval (gitConsumer registry).package.drvPath).success;
  commit = "d43c445b983ab4f67860560ca88d0ff8439ffed3";
  hostSources = gleam.gitSources {
    manifest = ./manifests/git-hosts.toml;
    registry = {
      "git@github.com:gleam-dream/gleam-nix.git".${commit} =
        gitHashes."https://github.com/gleam-dream/gleam-nix.git".${commit};
      "https://github.com/gleam-dream/gleam-nix".${commit} =
        gitHashes."https://github.com/gleam-dream/gleam-nix.git".${commit};
      "https://codeberg.org/example/library.git"."0123456789012345678901234567890123456789" =
        lib.fakeHash;
    };
  };
  plain = source: builtins.unsafeDiscardStringContext (toString source);

  # Refusals of the test, release and JavaScript layers, through their public
  # interfaces. Forcing a value to weak head normal form runs every refusal
  # these functions make, on any system, without a derivation's platform check.
  refuses = value: !(builtins.tryEval (builtins.seq value true)).success;
  tested = gleam.importProject {
    src = ./fixtures/tested;
    includeDev = true;
  };
  testCheck = args: gleam.mkTestCheck ({ project = tested; } // args);
  withGleam =
    version:
    gleam.overrideScope (
      _: prev: {
        gleam = prev.gleam.overrideAttrs {
          inherit version;
          __intentionallyOverridingVersion = true;
        };
      }
    );
  checkWithGleam =
    version:
    (withGleam version).mkTestCheck {
      project = (withGleam version).importProject {
        src = ./fixtures/warn_erlang;
        includeDev = true;
      };
    };
  postgresql = gleam.testServices.postgresql;
  runtime = gleam.trimErlang { without = [ "wx" ]; };
  frontend = args: gleam.buildJavascriptPackage ({ src = ./fixtures/frontend; } // args);
in
lib.runTests {
  testGitSourcesRejectUnlockedEntry = {
    expr = refuses (
      gleam.gitSources {
        manifest = ./manifests/git-unlocked.toml;
        registry = { };
      }
    );
    expected = true;
  };
  testGitSourcesRejectPathsOutsideRepository = {
    expr = refuses (
      gleam.gitSources {
        manifest = ./manifests/git-outside.toml;
        registry = { };
      }
    );
    expected = true;
  };

  testTestCheckRejectsProductionImport = {
    expr = refuses (gleam.mkTestCheck { project = gleam.importProject { src = ./fixtures/tested; }; });
    expected = true;
  };
  testTestCheckAcceptsOnlyPinnedGleam = {
    expr = map (version: refuses (checkWithGleam version)) [
      "1.18.1"
      "1.20.0"
      "1.19.9"
    ];
    expected = [
      true
      true
      false
    ];
  };
  testTestCheckRejectsInvalidServiceName = {
    expr = refuses (testCheck {
      services = [ (postgresql { name = "my-database"; }) ];
    });
    expected = true;
  };
  testTestCheckRejectsRepeatedServiceName = {
    expr = refuses (testCheck {
      services = [
        (postgresql { env = { }; })
        (postgresql { env = { }; })
      ];
    });
    expected = true;
  };
  testTestCheckRejectsClashBetweenServices = {
    expr = refuses (testCheck {
      services = [
        (postgresql { name = "first"; })
        (postgresql {
          name = "second";
          env = { };
          aliases.PGHOST = "127.0.0.1";
        })
      ];
    });
    expected = true;
  };
  testTestCheckRejectsClashWithCheck = {
    expr = refuses (testCheck {
      services = [ (postgresql { }) ];
      env.PGUSER = "someone";
    });
    expected = true;
  };
  testServiceRejectsAliasOfItsOwnName = {
    expr = refuses (postgresql {
      aliases.PGPORT = "5432";
    });
    expected = true;
  };
  testShardRunnerRefusals = {
    expr = map refuses [
      (gleam.testRunners.shard {
        index = 0;
        count = 0;
      })
      (gleam.testRunners.shard {
        index = 2;
        count = 2;
      })
      (gleam.testRunners.shard {
        index = 0;
        count = 2;
        pins.tested = 2;
      })
      (gleam.testRunners.shard {
        index = 0;
        count = 2;
        setup = "no_function";
      })
      (gleam.testRunners.shard {
        index = 0;
        count = 2;
      })
    ];
    expected = [
      true
      true
      true
      true
      false
    ];
  };

  testReleaseRejectsDevelopmentCompile = {
    expr = refuses (
      gleam.buildRelease {
        project = tested;
        inherit runtime;
      }
    );
    expected = true;
  };
  testReleaseRejectsForeignRuntime = {
    expr = refuses (
      gleam.buildRelease {
        project = gleam.importProject { src = ./fixtures/served; };
        runtime = pkgs.hello;
      }
    );
    expected = true;
  };
  testTrimErlangNeedsAnApplication = {
    expr = refuses (gleam.trimErlang { without = [ ]; });
    expected = true;
  };
  testImageRejectsRelativeHealthPath = {
    expr = refuses (
      gleam.buildImage {
        release = gleam.buildRelease {
          project = gleam.importProject { src = ./fixtures/served; };
          inherit runtime;
        };
        name = "served";
        port = 8080;
        health = "health";
        user = "app";
      }
    );
    expected = true;
  };

  testImageRejectsRootUser = {
    expr = map refuses [
      (gleam.buildImage {
        release = gleam.buildRelease {
          project = gleam.importProject { src = ./fixtures/served; };
          inherit runtime;
        };
        name = "served";
        port = 8080;
        health = "/health";
        user = "app";
        uid = 0;
      })
      (gleam.buildImage {
        release = gleam.buildRelease {
          project = gleam.importProject { src = ./fixtures/served; };
          inherit runtime;
        };
        name = "served";
        port = 8080;
        health = "/health";
        user = "root";
      })
    ];
    expected = [
      true
      true
    ];
  };
  testReleaseRejectsPrivOutsideItsDirectory = {
    expr = refuses (
      gleam.buildRelease {
        project = gleam.importProject { src = ./fixtures/served; };
        inherit runtime;
        priv."../escape" = pkgs.emptyDirectory;
      }
    );
    expected = true;
  };

  testImportProjectStaysErlangOnly = {
    expr = refuses (gleam.importProject { src = ./fixtures/frontend; }).package;
    expected = true;
  };
  testJavascriptRejectsErlangTarget = {
    expr = refuses (gleam.buildJavascriptPackage { src = ./fixtures/served; });
    expected = true;
  };
  # The remaining refusals sit in the build script, so force the derivation.
  testJavascriptRejectsHexWithoutChecksum = {
    expr = refuses (frontend { manifest = ./manifests/javascript-no-checksum.toml; }).drvPath;
    expected = true;
  };
  testJavascriptRejectsGitWithoutOverride = {
    expr = refuses (frontend { manifest = ./manifests/javascript-git.toml; }).drvPath;
    expected = true;
  };
  # Only what the frontend's build and tests read is an input: a README or an
  # agent document edit leaves its derivation unchanged.
  testJavascriptIgnoresDocumentation = {
    expr =
      map
        (
          name:
          (gleam.buildJavascriptPackage {
            src =
              /.
              + builtins.unsafeDiscardStringContext (
                builtins.path {
                  path = ./fixtures;
                  name = "fixtures-without-${baseNameOf name}";
                  filter = path: _: !(lib.hasSuffix name path);
                }
              )
              + "/frontend";
          }).drvPath
        )
        [
          "frontend/README.md"
          "frontend/AGENTS.md"
        ];
    expected = map (_: (frontend { }).drvPath) [
      1
      2
    ];
  };
  # An overridden local package needs no original at its locked path.
  testJavascriptAcceptsLocalOverrideWithoutOriginal = {
    expr =
      refuses
        (frontend {
          manifest = ./manifests/javascript-overridden-local.toml;
          sourceOverrides.js_widgets = ./fixtures/js_widgets_override;
        }).drvPath;
    expected = false;
  };
  testJavascriptAcceptsGitWithOverride = {
    expr =
      refuses
        (frontend {
          manifest = ./manifests/javascript-git.toml;
          sourceOverrides.from_git = ./fixtures/shared_lib;
        }).drvPath;
    expected = false;
  };

  testGitSourcesAvoidEvaluationFetch = {
    expr = (builtins.tryEval (gitConsumer gitHashes).package.drvPath).success;
    expected = true;
  };
  testGitSourcesSelectSubdirectory = {
    expr = lib.hasSuffix "-source/tests/fixtures/shared_lib" (
      plain (gitConsumer gitHashes).sources.shared_lib
    );
    expected = true;
  };
  testGitSourcesRejectMissingRepository = {
    expr = rejectsGit { };
    expected = true;
  };
  testGitSourcesRejectMissingCommit = {
    expr = rejectsGit {
      "https://github.com/gleam-dream/gleam-nix.git"."0000000000000000000000000000000000000000" =
        lib.fakeHash;
    };
    expected = true;
  };
  testGitSourcesCoverOnlyGitEntries = {
    expr = lib.attrNames hostSources;
    expected = [
      "bare_https"
      "elsewhere"
      "over_ssh"
    ];
  };
  # One GitHub repository is the same source under each URL form.
  testGitSourcesNormalizeGitHubUrls = {
    expr = plain hostSources.over_ssh == plain hostSources.bare_https;
    expected = true;
  };
  testGitSourcesFetchOtherHostsWithGit = {
    expr =
      let
        source = plain hostSources.elsewhere;
      in
      lib.hasSuffix "/packages/library" source && source != plain hostSources.bare_https;
    expected = true;
  };

  testForeignPackageDropsRequirementsGleamNeverLocked = {
    expr = (builtins.head (gleam.readManifest ./manifests/optional.toml).packages).requirements;
    expected = [
      "gleam_stdlib"
      "telemetry"
    ];
  };
  testOpaqueSourceAvoidsIfd = {
    expr = (builtins.tryEval opaqueSource.drvPath).success;
    expected = true;
  };
  testRootArgumentsCannotReplaceGraph = {
    expr = rejects { packageArgs.beamDeps = [ ]; };
    expected = true;
  };
  testPackageOverridePreservesLockedIdentity = {
    expr = rejects {
      packageOverrides = _: _: {
        shared_lib = gleam.fromBeamPackage {
          package = a.packages.shared_lib;
          pname = "renamed";
          version = "9.9.9";
          otpAppName = "different_app";
          beamDeps = [ ];
        };
      };
    };
    expected = true;
  };
  testPackageOverridePreservesLockedEdges = {
    expr = rejects {
      packageOverrides = _: _: {
        shared_lib = a.packages.shared_lib // {
          beamDeps = [ ];
        };
      };
    };
    expected = true;
  };
  testDependencyOrderingDoesNotChangeCache = {
    expr =
      (ordered [
        a.packages.gleam_stdlib
        a.packages.dev_only
      ]).drvPath;
    expected =
      (ordered [
        a.packages.dev_only
        a.packages.gleam_stdlib
      ]).drvPath;
  };
  testCrossProjectCache = {
    expr = a.packages.shared_lib.drvPath;
    expected = b.packages.shared_lib.drvPath;
  };
  testTransitiveCrossProjectCache = {
    expr = a.packages.gleam_stdlib.drvPath;
    expected = b.packages.gleam_stdlib.drvPath;
  };
  testApplicationChanges = {
    expr = a.package.drvPath != changed.package.drvPath;
    expected = true;
  };
  testApplicationEditKeepsDependency = {
    expr = a.packages.shared_lib.drvPath;
    expected = changed.packages.shared_lib.drvPath;
  };
  testSourceOverrideInvalidatesDependency = {
    expr = a.packages.shared_lib.drvPath != sourceChanged.packages.shared_lib.drvPath;
    expected = true;
  };
  testSourceOverrideInvalidatesConsumer = {
    expr = a.package.drvPath != sourceChanged.package.drvPath;
    expected = true;
  };
  testSourceOverrideKeepsOtherDependency = {
    expr = a.packages.gleam_stdlib.drvPath;
    expected = sourceChanged.packages.gleam_stdlib.drvPath;
  };
  testProductionDependencies = {
    expr = map (package: package.gleamPackageName) a.package.beamDeps;
    expected = [ "shared_lib" ];
  };
  testDevelopmentDependencies = {
    expr = map (package: package.gleamPackageName) dev.package.beamDeps;
    expected = [
      "dev_only"
      "shared_lib"
    ];
  };
  testDevelopmentModeKeepsCompiledDependencies = {
    expr = a.packages.shared_lib.drvPath;
    expected = dev.packages.shared_lib.drvPath;
  };
  testDependencyGraphComesFromManifest = {
    expr = map (package: package.gleamPackageName) a.packages.shared_lib.beamDeps;
    expected = [ "gleam_stdlib" ];
  };
  testDuplicatePackages = {
    expr = rejectsManifest "duplicate";
    expected = true;
  };
  testMissingEdge = {
    expr = rejectsManifest "missing";
    expected = true;
  };
  testCycle = {
    expr = rejectsManifest "cycle";
    expected = true;
  };
  testSelfCycle = {
    expr = !(builtins.tryEval (gleam.readManifest ./invalid/self-cycle.toml)).success;
    expected = true;
  };
  testMalformedRecord = {
    expr = rejectsManifest "malformed";
    expected = true;
  };
  testRootDependencyMissing = {
    expr = rejectsManifest "empty";
    expected = true;
  };
  testGitNeedsSourceOverride = {
    expr = rejectsManifest "git";
    expected = true;
  };
  testUnsupportedBuildTool = {
    expr = rejectsManifest "rebar";
    expected = true;
  };
  testUnknownSourceOverride = {
    expr = rejects { sourceOverrides.typo = ./fixtures/shared_lib; };
    expected = true;
  };
  testConflictingPackageOutputs = {
    expr = !(builtins.tryEval conflicting.drvPath).success;
    expected = true;
  };
  testConflictingOtpOutputs = {
    expr = !(builtins.tryEval otpConflicting.drvPath).success;
    expected = true;
  };
  testSameOutputCannotHideConflictingAlias = {
    expr = !(builtins.tryEval aliasConflicting.drvPath).success;
    expected = true;
  };
  testSameOutputCannotHideConflictingDependencies = {
    expr = !(builtins.tryEval metadataConflicting.drvPath).success;
    expected = true;
  };
  testIncompatibleCompiler = {
    expr = !(builtins.tryEval incompatible.drvPath).success;
    expected = true;
  };
  testUnsupportedTarget = {
    expr = rejects { src = ./fixtures/javascript; };
    expected = true;
  };
  testForeignBuildsAreOptIn = {
    expr =
      !(builtins.tryEval (gleam.importProject { src = ./fixtures/mixed; }).package.drvPath).success;
    expected = true;
  };
  testForeignBuildPreservesLockedEdges = {
    expr = map (package: package.gleamPackageName) (foreign { }).packages.elixir_math.beamDeps;
    expected = [ "native_math" ];
  };
  testForeignArgumentsCannotReplaceLockedName = {
    expr = rejectsForeign { foreignArgs.native_math.name = "actual_native"; };
    expected = true;
  };
  testForeignArgumentsCannotReplaceLockedVersion = {
    expr = rejectsForeign { foreignArgs.native_math.version = "0.1.0"; };
    expected = true;
  };
  testForeignArgumentsCannotReplaceLockedSource = {
    expr = rejectsForeign { foreignArgs.native_math.src = ./fixtures/native_math; };
    expected = true;
  };
  testForeignArgumentsCannotReplaceLockedDependencies = {
    expr = rejectsForeign { foreignArgs.native_math.beamDeps = [ ]; };
    expected = true;
  };
  testForeignArgumentsNameLockedPackages = {
    expr =
      !(builtins.tryEval
        (gleam.importProject {
          src = ./fixtures/mixed;
          buildForeign = true;
          foreignArgs.undeclared = { };
        }).package.drvPath
      ).success;
    expected = true;
  };
  testLocalRebarSourceExcludesConsumerChanges = {
    expr = originalForeign.packages.native_math.drvPath;
    expected = editedForeign.packages.native_math.drvPath;
  };
  testForeignConsumerEditChangesApplication = {
    expr = originalForeign.package.drvPath != editedForeign.package.drvPath;
    expected = true;
  };
  testLocalMixSourceExcludesConsumerChanges = {
    expr = originalForeign.packages.elixir_math.drvPath;
    expected = editedForeign.packages.elixir_math.drvPath;
  };
  testLocalForeignBuildArtifactsDoNotChangeCache = {
    expr = originalForeign.packages.native_math.drvPath;
    expected = foreignWithoutBuildCache.packages.native_math.drvPath;
  };
  testForeignDependencyOrderingDoesNotChangeCache = {
    expr =
      (orderedForeign [
        "native_math"
        "dev_only"
      ]).packages.elixir_math.drvPath;
    expected =
      (orderedForeign [
        "dev_only"
        "native_math"
      ]).packages.elixir_math.drvPath;
  };
  testOpaqueForeignSourcesAvoidIfd = {
    expr = (builtins.tryEval opaqueForeign.package.drvPath).success;
    expected = true;
  };
}
