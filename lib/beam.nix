{
  lib,
  gleam,
  erlang,
}:
let
  packageName =
    package:
    package.gleamPackageName or package.pname
      or (throw "gleam-nix: a BEAM dependency needs a package name; use fromBeamPackage.");
  otpName = package: package.otpAppName or (packageName package);
  appDir = package: package.beamAppDir or "lib/erlang/lib/${otpName package}-${package.version}";
  sortPackages = lib.sort (first: second: packageName first < packageName second);
  identity = package: {
    output = toString package;
    name = packageName package;
    otpAppName = otpName package;
    directory = appDir package;
    inherit (package) version;
    gleamCompiler = if package ? gleamCompiler then toString package.gleamCompiler else null;
    erlangCompiler = if package ? erlangCompiler then toString package.erlangCompiler else null;
    dependencies = lib.sort builtins.lessThan (map toString (package.beamDeps or [ ]));
  };
  node = package: {
    key = builtins.toJSON (identity package);
    inherit package;
  };

  checkedName =
    kind: name:
    if builtins.isString name && builtins.match "[a-z][a-z0-9_]*" name != null then
      name
    else
      throw "gleam-nix: invalid ${kind} name ${builtins.toJSON name}.";

  closure =
    dependencies:
    let
      nodes = builtins.genericClosure {
        startSet = map node dependencies;
        operator = entry: map node (entry.package.beamDeps or [ ]);
      };
      packages = map (node: node.package) nodes;
      conflicts =
        getter:
        lib.attrNames (
          lib.filterAttrs (_: values: builtins.length values > 1) (lib.groupBy getter packages)
        );
      nameConflicts = conflicts packageName;
      otpConflicts = conflicts otpName;
      # Group keys are diagnostic identifiers, never derivation inputs.
      metadataConflicts = conflicts (package: builtins.unsafeDiscardStringContext (toString package));
      incompatible = builtins.filter (
        package:
        (package ? gleamCompiler && toString package.gleamCompiler != toString gleam)
        || (package ? erlangCompiler && toString package.erlangCompiler != toString erlang)
      ) packages;
    in
    if metadataConflicts != [ ] then
      throw "gleam-nix: inconsistent BEAM metadata for outputs: ${lib.concatStringsSep ", " metadataConflicts}."
    else if nameConflicts != [ ] then
      throw "gleam-nix: conflicting package outputs: ${lib.concatStringsSep ", " nameConflicts}."
    else if otpConflicts != [ ] then
      throw "gleam-nix: conflicting OTP application outputs: ${lib.concatStringsSep ", " otpConflicts}."
    else if incompatible != [ ] then
      throw "gleam-nix: incompatible compiler/toolchain for ${
        lib.concatMapStringsSep ", " packageName incompatible
      }."
    else
      builtins.deepSeq (map (package: [
        (checkedName "package" (packageName package))
        (checkedName "OTP application" (otpName package))
      ]) packages) (sortPackages packages);

  fromBeamPackage =
    {
      package,
      pname,
      version,
      otpAppName ? pname,
      beamDeps ? package.beamDeps or [ ],
      appDir ? "lib/erlang/lib/${otpAppName}-${version}",
    }:
    package
    // {
      gleamPackageName = checkedName "package" pname;
      inherit version beamDeps otpAppName;
      beamAppDir = appDir;
    };
in
{
  inherit
    packageName
    otpName
    appDir
    checkedName
    sortPackages
    identity
    closure
    fromBeamPackage
    ;
}
