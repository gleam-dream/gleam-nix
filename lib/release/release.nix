{
  lib,
  stdenvNoCC,
  perl,
  busybox,
  beam,
  warningsGate,
}:
# A release of the project's dependency outputs and a production compile of its
# root, on a runtime derived from the Erlang the tests ran on.
{
  project,
  runtime,
  # Files the root application finds under its priv directory at run time,
  # such as a built frontend: { web = frontend; } is priv/web.
  priv ? { },
}:
let
  # importProject leaves test/ and dev/ out of a production root's source:
  # Gleam's package compiler would compile their Erlang files even without
  # development code. The check below still guards what ships.
  root = warningsGate "its release" project.package;
  app = root.otpAppName;
  packageName = root.gleamPackageName;
  testsErlang = root.erlangCompiler;
  original = runtime.original or runtime;
  removed = runtime.without or [ ];
  libraries = beam.closure [ root ];
  # Modules of the development code, test and dev, which must not ship.
  modulesIn =
    directory:
    lib.optionals (builtins.pathExists directory) (
      map
        (
          file:
          let
            relative = lib.removePrefix "${toString directory}/" (toString file);
          in
          if lib.hasSuffix ".gleam" relative then
            builtins.replaceStrings [ "/" ] [ "@" ] (lib.removeSuffix ".gleam" relative)
          else
            baseNameOf (lib.removeSuffix ".erl" relative)
        )
        (
          builtins.filter (file: lib.hasSuffix ".gleam" file || lib.hasSuffix ".erl" file) (
            map toString (lib.filesystem.listFilesRecursive directory)
          )
        )
    );
  testModules = modulesIn (project.src + "/test") ++ modulesIn (project.src + "/dev");
in
if
  builtins.any (name: name == "" || lib.hasInfix "/" name || name == "." || name == "..") (
    lib.attrNames priv
  )
then
  throw "gleam-nix: buildRelease priv entries name one directory or file inside priv: ${lib.concatStringsSep ", " (lib.attrNames priv)}."
else if root.includeDev then
  throw "gleam-nix: buildRelease needs a project imported without includeDev; development code never ships."
else if original.outPath != testsErlang.outPath then
  throw "gleam-nix: buildRelease needs a runtime derived from the Erlang the project compiled with (${testsErlang.name})."
else
  stdenvNoCC.mkDerivation {
    pname = "${packageName}-release";
    inherit (root) version;
    dontUnpack = true;
    strictDeps = true;
    nativeBuildInputs = [
      perl
      runtime
    ];

    buildPhase = ''
      runHook preBuild
      mkdir -p "$out/lib" "$out/bin" "$out/entry"
      ${lib.concatMapStrings (package: ''
        target="$out/lib/${beam.otpName package}-${package.version}"
        mkdir -p "$target"
        for part in ebin priv; do
          if [ -e ${package}/${beam.appDir package}/$part ]; then
            cp -RL ${package}/${beam.appDir package}/$part "$target/"
          fi
        done
      '') libraries}
      chmod -R u+w "$out/lib"

      ${lib.concatStrings (
        lib.mapAttrsToList (name: source: ''
          rootPriv="$out/lib/${app}-${root.version}/priv"
          mkdir -p "$rootPriv"
          if [ -e "$rootPriv/${name}" ]; then
            echo "gleam-nix: priv/${name} already exists in ${packageName}." >&2
            exit 1
          fi
          cp -RL ${source} "$rootPriv/${name}"
          chmod -R u+w "$rootPriv/${name}"
        '') priv
      )}

      # No test module ships: the root compiled without its development code.
      for module in ${lib.escapeShellArgs testModules}; do
        if [ -e "$out/lib/${app}-${root.version}/ebin/$module.beam" ]; then
          echo "gleam-nix: development module $module would ship." >&2
          exit 1
        fi
      done

      # References to the Erlang the packages compiled with point at the
      # runtime; both store paths have the same length.
      old=${original}
      new=${runtime}
      if grep -rqF "$old" "$out/lib"; then
        if [ "''${#old}" -ne "''${#new}" ]; then
          echo "gleam-nix: cannot rewrite references to $old into a runtime path of another length." >&2
          exit 1
        fi
        grep -rlFZ "$old" "$out/lib" | xargs -0 perl -pi -e "s|\Q$old\E|$new|g"
      fi

      # Every application the service starts is present and not removed.
      cp ${./gleam_nix_release.erl} "$TMPDIR/gleam_nix_release.erl"
      erlc -o "$TMPDIR" "$TMPDIR/gleam_nix_release.erl"
      erl -noshell -pa "$TMPDIR" -eval 'gleam_nix_release:check(init:get_plain_arguments()).' \
        -extra ${app} "$out/lib" "$new/lib/erlang/lib" ${lib.escapeShellArgs removed}

      # Gleam's own entry module, as `gleam run` builds it.
      sed 's/__GLEAM_APP__/${app}/g' ${../gleam-main.erl} > "$TMPDIR/${app}@@main.erl"
      erlc +deterministic -o "$out/entry" "$TMPDIR/${app}@@main.erl"
      cat > "$out/bin/${packageName}" <<EOF
      #!${busybox}/bin/sh
      export ERL_LIBS="$out/lib"
      exec "$new/bin/erl" -noshell -pa "$out/entry" -eval "'${app}@@main':run('${packageName}')" -extra "\$@"
      EOF
      chmod +x "$out/bin/${packageName}"
      runHook postBuild
    '';

    dontInstall = true;
    dontStrip = true;
    dontPatchELF = true;
    dontPatchShebangs = true;

    passthru = {
      inherit
        project
        runtime
        app
        packageName
        ;
      package = root;
    };

    meta.platforms = lib.platforms.linux;
  }
