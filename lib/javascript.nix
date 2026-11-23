{
  lib,
  stdenvNoCC,
  gleam,
  nodejs,
  beamPackages,
  readManifest,
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
  downloaded = locked.packages;
  # Gleam resolves versions again, online, whenever a JavaScript project has a
  # local path dependency, even with every package downloaded, so the
  # sandboxed build cannot run.
  local = builtins.filter (package: package.source == "local") locked.packages;
  # Development packages and the root's test modules stay out of the output.
  testModules = lib.optionals (builtins.pathExists (src + "/test")) (
    map
      (file: lib.removeSuffix ".gleam" (lib.removePrefix "${toString (src + "/test")}/" (toString file)))
      (
        builtins.filter (file: lib.hasSuffix ".gleam" (toString file)) (
          lib.filesystem.listFilesRecursive (src + "/test")
        )
      )
  );
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
  ];
in
if (config.target or "erlang") != "javascript" then
  throw "gleam-nix: buildJavascriptPackage needs a project whose gleam.toml sets target = \"javascript\"."
else if local != [ ] then
  throw "gleam-nix: buildJavascriptPackage cannot build local path dependencies, because Gleam then resolves versions online: ${
    lib.concatMapStringsSep ", " (package: package.name) local
  }."
else
  stdenvNoCC.mkDerivation (
    standardArgs
    // {
      pname = config.name;
      version = config.version or "0.1.0";
      inherit src doCheck;
      nativeBuildInputs = [
        gleam
        nodejs
      ]
      ++ (args.nativeBuildInputs or [ ]);
      strictDeps = true;
      dontConfigure = true;

      buildPhase =
        args.buildPhase or ''
          runHook preBuild
          export HOME="$TMPDIR"
          mkdir -p build/packages
          ${lib.concatMapStrings (package: ''
            cp -R ${sourceFor package} build/packages/${package.name}
            chmod -R u+w build/packages/${package.name}
          '') downloaded}
          {
            echo "[packages]"
            # Gleam's record of downloaded packages; a missing one makes it resolve.
            ${lib.concatMapStrings (package: ''
              echo '${package.name} = "${package.version}"'
            '') locked.packages}
          } > build/packages/packages.toml
          ${lib.optionalString (nodeModules != null) ''
            ln -s ${nodeModules}/node_modules node_modules
          ''}
          gleam build --target javascript
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
          cp -R build/dev/javascript "$out"
          chmod -R u+w "$out"
          rm -rf "$out/gleam.lock" ${lib.concatMapStringsSep " " (name: ''"$out"/${name}'') developmentOnly}
          for module in ${lib.escapeShellArgs testModules}; do
            rm -f "$out/${config.name}/$module.mjs" "$out/${config.name}/$module.d.mts"
          done
          runHook postInstall
        '';

      passthru = (args.passthru or { }) // {
        inherit nodejs;
        gleamCompiler = gleam;
      };
    }
  )
