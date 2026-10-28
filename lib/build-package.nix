{
  lib,
  stdenvNoCC,
  gleam,
  erlang,
  beam,
  linkFarm,
  writeText,
  cleanSource,
}:
lib.makeOverridable (
  {
    pname,
    version,
    src,
    beamDeps ? [ ],
    otpAppName ? pname,
    includeDev ? false,
    nativeBuildInputs ? [ ],
    propagatedBuildInputs ? [ ],
    passthru ? { },
    ...
  }@args:
  let
    name = beam.checkedName "package" pname;
    applicationName = beam.checkedName "OTP application" otpAppName;
    dependencies = beam.closure beamDeps;
    directDependencies = lib.unique (beam.sortPackages beamDeps);
    libraries = linkFarm "gleam-libraries-${name}" (
      map (package: {
        name = beam.otpName package;
        path = "${package}/${beam.appDir package}";
      }) dependencies
    );
    appDirectory = "lib/erlang/lib/${applicationName}-${version}";
    compileDirectory = "compiled/${applicationName}";
    applicationMappings = lib.concatMapStringsSep "," (
      package: "${beam.packageName package}=${beam.otpName package}"
    ) dependencies;
    standardArgs = builtins.removeAttrs args [
      "beamDeps"
      "otpAppName"
      "includeDev"
      "nativeBuildInputs"
      "propagatedBuildInputs"
      "passthru"
    ];
  in
  assert lib.assertMsg (lib.versionAtLeast gleam.version "1.19")
    "gleam-nix: Gleam 1.19 or newer is required.";
  builtins.seq dependencies (
    stdenvNoCC.mkDerivation (
      standardArgs
      // {
        pname = name;
        inherit version;
        src = cleanSource src;
        nativeBuildInputs = [
          gleam
          erlang
        ]
        ++ nativeBuildInputs;
        propagatedBuildInputs = lib.unique (directDependencies ++ propagatedBuildInputs);
        strictDeps = args.strictDeps or true;
        dontConfigure = args.dontConfigure or true;
        # Preserve standard fixup: it installs setup hooks and dependency references.
        # BEAM bytecode needs none of the native-binary transforms below.
        dontStrip = args.dontStrip or true;
        dontPatchELF = args.dontPatchELF or true;
        dontPatchShebangs = args.dontPatchShebangs or true;

        env = {
          ERL_LIBS = toString libraries;
          ERL_COMPILER_OPTIONS = "[deterministic]";
        }
        // (args.env or { });

        setupHook =
          args.setupHook or (writeText "gleam-beam-setup-hook.sh" ''
            addToSearchPath ERL_LIBS "$1/lib/erlang/lib"
          '');

        buildPhase =
          args.buildPhase or ''
            runHook preBuild
            # include_lib resolves the current package by its OTP directory name.
            mkdir -p ${lib.escapeShellArg compileDirectory}/ebin
            export ERL_LIBS="$PWD/compiled''${ERL_LIBS:+:$ERL_LIBS}"
            gleam compile-package \
              --target erlang \
              ${lib.optionalString (!includeDev) "--no-dev"} \
              --package . \
              --out ${lib.escapeShellArg compileDirectory} \
              --lib ${lib.escapeShellArg (toString libraries)} \
              --otp-app-names ${lib.escapeShellArg applicationMappings}
            runHook postBuild
          '';

        installPhase =
          args.installPhase or ''
            runHook preInstall
            test -f ${lib.escapeShellArg compileDirectory}/ebin/${lib.escapeShellArg applicationName}.app
            mkdir -p "$out"/${lib.escapeShellArg appDirectory} "$out/src"
            # Gleam links priv/include to the build tree; materialize those links.
            cp -RL ${lib.escapeShellArg compileDirectory}/. "$out"/${lib.escapeShellArg appDirectory}/
            # Match Nixpkgs' BEAM convention: retain patched source without outputs.
            for entry in .[^.]* *; do
              if [ -e "$entry" ] && [ "$entry" != compiled ]; then
                cp -R "$entry" "$out/src/"
              fi
            done
            runHook postInstall
          '';

        passthru = passthru // {
          inherit includeDev;
          beamDeps = directDependencies;
          gleamPackageName = name;
          otpAppName = applicationName;
          beamAppDir = appDirectory;
          gleamCompiler = gleam;
          erlangCompiler = erlang;
        };

        meta = {
          platforms = erlang.meta.platforms;
        }
        // (args.meta or { });
      }
    )
  )
)
