{
  lib,
  stdenvNoCC,
  gleam,
  nodejs,
  beamPackages,
  readManifest,
  xxHash,
  gleamSource,
}:
# Builds a Gleam project for the JavaScript target and runs its tests with
# Node. It is a separate entry point: nothing in the Erlang graph depends on it.
# Its locked Hex sources are fetched as in importProject and laid out where
# Gleam looks for downloaded packages, so the build runs offline. npm
# dependencies come from a separate derivation passed as `nodeModules`.
{
  src,
  manifest ? src + "/manifest.toml",
  sourceOverrides ? { },
  nodeModules ? null,
  doCheck ? true,
  warningsAsErrors ? true,
  ...
}@args:
let
  locked = readManifest manifest;
  config = builtins.fromTOML (builtins.readFile (src + "/gleam.toml"));
  sourceFor =
    package:
    if sourceOverrides ? ${package.name} then
      sourceOverrides.${package.name}
    else if package.source == "hex" then
      beamPackages.fetchHex {
        pkg = package.name;
        inherit (package) version;
        sha256 =
          package.outer_checksum or (throw "gleam-nix: Hex package ${package.name} needs outer_checksum.");
      }
    else
      throw "gleam-nix: buildJavascriptPackage needs sourceOverrides.${package.name} for its ${package.source} source.";
  # Local packages compile from their locked paths; Gleam accepts them without
  # resolving again when it finds the fingerprint of each one's gleam.toml.
  # A local package outside src, or one an override replaces, is staged there.
  local = builtins.filter (package: package.source == "local") locked.packages;
  downloaded = builtins.filter (package: package.source != "local") locked.packages;
  staged = builtins.filter (
    package: lib.hasPrefix "../" package.path || sourceOverrides ? ${package.name}
  ) local;
  # Only what the build and tests read, as for an Erlang root: the project
  # with its test code and each local package inside it, without READMEs,
  # docs, agent documents or build output.
  source =
    if builtins.isPath src then
      lib.fileset.toSource {
        root = src;
        fileset = lib.fileset.unions (
          [
            (gleamSource {
              directory = src;
              includeDev = true;
            })
          ]
          ++ map (package: gleamSource { directory = src + "/${package.path}"; }) (
            # Overridden packages are staged from their overrides instead.
            builtins.filter (package: !(builtins.elem package staged)) local
          )
        );
      }
    else
      src;
  localSource =
    package:
    if sourceOverrides ? ${package.name} then
      sourceOverrides.${package.name}
    else
      src + "/${package.path}";
  # Gleam's index of downloaded packages, as `gleam deps download` writes it.
  index = lib.concatStrings (
    [ "[packages]\n" ]
    ++ map (package: "${package.name} = \"${package.version}\"\n") (
      lib.sort (a: b: a.name < b.name) locked.packages
    )
    ++ [ "\n[git]\n" ]
    ++ map (package: "\n[git.${package.name}]\ncommit = \"${package.commit}\"\n") (
      builtins.filter (package: package.source == "git") downloaded
    )
  );
  # Development packages and the root's test code stay out of the output: its
  # Gleam test modules, and the native modules Gleam copies from test/.
  testFiles = lib.optionals (builtins.pathExists (src + "/test")) (
    map (file: lib.removePrefix "${toString (src + "/test")}/" (toString file)) (
      lib.filesystem.listFilesRecursive (src + "/test")
    )
  );
  testModules = map (lib.removeSuffix ".gleam") (builtins.filter (lib.hasSuffix ".gleam") testFiles);
  nativeTestFiles = builtins.filter (file: !(lib.hasSuffix ".gleam" file)) testFiles;
  # The packages the frontend needs at run time: its dependencies and theirs,
  # through the locked requirements. Every other locked package, such as a
  # development dependency and what only it needs, stays out of the output.
  requirementsOf = lib.listToAttrs (
    map (package: lib.nameValuePair package.name package.requirements) locked.packages
  );
  runtimeClosure = builtins.genericClosure {
    startSet = map (name: { key = name; }) (lib.attrNames (config.dependencies or { }));
    operator = item: map (name: { key = name; }) (requirementsOf.${item.key} or [ ]);
  };
  runtimeNames = map (item: item.key) runtimeClosure;
  developmentOnly = builtins.filter (name: !(builtins.elem name runtimeNames)) (
    map (package: package.name) locked.packages
  );
  standardArgs = builtins.removeAttrs args [
    "manifest"
    "sourceOverrides"
    "nodeModules"
    "warningsAsErrors"
  ];
in
if (config.target or "erlang") != "javascript" then
  throw "gleam-nix: buildJavascriptPackage needs a project whose gleam.toml sets target = \"javascript\"."
else
  stdenvNoCC.mkDerivation (
    standardArgs
    // {
      pname = config.name;
      version = config.version or "0.1.0";
      inherit doCheck;
      src = source;
      nativeBuildInputs = [
        gleam
        nodejs
        xxHash
      ]
      ++ (args.nativeBuildInputs or [ ]);
      strictDeps = true;
      dontConfigure = true;

      postUnpack =
        (args.postUnpack or "")
        + lib.concatMapStrings (package: ''
          rm -rf "$sourceRoot/${package.path}"
          mkdir -p "$(dirname "$sourceRoot/${package.path}")"
          cp -R ${localSource package} "$sourceRoot/${package.path}"
          chmod -R u+w "$sourceRoot/${package.path}"
        '') staged;

      buildPhase =
        args.buildPhase or ''
          runHook preBuild
          export HOME="$TMPDIR"
          # Gleam builds with the selected manifest, not one src may carry.
          rm -f manifest.toml
          cp ${manifest} manifest.toml
          mkdir -p build/packages
          ${lib.concatMapStrings (package: ''
            cp -R ${sourceFor package} build/packages/${package.name}
            chmod -R u+w build/packages/${package.name}
          '') downloaded}
          # A missing entry makes Gleam resolve versions online.
          printf %s ${lib.escapeShellArg index} > build/packages/packages.toml
          ${lib.concatMapStrings (package: ''
            hash=$(xxhsum -H3 ${lib.escapeShellArg "${package.path}/gleam.toml"} | cut -d' ' -f1 | cut -d_ -f2)
            printf '%u' "0x$hash" > build/packages/${package.name}.config_fingerprint
          '') local}
          ${lib.optionalString (nodeModules != null) ''
            ln -s ${nodeModules}/node_modules node_modules
          ''}
          gleam build --target javascript ${lib.optionalString warningsAsErrors "--warnings-as-errors"}
          runHook postBuild
        '';

      checkPhase =
        args.checkPhase or ''
          runHook preCheck
          gleam test --target javascript
          runHook postCheck
        '';

      installPhase =
        args.installPhase or ''
          runHook preInstall
          # Packages' priv directories are links into the build tree.
          cp -RL build/dev/javascript "$out"
          chmod -R u+w "$out"
          rm -rf "$out/gleam.lock" ${lib.concatMapStringsSep " " (name: ''"$out"/${name}'') developmentOnly}
          # Nothing of the tests ships: their modules, their compiler metadata,
          # and the entry modules `gleam test` generates, named with "@@".
          for module in ${lib.escapeShellArgs testModules}; do
            artefact=''${module//\//@}
            rm -f "$out/${config.name}/$module.mjs" "$out/${config.name}/$module.d.mts" \
              "$out/${config.name}/_gleam_artefacts/$artefact".cache*
          done
          for file in ${lib.escapeShellArgs nativeTestFiles}; do
            rm -f "$out/${config.name}/$file"
          done
          find "$out/${config.name}" -maxdepth 1 -name '*@@*' -delete
          runHook postInstall
        '';

      passthru = (args.passthru or { }) // {
        inherit nodejs;
        gleamCompiler = gleam;
      };
    }
  )
