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
in
lib.runTests {
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
