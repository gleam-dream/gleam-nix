{ lib }:
path:
let
  manifest = builtins.fromTOML (builtins.readFile path);
  packages = manifest.packages or (throw "gleam-nix: manifest.toml must contain a packages list.");
  validRecord =
    package:
    builtins.isAttrs package
    && builtins.isString (package.name or null)
    && builtins.match "[a-z][a-z0-9_]*" package.name != null
    && builtins.isString (package.version or null)
    && builtins.isString (package.source or null)
    && builtins.isList (package.requirements or null)
    && builtins.all builtins.isString package.requirements
    && builtins.isList (package.build_tools or null)
    && builtins.all builtins.isString package.build_tools;
  names = map (package: package.name) packages;
  duplicates = lib.attrNames (
    lib.filterAttrs (_: values: builtins.length values > 1) (
      lib.groupBy (package: package.name) packages
    )
  );
  missing = lib.concatMap (
    package:
    map (name: "${package.name} -> ${name}") (
      builtins.filter (name: !(builtins.elem name names)) package.requirements
    )
  ) packages;
  selfCycles = builtins.filter (package: builtins.elem package.name package.requirements) packages;
  ordered = lib.toposort (first: second: builtins.elem first.name second.requirements) packages;
in
if !(builtins.isList packages) || !(builtins.all validRecord packages) then
  throw "gleam-nix: invalid locked package record in ${toString path}."
else if duplicates != [ ] then
  throw "gleam-nix: duplicate locked packages: ${lib.concatStringsSep ", " duplicates}."
else if missing != [ ] then
  throw "gleam-nix: missing locked requirements: ${lib.concatStringsSep ", " missing}."
else if selfCycles != [ ] then
  throw "gleam-nix: dependency cycle: ${
    lib.concatMapStringsSep ", " (package: package.name) selfCycles
  } depends on itself."
else if ordered ? cycle then
  throw "gleam-nix: dependency cycle: ${
    lib.concatMapStringsSep " -> " (package: package.name) ordered.cycle
  }."
else
  manifest
