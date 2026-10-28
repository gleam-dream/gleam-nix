{
  pkgs,
  gleam,
  exampleShell,
}:
let
  a = gleam.importProject { src = ./fixtures/app_a; };
  b = gleam.importProject { src = ./fixtures/app_b; };
  ownHeaders = gleam.importProject { src = ./fixtures/own_headers; };
  elixir = gleam.beamPackages.elixir;
  elixirSources = gleam.importProject {
    src = ./fixtures/elixir_sources;
    packageArgs = {
      nativeBuildInputs = [ elixir ];
      propagatedBuildInputs = [ elixir ];
    };
  };
  changed = gleam.importProject { src = ./fixtures/app_a_changed; };
  dev = gleam.importProject {
    src = ./fixtures/app_a;
    includeDev = true;
  };
  sourceChanged = gleam.importProject {
    src = ./fixtures/app_a;
    sourceOverrides.shared_lib = ./fixtures/shared_lib_changed;
  };
  paths =
    packages:
    pkgs.lib.concatMapStringsSep ":" (package: "${package}/lib/erlang/lib") (
      gleam.beam.closure packages
    );
  failures = import ./evaluation.nix { inherit pkgs gleam; };
  example = import ../examples/composition.nix { inherit pkgs gleam; };
  closure = pkgs.closureInfo { rootPaths = [ b.package ]; };
  elixirSourcesClosure = pkgs.closureInfo { rootPaths = [ elixirSources.package ]; };
  formatSources = pkgs.lib.fileset.toSource {
    root = ../.;
    fileset = pkgs.lib.fileset.fileFilter (file: file.hasExt "nix") ../.;
  };
in
{
  formatting =
    pkgs.runCommand "gleam-nix-formatting"
      {
        nativeBuildInputs = [ pkgs.nixfmt ];
      }
      ''
        find ${formatSources} -type f -name '*.nix' -exec nixfmt --check {} +
        touch "$out"
      '';
  evaluation =
    assert failures == [ ];
    pkgs.runCommand "gleam-nix-evaluation" { } ''
      touch "$out"
    '';

  runtime =
    pkgs.runCommand "gleam-nix-runtime"
      {
        nativeBuildInputs = [ gleam.erlang ];
      }
      ''
        ERL_LIBS=${
          pkgs.lib.escapeShellArg (paths [
            a.package
            b.package
          ])
        } erl -noshell -eval '
          4 = app_a:answer(),
          5 = app_b:answer(),
          {ok, _} = application:ensure_all_started(app_a),
          {ok, _} = application:ensure_all_started(app_b),
          {ok, <<"retained", 10>>} = file:read_file(filename:join([code:priv_dir(app_a), "build", "value.txt"])),
          {error, nofile} = code:ensure_loaded(development),
          {error, nofile} = code:ensure_loaded(dev_only),
          halt(0).'
        ERL_LIBS=${pkgs.lib.escapeShellArg (paths [ changed.package ])} erl -noshell -eval '
          6 = app_a:answer(), halt(0).'
        ERL_LIBS=${pkgs.lib.escapeShellArg (paths [ dev.package ])} erl -noshell -eval '
          4 = app_a:answer(),
          99 = development:answer(),
          {ok, _} = application:ensure_all_started(app_a),
          halt(0).'
        ERL_LIBS=${pkgs.lib.escapeShellArg (paths [ sourceChanged.package ])} erl -noshell -eval '
          5 = app_a:answer(), halt(0).'
        test -f ${a.package}/src/src/app_a.gleam
        touch "$out"
      '';

  beam-composition = import ./composition.nix { inherit pkgs gleam; };

  own-headers =
    pkgs.runCommand "gleam-nix-own-headers"
      {
        nativeBuildInputs = [ gleam.erlang ];
        buildInputs = [ ownHeaders.package ];
      }
      ''
        erl -noshell -eval '42 = own_headers:answer(), halt(0).'
        touch "$out"
      '';

  elixir-sources =
    pkgs.runCommand "gleam-nix-elixir-sources"
      {
        nativeBuildInputs = [ gleam.erlang ];
        buildInputs = [ elixirSources.package ];
      }
      ''
        ERL_LIBS=${pkgs.lib.escapeShellArg "${elixir}/lib/elixir/lib"}''${ERL_LIBS:+:$ERL_LIBS} erl -noshell -eval '
          {ok, _} = application:ensure_all_started(elixir),
          {ok, _} = application:ensure_all_started(elixir_sources),
          42 = elixir_sources:answer(), halt(0).'
        grep -Fx ${elixir} ${elixirSourcesClosure}/store-paths
        touch "$out"
      '';

  quickstart =
    pkgs.runCommand "gleam-nix-quickstart"
      {
        inherit (exampleShell) nativeBuildInputs buildInputs;
      }
      ''
        erl -noshell -eval '
          {ok, _} = application:ensure_all_started(hello),
          hello:main(), halt(0).' > greeting
        grep -Fx 'Hello from a cached Gleam package' greeting
        touch "$out"
      '';

  beam-hooks =
    pkgs.runCommand "gleam-nix-beam-hooks"
      {
        nativeBuildInputs = [ gleam.erlang ];
        buildInputs = [ b.package ];
      }
      ''
        # ERL_LIBS must come from installed setup hooks and dependency propagation.
        erl -noshell -eval '
          5 = app_b:answer(),
          {ok, _} = application:ensure_all_started(app_b),
          halt(0).'
        grep -Fx ${b.packages.shared_lib} ${closure}/store-paths
        grep -Fx ${b.packages.gleam_stdlib} ${closure}/store-paths
        touch "$out"
      '';

  frontend-composition =
    pkgs.runCommand "gleam-nix-frontend-composition"
      {
        nativeBuildInputs = [ gleam.erlang ];
      }
      ''
        test -s ${example.combined}/share/www/index.html
        test -f ${example.combined}/lib/erlang/lib/hello-0.1.0/ebin/hello.beam
        ERL_LIBS=${pkgs.lib.escapeShellArg (paths [ example.backend ])} erl -noshell -eval '
          {ok, _} = application:ensure_all_started(hello),
          hello:main(), halt(0).'
        touch "$out"
      '';
}
