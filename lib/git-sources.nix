{
  lib,
  readManifest,
  fetchFromGitHub,
  fetchgit,
}:
{ manifest, registry }:
let
  locked = readManifest manifest;
  entries = builtins.filter (package: package.source == "git") locked.packages;

  # Host, owner and repository from scp-like or URL-style Git remotes.
  parse =
    url:
    let
      scp = builtins.match "[^@/]+@([^:/]+):([^/]+)/([^/]+)" url;
      standard = builtins.match "[a-z+]+://([^@/]+@)?([^:/]+)(:[0-9]+)?/([^/]+)/([^/]+)" url;
      strip = name: lib.removeSuffix "/" (lib.removeSuffix ".git" (lib.removeSuffix "/" name));
    in
    if scp != null then
      {
        host = builtins.elemAt scp 0;
        owner = builtins.elemAt scp 1;
        repo = strip (builtins.elemAt scp 2);
      }
    else if standard != null then
      {
        host = builtins.elemAt standard 1;
        owner = builtins.elemAt standard 3;
        repo = strip (builtins.elemAt standard 4);
      }
    else
      null;

  hashFor = package: registry.${package.repo}.${package.commit} or null;
  missing = builtins.filter (package: hashFor package == null) entries;

  sourceFor =
    package:
    let
      remote = parse package.repo;
      hash = hashFor package;
      fetched =
        if remote != null && remote.host == "github.com" then
          fetchFromGitHub {
            inherit (remote) owner repo;
            rev = package.commit;
            inherit hash;
          }
        else
          fetchgit {
            url = package.repo;
            rev = package.commit;
            inherit hash;
          };
      path = package.path or "";
    in
    if !(builtins.isString (package.repo or null)) || !(builtins.isString (package.commit or null)) then
      throw "gleam-nix: Git package ${package.name} needs repo and commit in manifest.toml."
    else if
      !(builtins.isString path) || lib.hasPrefix "/" path || builtins.elem ".." (lib.splitString "/" path)
    then
      throw "gleam-nix: Git package ${package.name} has a path outside its repository: ${toString path}."
    else if path == "" then
      fetched
    else
      # Interpolation keeps the fetched tree opaque: nothing is read here.
      "${fetched}/${lib.removeSuffix "/" path}";
in
if missing != [ ] then
  throw "gleam-nix: the Git source registry lacks ${
    lib.concatMapStringsSep ", " (
      package: "${package.name} (${package.repo} at ${package.commit})"
    ) missing
  }."
else
  lib.listToAttrs (
    map (package: {
      inherit (package) name;
      value = sourceFor package;
    }) entries
  )
