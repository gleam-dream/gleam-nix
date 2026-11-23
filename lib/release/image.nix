{
  lib,
  dockerTools,
  busybox,
  cacert,
  writeTextDir,
  runCommand,
  closureInfo,
}:
# An OCI image of a release with a runtime contract: a non-root user, CA
# certificates, a shell and an HTTP client for the health check, and an
# entrypoint. Its closure holds no untrimmed Erlang.
{
  release,
  name,
  port,
  health,
  user,
  assets ? null,
  tag ? null,
  labels ? { },
  env ? { },
}:
let
  uid = "1000";
  home = "/home/${user}";
  certificates = "${cacert}/etc/ssl/certs/ca-bundle.crt";
  accounts = [
    (writeTextDir "etc/passwd" ''
      root:x:0:0::/root:/bin/sh
      ${user}:x:${uid}:${uid}::${home}:/bin/sh
    '')
    (writeTextDir "etc/group" ''
      root:x:0:
      ${user}:x:${uid}:
    '')
  ];
  contents = [
    release
    busybox
    cacert
  ]
  ++ accounts
  ++ lib.optional (assets != null) assets;
  environment = {
    PATH = "/bin";
    HOME = home;
    PORT = toString port;
    SSL_CERT_FILE = certificates;
    NIX_SSL_CERT_FILE = certificates;
  }
  // lib.optionalAttrs (assets != null) { ASSETS_DIR = "${assets}"; }
  // env;
  raw = dockerTools.buildLayeredImage {
    inherit name tag contents;
    fakeRootCommands = ''
      mkdir -p .${home} tmp
      chown ${uid}:${uid} .${home}
      chmod 1777 tmp
    '';
    config = {
      User = user;
      WorkingDir = home;
      Entrypoint = [ "${release}/bin/${release.packageName}" ];
      Env = lib.mapAttrsToList (key: value: "${key}=${value}") environment;
      ExposedPorts."${toString port}/tcp" = { };
      Healthcheck = {
        Test = [
          "CMD"
          "${busybox}/bin/wget"
          "-q"
          "-O"
          "/dev/null"
          "http://127.0.0.1:${toString port}${health}"
        ];
        Interval = 10000000000;
        Timeout = 5000000000;
        Retries = 3;
      };
      Labels = labels;
    };
  };
  closure = closureInfo { rootPaths = contents; };
  untrimmed = release.runtime.original or null;
in
if !(lib.hasPrefix "/" health) then
  throw "gleam-nix: buildImage health must be a path such as /health, not ${health}."
else
  runCommand "${name}-image"
    {
      passthru = (raw.passthru or { }) // {
        inherit raw release;
        inherit (raw) imageName imageTag;
      };
      meta.platforms = lib.platforms.linux;
    }
    ''
      ${lib.optionalString (untrimmed != null) ''
        # Binaries embed store paths, so scan file contents, not only references.
        hash=$(basename ${builtins.unsafeDiscardStringContext untrimmed.outPath} | cut -c1-32)
        while IFS= read -r path; do
          # No pipe: the verdict must not depend on grep's status after a
          # reader closes early. Status 1 only means no match.
          found=$(grep -rlF --no-messages "$hash" "$path") || [ "$?" -eq 1 ]
          if [ -n "$found" ]; then
            echo "gleam-nix: the image of ${name} holds the untrimmed Erlang: ''${found%%$'\n'*}" >&2
            exit 1
          fi
        done < ${closure}/store-paths
      ''}
      ln -s ${raw} "$out"
    ''
