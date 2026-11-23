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
a [release and image](#ship-an-image), a [Gleam frontend](#build-a-gleam-frontend),
and [CI](#run-ci) that builds only the checks whose inputs changed. Checks,
releases and images run on Linux. The release, image and frontend are
unstable. See the [design](docs/design.md) for every interface.

The library doesn't resolve versions, deploy, support languages other than
Gleam or targets other than Erlang and JavaScript, or run checks and images on
Darwin.

## A service in one flake

A service with a PostgreSQL test suite in four shards, a coverage check, an
image, and CI on a Cachix cache. It is [the service example](examples/service/flake.nix),
which the library's checks evaluate:

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
      ci = gleam-nix.lib.ci pkgs;
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
      checks.${system} = builtins.listToAttrs (
        pkgs.lib.imap1 (index: check: {
          name = "shard-${toString index}";
          value = check;
        }) shards
      );
      packages.${system}.image = gleam.buildImage {
        inherit release;
        name = "my-service";
        port = 8080;
        health = "/health";
        user = "app";
      };
      ci.${system} = ci.declare {
        adapter = ci.adapters.cachix {
          name = "my-cache";
          publicKey = "my-cache.cachix.org-1:...";
        };
        checks = self.checks.${system} // {
          image = self.packages.${system}.image;
        };
        derived.coverage = gleam.mkCoverageCheck { checks = shards; };
      };
    };
}
```

And the one line of workflow, in a job whose name is your required check:

```yaml
jobs:
  ci:
    uses: gleam-dream/gleam-nix/.github/workflows/ci.yml@ci-v1
    with: { declaration: ".#ci.x86_64-linux" }
    secrets: inherit
```

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
  places a module in a chosen shard. All shards share one compile.
- **Inputs.** A check's source is the app's directory and its local
  dependencies, without build directories, `AGENTS.md` or `CLAUDE.md`. Add
  shared files with `extraInputs`.
- **Services** start with a fresh port and state directory per check, so each
  shard has its own database. Two services, or a service and the check, that
  set the same variable fail evaluation. A failing check prints each service's
  log.
- **Results.** Each check writes `report`, one line per test module with its
  verdict, test count and milliseconds. The coverage check fails naming any
  module that ran in no check or in several.
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
- The image reads `PORT`; pass a frontend's output as `assets` and read its
  path from `ASSETS_DIR`.

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
image, never the backend. Its locked Hex packages are fetched as separate
derivations and compiled in one offline `gleam build`. This entry point is
unstable.

## Run CI

The CI layer is apart from the Gleam scope and carries its own version
(`lib.ci pkgs`, version 1). A declaration lists the checks to plan, checks that
always run, derived checks such as coverage, external jobs, and one cache
adapter. Three commands run over it, in any CI vendor:

```sh
nix run github:gleam-dream/gleam-nix#ci -- plan .#ci.x86_64-linux --out plan.json
nix run github:gleam-dream/gleam-nix#ci -- build .#ci.x86_64-linux --check shard-1
nix run github:gleam-dream/gleam-nix#ci -- verify .#ci.x86_64-linux
```

- `plan` asks nix-eval-jobs which checks are missing from the cache, says why
  each missed, and stages them so a compile that two shards share builds once
  first.
- `build` builds one check, or the shared builds, and pushes the result
  through the adapter, reporting push failures and each module's time.
- `verify` is the only verdict. It substitutes every declared result with local
  builds forbidden, names any missing check and the job that should have pushed
  it, then builds the derived checks.

The [reusable workflow](.github/workflows/ci.yml) runs plan, the shared stage,
each missing check, external jobs and verify, and can publish from the default
branch with a command you supply.

| Adapter           | Who reads                     | Who writes                                                |
| ----------------- | ----------------------------- | --------------------------------------------------------- |
| `adapters.cachix` | Anyone the cache admits       | A holder of the cache's write token (`CACHIX_AUTH_TOKEN`) |
| `adapters.attic`  | Anyone the cache admits       | A token with push rights (`ATTIC_TOKEN`)                  |
| `adapters.local`  | Jobs of the same workflow run | Jobs of the same workflow run                             |

There's no default adapter. A GitHub Actions cache adapter waits on a
measurement of the tools behind it. A run without a write credential, such as a
fork's pull request, carries its results through the run-local store and is
reported as degraded.

**Trust.** A store path names the recipe, not the result. Write access to a
cache is therefore merge rights on every repository that reads from it. Record
in the image what tested it, and recover by rebuilding without the cache.

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
