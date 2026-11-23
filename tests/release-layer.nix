# Checks of the release and image layer (D10). Linux only.
{ pkgs, gleam }:
let
  inherit (pkgs) lib;
  inherit (import ./helpers.nix { inherit pkgs; }) failsWith;
  served = gleam.importProject { src = ./fixtures/served; };
  testedProject = gleam.importProject {
    src = ./fixtures/tested;
    includeDev = true;
  };
  runtime = gleam.trimErlang { without = [ "wx" ]; };
  testedRelease = gleam.buildRelease {
    project = gleam.importProject { src = ./fixtures/tested; };
    inherit runtime;
  };
  release = gleam.buildRelease {
    project = served;
    inherit runtime;
  };
  image = gleam.buildImage {
    inherit release;
    name = "served";
    port = 8080;
    health = "/health";
    user = "app";
  };

  failures = lib.runTests {
    # What ships is what was tested: the release and the test check share
    # every dependency derivation and the compiler.
    testReleaseSharesTestedDependencies = {
      expr =
        let
          shipped = gleam.buildRelease {
            project = gleam.importProject { src = ./fixtures/tested; };
            inherit runtime;
          };
          tested = (gleam.mkTestCheck { project = testedProject; }).compiled;
          dependencies = package: map (dependency: dependency.drvPath) (gleam.beam.closure package.beamDeps);
        in
        {
          compiler = shipped.package.gleamCompiler.drvPath == tested.gleamCompiler.drvPath;
          shippedAreTested = builtins.all (path: builtins.elem path (dependencies tested)) (
            dependencies shipped.package
          );
          count = builtins.length (dependencies shipped.package);
        };
      expected = {
        compiler = true;
        shippedAreTested = true;
        count = 2;
      };
    };
  };
in
{
  release-evaluation =
    assert failures == [ ];
    pkgs.runCommand "gleam-nix-release-evaluation" { } ''
      touch "$out"
    '';

  release-trim-erlang = pkgs.runCommand "gleam-nix-release-trim-erlang" { } ''
    original=${gleam.erlang}
    test "''${#original}" -eq "${toString (builtins.stringLength "${runtime}")}"
    ! ls -d ${runtime}/lib/erlang/lib/wx-* 2>/dev/null
    ls -d ${runtime}/lib/erlang/lib/inets-*
    ! grep -rqF "$original" ${runtime}
    ${runtime}/bin/erl -noshell -eval '{error, _} = application:load(wx), ok = application:load(inets), halt(0).'
    touch "$out"
  '';

  # The closure scan catches the original Erlang wherever it enters the image.
  release-image-untrimmed = failsWith "release-image-untrimmed" (gleam.buildImage {
    inherit release;
    name = "untrimmed";
    port = 8080;
    health = "/health";
    user = "app";
    assets = gleam.erlang;
  }) [ "gleam-nix: the image of untrimmed holds the untrimmed Erlang:" ];

  # Many matching files in one store path, more names than a 64 KiB pipe holds:
  # the scan must still fail. The files name the Erlang as text, so it is not
  # a reference and only this path matches.
  release-image-many-matches = failsWith "release-image-many-matches" (gleam.buildImage {
    inherit release;
    name = "many-matches";
    port = 8080;
    health = "/health";
    user = "app";
    assets = pkgs.runCommand "names-untrimmed-erlang" { } ''
      mkdir -p "$out"
      for index in $(seq 2000); do
        echo ${lib.escapeShellArg (builtins.unsafeDiscardStringContext gleam.erlang.outPath)} \
          > "$out/a-long-file-name-so-that-the-list-of-matches-exceeds-one-buffer-$index"
      done
    '';
  }) [ "gleam-nix: the image of many-matches holds the untrimmed Erlang:" ];

  release-removed-application = failsWith "release-removed-application" (gleam.buildRelease {
    project = gleam.importProject { src = ./fixtures/needs_wx; };
    inherit runtime;
  }) [ "gleam-nix: needs_wx needs wx, which the runtime removed." ];

  # Gleam's package compiler still compiles Erlang files under test/ without
  # development code; the release compiles a source without test/.
  release-without-test-code = pkgs.runCommand "gleam-nix-release-without-test-code" { } ''
    test -e ${testedRelease}/lib/tested-0.1.0/ebin/tested.beam
    test ! -e ${testedRelease}/lib/tested-0.1.0/ebin/beta_test.beam
    test ! -e ${testedRelease}/lib/tested-0.1.0/ebin/tested@alpha_test.beam
    touch "$out"
  '';

  # The runtime contract an adopter can set: a chosen non-root uid and gid, a
  # working directory, extra packages, and files in the root's priv.
  release-image-contract =
    let
      web = pkgs.runCommand "web" { } ''
        mkdir -p "$out"
        echo shell > "$out/index.html"
      '';
      contracted = gleam.buildImage {
        release = gleam.buildRelease {
          project = served;
          inherit runtime;
          priv.web = web;
        };
        name = "contracted";
        port = 8080;
        health = "/health";
        user = "service";
        uid = 10001;
        gid = 10001;
        workingDir = "/app";
        contents = [ pkgs.hello ];
      };
    in
    pkgs.runCommand "gleam-nix-release-image-contract"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        grep -Fx shell ${contracted.release}/lib/served-0.1.0/priv/web/index.html
        mkdir image
        tar -xzf ${contracted} -C image manifest.json
        config=image/$(jq -r '.[0].Config' image/manifest.json)
        tar -xzf ${contracted} -C image "''${config#image/}"
        test "$(jq -r '.config.User' "$config")" = 10001:10001
        test "$(jq -r '.config.WorkingDir' "$config")" = /app
        # Extra packages are in the image's layers.
        for layer in $(jq -r '.[0].Layers[]' image/manifest.json); do
          tar -xzf ${contracted} -O "$layer" | tar -t
        done > files
        grep -q -- '-hello-' files
        touch "$out"
      '';

  release-boots =
    pkgs.runCommand "gleam-nix-release-boots"
      {
        nativeBuildInputs = [ pkgs.curl ];
      }
      ''
        export PORT=18080 HOME="$TMPDIR"
        ${release}/bin/served &
        pid=$!
        for _ in $(seq 100); do
          if curl -fsS "http://127.0.0.1:$PORT/health" > body; then break; fi
          sleep 0.2
        done
        kill "$pid"
        test "$(cat body)" = ok
        ! ls ${release}/lib | grep -q gleeunit
        test ! -e ${release}/lib/served-0.1.0/ebin/served_test.beam
        touch "$out"
      '';

  # Starts the image's own entrypoint with its environment and waits for its
  # own health check, read from the image configuration.
  release-image-health =
    pkgs.runCommand "gleam-nix-release-image-health"
      {
        nativeBuildInputs = [ pkgs.jq ];
        # The image's contents, which its configuration names by path.
        contents = image.release;
      }
      ''
        mkdir image
        tar -xzf ${image} -C image manifest.json
        config=$(jq -r '.[0].Config' image/manifest.json)
        tar -xzf ${image} -C image "$config"
        config=image/$config
        test "$(jq -r '.config.User' "$config")" = 1000:1000
        mapfile -t entrypoint < <(jq -r '.config.Entrypoint[]' "$config")
        mapfile -t environment < <(jq -r '.config.Env[]' "$config" | sed 's|^PATH=.*|PATH=${pkgs.busybox}/bin|')
        mapfile -t health < <(jq -r '.config.Healthcheck.Test[1:][]' "$config")
        env -i "''${environment[@]}" HOME="$TMPDIR" "''${entrypoint[@]}" &
        pid=$!
        healthy=0
        for _ in $(seq 100); do
          if "''${health[@]}"; then healthy=1; break; fi
          sleep 0.2
        done
        kill "$pid"
        test "$healthy" -eq 1
        touch "$out"
      '';
}
