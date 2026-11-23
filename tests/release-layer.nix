# Checks of the release and image layer (D10). Linux only.
{ pkgs, gleam }:
let
  inherit (pkgs) lib;
  inherit (import ./helpers.nix { inherit pkgs; }) failsWith;
  served = gleam.importProject { src = ./fixtures/served; };
  servedTests = gleam.importProject {
    src = ./fixtures/served;
    includeDev = true;
  };
  testedProject = gleam.importProject {
    src = ./fixtures/tested;
    includeDev = true;
  };
  runtime = gleam.trimErlang { without = [ "wx" ]; };
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

  rejects = value: !(builtins.tryEval (builtins.seq value.drvPath true)).success;
  failures = lib.runTests {
    testReleaseRejectsDevelopmentCompile = {
      expr = rejects (
        gleam.buildRelease {
          project = servedTests;
          inherit runtime;
        }
      );
      expected = true;
    };
    testReleaseRejectsForeignRuntime = {
      expr = rejects (
        gleam.buildRelease {
          project = served;
          runtime = pkgs.hello;
        }
      );
      expected = true;
    };
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

  release-removed-application = failsWith "release-removed-application" (gleam.buildRelease {
    project = gleam.importProject { src = ./fixtures/needs_wx; };
    inherit runtime;
  }) [ "gleam-nix: needs_wx needs wx, which the runtime removed." ];

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
        test "$(jq -r '.config.User' "$config")" = app
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
