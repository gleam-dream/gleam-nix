{
  lib,
  beam,
  beamPackages,
  readManifest,
  buildGleamPackage,
}:
{
  src,
  manifest ? src + "/manifest.toml",
  sourceOverrides ? { },
  packageOverrides ? final: prev: { },
  includeDev ? false,
  packageArgs ? { },
}:
let
  locked = readManifest manifest;
  config = builtins.fromTOML (builtins.readFile (src + "/gleam.toml"));
  records = lib.listToAttrs (
    map (package: {
      name = package.name;
      value = package;
    }) locked.packages
  );

  unknownSources = builtins.filter (name: !(records ? ${name})) (lib.attrNames sourceOverrides);

  sourceFor =
    name: package:
    if sourceOverrides ? ${name} then
      sourceOverrides.${name}
    else if package.source == "hex" then
      beamPackages.fetchHex {
        pkg = name;
        inherit (package) version;
        sha256 = package.outer_checksum or (throw "gleam-nix: Hex package ${name} needs outer_checksum.");
      }
    else if package.source == "local" then
      src + "/${package.path}"
    else
      throw "gleam-nix: source '${package.source}' for ${name} needs sourceOverrides.${name}.";

  sources = lib.mapAttrs sourceFor records;
  packages = lib.fix (
    final:
    let
      defaults = lib.mapAttrs (
        name: package:
        if !(builtins.elem "gleam" package.build_tools) then
          throw "gleam-nix: ${name} uses ${lib.concatStringsSep ", " package.build_tools}; provide packageOverrides with fromBeamPackage."
        else
          buildGleamPackage {
            pname = name;
            inherit (package) version;
            src = sources.${name};
            otpAppName = package.otp_app or name;
            beamDeps = map (dependency: final.${dependency}) package.requirements;
          }
      ) records;
      overrides = packageOverrides final defaults;
      unknownOverrides = builtins.filter (name: !(records ? ${name})) (lib.attrNames overrides);
      checked =
        name: package:
        let
          record = records.${name};
          expected = lib.unique (map (dependency: final.${dependency}) record.requirements);
          actual = package.beamDeps or [ ];
          identities = dependencies: map beam.identity (beam.sortPackages dependencies);
        in
        if
          beam.packageName package != name
          || package.version != record.version
          || beam.otpName package != (record.otp_app or name)
        then
          throw "gleam-nix: package override for ${name} must preserve the locked package name, version, and OTP application."
        else if identities actual != identities expected then
          throw "gleam-nix: package override for ${name} must preserve the locked dependency graph."
        else
          package // { beamDeps = beam.sortPackages expected; };
    in
    if unknownOverrides != [ ] then
      throw "gleam-nix: overrides for undeclared packages: ${lib.concatStringsSep ", " unknownOverrides}."
    else
      lib.mapAttrs checked (defaults // overrides)
  );

  development = config."dev-dependencies" or config.dev_dependencies or { };
  rootNames = lib.unique (
    lib.attrNames (config.dependencies or { }) ++ lib.optionals includeDev (lib.attrNames development)
  );
  missingRoot = builtins.filter (name: !(records ? ${name})) rootNames;
  reservedArgs = builtins.filter (name: builtins.hasAttr name packageArgs) [
    "pname"
    "version"
    "src"
    "beamDeps"
    "otpAppName"
    "includeDev"
    "target"
  ];
  root = buildGleamPackage (
    {
      pname = config.name;
      version = config.version or "0.1.0";
      inherit src includeDev;
      beamDeps = map (name: packages.${name}) rootNames;
    }
    // packageArgs
  );
in
if (config.target or "erlang") != "erlang" then
  throw "gleam-nix: importProject currently supports only the Erlang target."
else if unknownSources != [ ] then
  throw "gleam-nix: source overrides for undeclared packages: ${lib.concatStringsSep ", " unknownSources}."
else if missingRoot != [ ] then
  throw "gleam-nix: root dependencies missing from manifest: ${lib.concatStringsSep ", " missingRoot}."
else if reservedArgs != [ ] then
  throw "gleam-nix: packageArgs cannot replace project inputs: ${lib.concatStringsSep ", " reservedArgs}."
else
  builtins.seq locked {
    manifest = locked;
    inherit packages sources;
    package = root;
  }
