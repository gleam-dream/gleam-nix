# Checks of the JavaScript entry point (D11). Linux only, beside the image.
{ pkgs, gleam }:
let
  inherit (pkgs) lib;
  inherit (import ./helpers.nix { inherit pkgs; }) failsWith;
  frontend = gleam.buildJavascriptPackage { src = ./fixtures/frontend; };
  failing = gleam.buildJavascriptPackage {
    src = ./fixtures/frontend;
    # The fixture's tests fail when the greeting changes.
    postPatch = ''
      substituteInPlace src/frontend.gleam --replace-fail "js_widgets.label()" "js_widgets.label() <> \"!\""
    '';
  };
  runtime = gleam.trimErlang { without = [ "wx" ]; };
  release = gleam.buildRelease {
    project = gleam.importProject { src = ./fixtures/served; };
    inherit runtime;
  };
  image = gleam.buildImage {
    inherit release;
    name = "served-with-assets";
    port = 8080;
    health = "/health";
    user = "app";
    assets = frontend;
  };
  failures = lib.runTests {
    # The backend never depends on the frontend.
    testFrontendLeavesBackendAlone = {
      expr = image.release.drvPath;
      expected = release.drvPath;
    };
  };
in
{
  javascript-evaluation =
    assert failures == [ ];
    pkgs.runCommand "gleam-nix-javascript-evaluation" { } ''
      touch "$out"
    '';

  javascript-package =
    pkgs.runCommand "gleam-nix-javascript-package"
      {
        nativeBuildInputs = [ pkgs.nodejs ];
      }
      ''
        cat > greet.mjs <<'EOF'
        import { greeting } from "${frontend}/frontend/frontend.mjs";
        if (greeting() !== "HELLO FROM THE FRONTEND") process.exit(1);
        EOF
        node greet.mjs
        # Test code and development dependencies stay out of the assets.
        test ! -e ${frontend}/frontend/frontend_test.mjs
        # No trace of the tests ships: no generated test entry, no test
        # module's compiler metadata, nothing that imports a test module.
        test -z "$(find ${frontend} -name '*@@*')"
        ! grep -rl frontend_test ${frontend}
        test ! -e ${frontend}/gleeunit
        # So does gleam_stdlib, which only the development dependency needs.
        test ! -e ${frontend}/gleam_stdlib
        # The local dependency ships, with its priv directory resolved, not a
        # link into the build tree.
        test ! -L ${frontend}/js_widgets/priv
        grep -Fx 'widget asset' ${frontend}/js_widgets/priv/widget.txt
        touch "$out"
      '';

  # The manifest argument is the one Gleam builds with, not src's own.
  javascript-external-manifest = gleam.buildJavascriptPackage {
    src =
      /.
      + builtins.unsafeDiscardStringContext (
        builtins.path {
          path = ./fixtures;
          name = "fixtures-without-frontend-manifest";
          filter = path: _: !(lib.hasSuffix "frontend/manifest.toml" path);
        }
      )
      + "/frontend";
    manifest = ./fixtures/frontend/manifest.toml;
  };

  # Warnings fail the frontend's build, as they fail a test check.
  javascript-warnings = failsWith "javascript-warnings" (gleam.buildJavascriptPackage {
    src = ./fixtures/frontend;
    postPatch = ''
      printf '\nfn unused() -> Int {\n  1\n}\n' >> src/frontend.gleam
    '';
  }) [ "Unused private function" ];

  javascript-failing-tests = failsWith "javascript-failing-tests" failing [
    "frontend_test.greeting_test"
  ];

  # An image with the frontend as assets serves them.
  javascript-image-assets =
    pkgs.runCommand "gleam-nix-javascript-image-assets"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.curl
        ];
        contents = image.release;
        assets = frontend;
      }
      ''
        mkdir image
        tar -xzf ${image} -C image manifest.json
        config=image/$(jq -r '.[0].Config' image/manifest.json)
        tar -xzf ${image} -C image "''${config#image/}"
        mapfile -t entrypoint < <(jq -r '.config.Entrypoint[]' "$config")
        mapfile -t environment < <(jq -r '.config.Env[]' "$config" | sed 's|^PATH=.*|PATH=${pkgs.busybox}/bin|')
        env -i "''${environment[@]}" HOME="$TMPDIR" "''${entrypoint[@]}" &
        pid=$!
        for _ in $(seq 100); do
          if curl -fsS http://127.0.0.1:8080/assets/frontend/frontend.mjs > served.mjs; then break; fi
          sleep 0.2
        done
        kill "$pid"
        cmp served.mjs ${frontend}/frontend/frontend.mjs
        touch "$out"
      '';
}
