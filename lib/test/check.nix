{
  lib,
  stdenvNoCC,
  writeText,
  cacert,
  gleamSource,
  warningsGate,
  testSupport,
  testRunners,
}:
let
  # Gleam versions whose generated main module, compiler output and gleeunit
  # contract the pins check has seen. Others fail evaluation.
  supportedGleam = {
    from = "1.19";
    before = "1.20";
  };

  components = path: lib.path.subpath.components (lib.path.splitRoot path).subpath;
  commonPrefix =
    first: second:
    if first == [ ] || second == [ ] || builtins.head first != builtins.head second then
      [ ]
    else
      [ (builtins.head first) ] ++ commonPrefix (builtins.tail first) (builtins.tail second);
  commonAncestor =
    paths:
    lib.path.append (lib.path.splitRoot (builtins.head paths)).root (
      lib.path.subpath.join (
        lib.foldl' commonPrefix (components (builtins.head paths)) (map components paths)
      )
    );

  # What a package's build and tests read, without agent documents: the root
  # with its development code, each local dependency without it.
  checkInputs = directory: includeDev: gleamSource { inherit directory includeDev; };

  # Names the check itself sets; a service cannot claim them.
  checkOwned = [
    "EUNIT"
    "ERL_AFLAGS"
    "SSL_CERT_FILE"
    "NIX_SSL_CERT_FILE"
    "GLEAM_NIX_TEST_MODULES"
  ];
in
{
  project,
  inputs ? null,
  extraInputs ? [ ],
  runner ? testRunners.default,
  services ? [ ],
  vmFlags ? [ ],
  env ? { },
}:
let
  root = project.package;
  app = root.otpAppName;
  packageName = root.gleamPackageName;
  gleamVersion = root.gleamCompiler.version;
  erlang = root.erlangCompiler;
  support = testSupport erlang;

  localPaths = map (package: project.src + "/${package.path}") (
    builtins.filter (package: package.source == "local") project.manifest.packages
  );
  fileset = lib.fileset.unions (
    [
      (
        if inputs == null then
          lib.fileset.unions (
            [ (checkInputs project.src true) ] ++ map (path: checkInputs path false) localPaths
          )
        else
          inputs
      )
    ]
    ++ map gleamSource.withoutAgentDocuments extraInputs
  );
  sourceAncestor = commonAncestor ([ project.src ] ++ localPaths ++ extraInputs);
  source = lib.fileset.toSource {
    root = sourceAncestor;
    inherit fileset;
  };
  relativeRoot = lib.removePrefix "./" (lib.path.removePrefix sourceAncestor project.src);
  sourceRoot =
    "source" + lib.optionalString (relativeRoot != "" && relativeRoot != ".") "/${relativeRoot}";

  appDir = root.beamAppDir;
  # The root compiled with its development code under the warnings gate. Every
  # runner of this project and input set shares this derivation.
  compiled =
    (warningsGate "its test check" (root.override { src = source; })).overrideAttrs
      (previous: {
        pname = "${previous.pname}-test";
        inherit sourceRoot;
        nativeBuildInputs = previous.nativeBuildInputs ++ [ support ];
        postInstall = (previous.postInstall or "") + ''
          # The expected test modules come from the sources, never from a runner.
          gleamNixModules=()
          if [ -d test ]; then
            while IFS= read -r gleamNixFile; do
              case "$gleamNixFile" in
                *.gleam)
                  gleamNixModule="''${gleamNixFile#test/}"
                  gleamNixModule="''${gleamNixModule%.gleam}"
                  gleamNixModules+=("''${gleamNixModule//\//@}")
                  ;;
                *.erl) gleamNixModules+=("$(basename "$gleamNixFile" .erl)") ;;
              esac
            done < <(find test -type f \( -name '*.gleam' -o -name '*.erl' \) | LC_ALL=C sort)
          fi
          mkdir -p "$out/nix-support"
          erl -noshell -pa ${support}/ebin -eval 'gleam_nix_test:discover(init:get_plain_arguments()).' \
            -extra "$out"/${lib.escapeShellArg appDir}/ebin "''${gleamNixModules[@]}" \
            > "$out/nix-support/gleam-nix-test-modules"
        '';
      });
  testModules = "${compiled}/nix-support/gleam-nix-test-modules";

  serviceNames = map (service: service.name) services;
  repeatedServices = lib.attrNames (
    lib.filterAttrs (_: count: count > 1) (
      lib.foldl' (counts: name: counts // { ${name} = (counts.${name} or 0) + 1; }) { } serviceNames
    )
  );
  claims =
    map (name: {
      inherit name;
      owner = "the check";
    }) (lib.attrNames env ++ checkOwned)
    ++ lib.concatMap (
      service:
      map (name: {
        inherit name;
        owner = "service ${service.name}";
      }) (lib.attrNames service.env)
    ) services;
  clashes = lib.filterAttrs (_: owners: builtins.length owners > 1) (
    lib.mapAttrs (_: map (claim: claim.owner)) (lib.groupBy (claim: claim.name) claims)
  );

  script = name: text: writeText "gleam-nix-${name}.sh" text;
  serviceState = service: "$TMPDIR/gleam-nix-services/${service.name}";
  portVariable = service: "gleamNixPort_${service.name}";
  withService =
    service: command:
    ''SERVICE_STATE="${serviceState service}" SERVICE_PORT="''$${portVariable service}" ${command}'';
  badServiceNames = builtins.filter (name: builtins.match "[A-Za-z0-9_]+" name == null) serviceNames;
  printLogs = lib.concatMapStrings (service: ''
    if [ -n "''${gleamNixStarted_${portVariable service}:-}" ]; then
      SERVICE_STATE="${serviceState service}"
      gleamNixLog="${service.log}"
      if [ -f "$gleamNixLog" ]; then
        echo "gleam-nix: log of service ${service.name}:" >&2
        cat "$gleamNixLog" >&2
      fi
    fi
  '') services;
  stopServices = lib.concatMapStrings (service: ''
    if [ -n "''${gleamNixStarted_${portVariable service}:-}" ]; then
      ${withService service "bash -eu ${script "${service.name}-stop" service.stop}"} || true
    fi
  '') (lib.reverseList services);
  startServices = lib.concatMapStrings (service: ''
    mkdir -p "${serviceState service}"
    ${portVariable service}=$(gleamNixFreePort)
    if ! ${withService service "bash -eu ${script "${service.name}-start" service.start}"}; then
      gleamNixStarted_${portVariable service}=1
      echo "gleam-nix: service ${service.name} did not start." >&2
      gleamNixPrintLogs
      gleamNixStopServices
      exit 1
    fi
    gleamNixStarted_${portVariable service}=1
    SERVICE_STATE="${serviceState service}"
    SERVICE_PORT="''$${portVariable service}"
    ${lib.concatStrings (
      lib.mapAttrsToList (name: value: ''
        export ${name}="${value}"
      '') service.env
    )}
    unset SERVICE_STATE SERVICE_PORT
  '') services;

  runScript = script "${packageName}-${runner.name}" (
    runner.run {
      inherit app;
      module = "${packageName}_test";
    }
  );
in
if !(root.includeDev or false) then
  throw "gleam-nix: mkTestCheck needs a project imported with includeDev = true."
else if
  !(
    lib.versionAtLeast gleamVersion supportedGleam.from
    && lib.versionOlder gleamVersion supportedGleam.before
  )
then
  throw "gleam-nix: the test layer supports Gleam ${supportedGleam.from} up to before ${supportedGleam.before}, not ${gleamVersion}."
else if badServiceNames != [ ] then
  throw "gleam-nix: service names may hold only letters, digits and underscores: ${lib.concatStringsSep ", " badServiceNames}."
else if repeatedServices != [ ] then
  throw "gleam-nix: services in one check need distinct names: ${lib.concatStringsSep ", " repeatedServices}."
else if clashes != { } then
  throw "gleam-nix: environment variables set more than once: ${
    lib.concatStringsSep "; " (
      lib.mapAttrsToList (name: owners: "${name} by ${lib.concatStringsSep " and " owners}") clashes
    )
  }."
else
  stdenvNoCC.mkDerivation {
    name = "${packageName}-${runner.name}";
    dontUnpack = true;
    strictDeps = true;
    nativeBuildInputs = [
      erlang
    ]
    ++ lib.concatMap (service: service.nativeBuildInputs or [ ]) services;
    buildInputs = [ compiled ];

    env = env // {
      EUNIT = "[{report, {gleam_nix_eunit_report, []}}]";
      # Every VM the check starts, including ones its tests start, loads the
      # CA bundle and the runner support modules.
      ERL_AFLAGS = "-pa ${support}/ebin -eval gleam_nix_test:load_ca()";
      SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
      NIX_SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
      GLEAM_NIX_TEST_MODULES = testModules;
    };

    buildPhase = ''
      runHook preBuild
      export GLEAM_NIX_TEST_REPORT="$TMPDIR/gleam-nix-report"
      export GLEAM_NIX_SHARD="$TMPDIR/gleam-nix-shard"
      : > "$GLEAM_NIX_TEST_REPORT"

      # Gleam's generated entry module, as `gleam test` builds it.
      mkdir -p "$TMPDIR/gleam-nix-main"
      sed 's/__GLEAM_APP__/${app}/g' ${support.main} > "$TMPDIR/gleam-nix-main/${app}@@main.erl"
      erlc -o "$TMPDIR/gleam-nix-main" "$TMPDIR/gleam-nix-main/${app}@@main.erl"
      cat > "$TMPDIR/gleam-nix-erl" <<EOF
      #!${stdenvNoCC.shell}
      exec erl -noshell -pa "$TMPDIR/gleam-nix-main" ${lib.escapeShellArgs vmFlags} "\$@"
      EOF
      chmod +x "$TMPDIR/gleam-nix-erl"
      export GLEAM_NIX_ERL="$TMPDIR/gleam-nix-erl"

      # Each service's log reaches the build log when the check fails.
      gleamNixPrintLogs() {
        :
        ${printLogs}
      }
      gleamNixStopServices() {
        :
        ${stopServices}
      }
      gleamNixFreePort() {
        local port
        while :; do
          port=$((20000 + RANDOM % 40000))
          if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            echo "$port"
            return
          fi
        done
      }
      ${startServices}

      # gleeunit discovers test/ relative to the working directory.
      cp -R ${source} "$TMPDIR/source"
      chmod -R u+w "$TMPDIR/source"
      cd "$TMPDIR/${sourceRoot}"
      gleamNixStatus=0
      bash -eu ${runScript} || gleamNixStatus=$?
      if [ "$gleamNixStatus" -ne 0 ]; then
        gleamNixPrintLogs
      fi
      gleamNixStopServices
      if [ "$gleamNixStatus" -ne 0 ]; then
        echo "gleam-nix: tests of ${packageName} failed under ${runner.name}." >&2
        exit "$gleamNixStatus"
      fi
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp "$GLEAM_NIX_TEST_REPORT" "$out/report"
      if [ -f "$GLEAM_NIX_SHARD" ]; then cp "$GLEAM_NIX_SHARD" "$out/shard"; fi
      runHook postInstall
    '';

    passthru = {
      inherit
        compiled
        source
        runner
        services
        testModules
        ;
    };

    meta.platforms = lib.platforms.linux;
  }
