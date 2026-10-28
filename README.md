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

## Capabilities

- Build locked Hex and local Gleam packages independently.
- Supply Git sources through explicit overrides and build Rebar3 and Mix
  packages with Nixpkgs on request.
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
  dependencies require `sourceOverrides`.
- Locked Rebar3 and Mix packages can use `buildForeign = true`, with builder
  options in `foreignArgs.<name>`. Other foreign build tools need `packageOverrides`.
- Optional Hex requirements absent from the manifest are dropped for packages
  without the `gleam` build tool. Missing Gleam requirements remain errors.
- Gleam packages containing Elixir sources need the selected Elixir compiler in
  `nativeBuildInputs` (`packageArgs.nativeBuildInputs` for the root). Retain and
  load Elixir's runtime separately; see the [compilation contract](docs/design.md#d3-package-compilation).
- Compiled Gleam dependencies must use the same Gleam and Erlang derivations.
  Select alternative toolchains through the scope's `overrideScope`.
- `includeDev = true` compiles root development/test modules and includes their
  dependencies. Run your test runner separately to execute them.
- Flake outputs cover x86-64 Linux, ARM64 Linux and ARM64 macOS. Gleam compilation
  to JavaScript, release assembly and cross compilation remain outside this library.

## Examples and reference

The [design reference](docs/design.md) documents API arguments, overrides, output
layout and source filtering. The [checks](tests/default.nix) exercise package
reuse, selective invalidation, runtime closures, generated headers and composition.
Run them with:

```sh
nix flake check --no-update-lock-file
```
