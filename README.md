# Gleam Nix

[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

Gleam Nix builds each Gleam package as a separate Nix derivation, using the resolved
dependency graph in `manifest.toml`. Projects with matching dependency inputs
reuse compiled packages. Application edits leave those dependencies cached.

It supports the Erlang target with Gleam 1.19 or newer, selected through your
Nixpkgs input. Gleam retains responsibility for resolving dependency versions.

## When to use it

Use Gleam Nix to package Erlang applications with Nix, share compiled dependencies
between projects, or compose Gleam with existing Erlang, Elixir and frontend builds.
Nix owns local store reuse and sharing through configured binary caches.

## Scope

On one package graph the library builds packages, [test checks](#test-a-project),
a [release and image](#ship-an-image), and a [Gleam frontend](#build-a-gleam-frontend).
Each is a function returning derivations, so it composes with the rest of your
flake. Checks, releases and images run on Linux. The release, image and
frontend are unstable. See the [design](docs/design.md) for every interface.

The library doesn't orchestrate CI, resolve versions, deploy, support languages other than
Gleam or targets other than Erlang and JavaScript, or run checks and images on
Darwin.

## A service in one flake

A service with a PostgreSQL test suite in four shards, a coverage check and an
image. It is [the service example](examples/service/flake.nix),
which the library's checks build:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.gleam-nix = {
    url = "github:gleam-dream/gleam-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      gleam-nix,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      gleam = gleam-nix.lib.mkLib pkgs;
      tested = gleam.importProject {
        src = ./.;
        includeDev = true;
      };
      database = gleam.testServices.postgresql {
        package = pkgs.postgresql_17;
        aliases.DATABASE_URL = "postgresql://postgres@127.0.0.1:$SERVICE_PORT/postgres";
      };
      shards =
        map
          (
            runner:
            gleam.mkTestCheck {
              project = tested;
              inherit runner;
              services = [ database ];
            }
          )
          (
            gleam.testRunners.shards {
              count = 4;
              setup = "my_app_test.setup";
            }
          );
      release = gleam.buildRelease {
        project = gleam.importProject { src = ./.; };
        runtime = gleam.trimErlang {
          without = [
            "wx"
            "observer"
            "debugger"
            "et"
          ];
        };
      };
    in
    {
      # Each shard is its own derivation; coverage checks that every test
      # module ran in exactly one of them.
      checks.${system} =
        builtins.listToAttrs (
          pkgs.lib.imap1 (index: check: {
            name = "shard-${toString index}";
            value = check;
          }) shards
        )
        // {
          coverage = gleam.mkCoverageCheck { checks = shards; };
        };
      packages.${system}.image = gleam.buildImage {
        inherit release;
        name = "my-service";
        port = 8080;
        health = "/health";
        user = "app";
      };
    };
}
```

`nix flake check` builds the shards and coverage; `nix build .#image` builds
the image.

## Capabilities

- Build locked Hex and local Gleam packages independently.
- Fetch locked Git sources from the manifest with a registry of content hashes,
  and build Rebar3 and Mix packages with Nixpkgs on request.
- Compose Rebar3 and Mix outputs through the same BEAM dependency graph.
- Keep application source and unrelated manifest entries outside dependency inputs.

## Install

Add the library to your existing `flake.nix`, sharing its Nixpkgs input:

```nix
inputs.gleam-nix = {
  url = "github:gleam-dream/gleam-nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Keep `manifest.toml` current with `gleam deps download`. In a Git-backed project,
track the flake, Gleam configuration, manifest and source files. Commit
`flake.lock` to retain the selected Nix inputs.

## Build a project

Create the library scope with your selected `pkgs`, then expose the result as a
flake package:

```nix
let
  gleam = gleam-nix.lib.mkLib pkgs;
  project = gleam.importProject { src = ./.; };
in
project.package
```

`project.packages.<name>` exposes an individual compiled dependency;
`project.sources.<name>` exposes its source for build overrides.

The [complete hello flake](examples/hello/flake.nix) exports packages for the
supported platforms and a development shell with the compiled package on
`ERL_LIBS`. With that setup, build and run your entry module:

```sh
nix build
nix develop --command erl -noshell -eval 'my_app:main(), halt(0).'
```

Replace `my_app` with your module name (`hello` in the example). The output is a
compiled OTP library with Gleam compiler metadata. Applications assemble their
own executable launchers or OTP/Mix releases.

## Git dependencies

The manifest locks each Git dependency's repository, commit and, for a package
in a subdirectory, its path. Keep a registry of content hashes beside it, keyed
by repository URL and commit, and hand both to `gitSources`:

```nix
gleam.importProject {
  src = ./.;
  sourceOverrides = gleam.gitSources {
    manifest = ./manifest.toml;
    registry = import ./git-hashes.nix;
  };
}
```

```nix
# git-hashes.nix
{
  "https://github.com/owner/library.git" = {
    "<locked commit>" = "sha256-...";
  };
}
```

GitHub repositories use `fetchFromGitHub`; other hosts use `fetchgit`.
Evaluation fetches nothing and needs no Git credentials. A Git entry missing
from the registry fails evaluation with its name, repository and commit. Get a
GitHub hash with `nix flake prefetch github:owner/library/<commit>`.

## Test a project

A test check compiles the root with its test code against the same cached
dependency outputs as the release, fails on any Gleam or Erlang warning in the
root, and runs the tests in the Nix sandbox. A failing check leaves nothing in
the store; its log is the build log.

```nix
let
  project = gleam.importProject {
    src = ./.;
    includeDev = true;
  };
  database = gleam.testServices.postgresql {
    package = pkgs.postgresql_17;
    init = "create role app login; create database app_test owner app;";
    aliases.DATABASE_URL = "postgresql://app@127.0.0.1:$SERVICE_PORT/app_test";
  };
  shards = map (
    runner:
    gleam.mkTestCheck {
      inherit project runner;
      services = [ database ];
    }
  ) (gleam.testRunners.shards { count = 4; setup = "my_app_test.setup"; });
in
{
  tests = gleam.mkTestCheck { inherit project; services = [ database ]; };
  coverage = gleam.mkCoverageCheck { checks = shards; };
}
```

- **Runners.** The default runner calls your `my_app_test.main()`, exactly as
  `gleam test` does, from a copy of your source. The shard runner splits the
  test modules by a hash of their names, so adding a module moves no other;
  setup from your test `main` moves into its `setup` function, and `pins`
  places a module in a chosen shard. All shards share one compile. Sharding
  splits by module: a suite whose time sits in one slow module gains nothing,
  since that module still runs whole in one shard. Read each module's time in
  a check's `report` before choosing a shard count.
- **Inputs.** A check's source is what its build and tests read: `gleam.toml`,
  `manifest.toml`, `src`, `priv`, `include`, `test` and `dev`, and the same
  without `test` and `dev` for its local dependencies. `AGENTS.md` and
  `CLAUDE.md` are left out wherever they sit, so a README, docs or agent
  document edit reruns nothing, and the release ignores them too. Add other
  files your tests read with `extraInputs`.
- **Services** start with a fresh port and state directory per check, so each
  shard has its own database. Two services, or a service and the check, that
  set the same variable fail evaluation. A failing check prints each service's
  log.
- **Results.** Each check writes `report`, one line per test module with its
  verdict, test count and milliseconds. The coverage check fails naming any
  module that ran in no check or in several. Coverage reads the expected
  modules from the shared compile's separate `modules` output, so a CI that
  pushes the compile to a binary cache must push its `modules` output too, or
  coverage rebuilds the compile.
- **Sandbox.** Every VM a check starts loads a CA bundle.

The test layer supports Gleam 1.19 and gleeunit; another compiler version fails
evaluation until the library's checks have pinned its output.

## Ship an image

What ships is what was tested. The release uses the test checks' dependency
outputs and compiler, compiles the root again without its test code under the
same warnings gate, and runs on a copy of the tests' Erlang with unused OTP
applications removed. Nothing is rebuilt. This layer is unstable: it may change
without a major version until a second user adopts it.

```nix
let
  runtime = gleam.trimErlang { without = [ "wx" "observer" "debugger" "et" ]; };
  release = gleam.buildRelease {
    project = gleam.importProject { src = ./.; };
    inherit runtime;
  };
in
gleam.buildImage {
  inherit release;
  name = "my-service";
  port = 8080;
  health = "/health";
  user = "app";
}
```

- `buildRelease` fails if any application the service starts needs one the
  runtime removed, naming both, and if a test module would ship.
  `bin/my_app` starts the root's `main` as `gleam run` does.
- `buildImage` adds a non-root user, CA certificates, BusyBox for a shell and
  the health check's HTTP client, and an entrypoint. It fails if any file in
  its closure, binaries included, still names the untrimmed Erlang.
- The user runs as UID and GID 1000 from its home; set `uid`, `gid` and
  `workingDir` for another contract (root is refused), and add packages, such
  as tools for an operator's shell, with `contents`.
- The image reads `PORT`. Pass a frontend's output as `assets` and read its
  path from `ASSETS_DIR`, or place it in the root application's `priv` with
  `buildRelease { priv.web = frontend; }` and read it through
  `code:priv_dir/1`.

## Build a Gleam frontend

`buildJavascriptPackage` builds a project whose `gleam.toml` sets
`target = "javascript"` and runs its tests with Node. Its output, the compiled
JavaScript tree without test code, can be an image's `assets`:

```nix
let
  frontend = gleam.buildJavascriptPackage {
    src = ./frontend;
    # Optional: npm dependencies from their own derivation.
    nodeModules = pkgs.importNpmLock.buildNodeModules {
      npmRoot = ./frontend;
      inherit (pkgs) nodejs;
    };
  };
in
gleam.buildImage {
  inherit release;
  name = "my-service";
  port = 8080;
  health = "/health";
  user = "app";
  assets = frontend;
}
```

The frontend is its own derivation: editing it rebuilds the frontend and the
image, and not the backend as long as the frontend's files sit outside the
backend's own inputs, such as its `src` or `priv`. Like a test check, it reads
only `gleam.toml`, `manifest.toml`, `src`, `priv`, `include`, `test`, `dev` and
its local packages, so a README or agent document edit rebuilds nothing. Its
locked Hex packages are fetched as separate derivations and compiled in one
offline `gleam build`. This entry point is
unstable.

## Use it in CI

Every check is an ordinary derivation whose inputs are only what it needs, so
any Nix CI setup gets the reuse: with a binary cache, an unchanged check is
fetched instead of rebuilt. The library ships no CI tooling; compose the tools
that exist:

- Build only what the cache lacks with
  [nix-fast-build](https://github.com/Mic92/nix-fast-build) `--skip-cached`, or
  read per-check cache status from
  [nix-eval-jobs](https://github.com/nix-community/nix-eval-jobs)
  `--check-cache-status`.
- Share results through [Cachix](https://www.cachix.org/),
  [Attic](https://github.com/zhaofengli/attic) or, on GitHub Actions,
  [Magic Nix Cache](https://github.com/DeterminateSystems/magic-nix-cache-action).
- Run shards as parallel jobs with
  [nix-github-actions](https://github.com/nix-community/nix-github-actions), or
  a matrix over `.#checks.x86_64-linux` names.
- For one verdict that nothing was skipped, substitute every check with local
  builds forbidden: `nix build --max-jobs 0 .#checks.x86_64-linux.<name>`.

A store path names the recipe, not the result, so write access to a binary
cache is merge rights on every repository that reads from it.

## How caching works

Each Gleam package compiles against its resolved dependencies with
`gleam compile-package`. Its derivation depends on its own source, dependency
outputs, toolchain, platform and build settings. It excludes the consuming
application's source and full manifest.

| Change                                    | Build effect                      |
| ----------------------------------------- | --------------------------------- |
| Application source                        | The application                   |
| Dependency source                         | That dependency and its consumers |
| Same dependency inputs in another project | Reuse the existing output         |

Nix reuses outputs already in its store. Sharing across machines uses a configured
binary cache. Matching package versions alone is insufficient; the other build
inputs must match too. Dependency ordering does not affect cache identity.

## Compose with other builders

Set `buildForeign = true` to build locked Rebar3 and Mix packages with Nixpkgs'
`buildRebar3` and `buildMix`. Pass per-package builder arguments, such as rebar3
plugins the sandbox cannot download, through `foreignArgs.<name>`.

For full control, use `packageOverrides` with the same builders, then adapt the
compiled package with `fromBeamPackage`. Keep one BEAM package set throughout the
project. Overrides must preserve the locked package identity and dependency edges.

Build frontend assets separately with npm, pnpm or Yarn, then assemble them beside
the backend. Keep their source outside the backend's `src` to avoid rebuilding the
backend on asset edits. Compiled Gleam dependencies remain independent either way.

| Example                                                                                           | Demonstrates                                                                 |
| ------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| [Erlang and Elixir](examples/beam-composition.nix)                                                | Complete Rebar3 and Mix overrides, including distinct OTP application names. |
| [Native build plugins](examples/foreign-builds.nix)                                               | `buildForeign` with the `pc` port compiler for esqlite's SQLite NIF.         |
| [Frontend assets](examples/composition.nix)                                                       | `buildNpmPackage`, `importNpmLock` and final asset assembly.                 |
| [Oversight applications](https://github.com/gleam-dream/oversight/blob/main/nix/applications.nix) | Locked Git adapters and shared native dependencies across real applications. |

## Operational limits

- The root configuration and manifest must be readable during evaluation. Git
  dependencies need a registry entry for `gitSources`, or an explicit
  `sourceOverrides` entry. Private repositories need a fetcher of the adopter's.
- Locked Rebar3 and Mix packages can use `buildForeign = true`, with builder
  options in `foreignArgs.<name>`. Other foreign build tools need `packageOverrides`.
- Non-Gleam packages drop all requirements absent from the manifest, for any
  source type, including optional Hex dependencies. Missing required foreign
  edges can pass validation. Missing Gleam requirements remain errors.
- Gleam packages containing Elixir sources need the selected Elixir compiler in
  `nativeBuildInputs` (`packageArgs.nativeBuildInputs` for the root). Retain and
  load Elixir's runtime separately; see the [compilation contract](docs/design.md#d3-package-compilation).
- Compiled Gleam dependencies must use the same Gleam and Erlang derivations.
  Select alternative toolchains through the scope's `overrideScope`.
- `includeDev = true` compiles root development/test modules and includes their
  dependencies; `mkTestCheck` runs them.
- Flake outputs cover x86-64 Linux, ARM64 Linux and ARM64 macOS. Test checks,
  releases and images are Linux only. Cross compilation stays outside this
  library. A frontend's packages come from Hex, local paths or
  `sourceOverrides`.

## Examples and reference

The [design reference](docs/design.md) documents API arguments, overrides, output
layout and source filtering. The [checks](tests/default.nix) exercise package
reuse, selective invalidation, runtime closures, generated headers and composition.
Run them with:

```sh
nix flake check --no-update-lock-file
```

Licensed under [Apache-2.0](LICENSE).
