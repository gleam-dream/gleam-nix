# Gleam Nix

Build each Gleam package as an independent Nix derivation. Projects reuse compiled
dependencies when their sources, resolved dependencies, toolchain, platform, and
build settings match. Editing application code leaves those dependencies cached.

The compiler target is Erlang, using Gleam 1.19 or newer. Hex and local packages
work directly. Git sources and non-Gleam build tools use explicit overrides.
JavaScript frontend assets compose through the existing Nixpkgs builders.

## Quickstart

Start with an Erlang Gleam project and Nix with flakes enabled. Keep
`manifest.toml` current with `gleam deps download`; Gleam Nix uses the locked graph
and does not resolve versions. In a Git-backed flake, track `gleam.toml`,
`manifest.toml`, and your source files so Nix includes them.

Save this as `flake.nix` in your project. For a local checkout, replace the
GitHub input with `path:/absolute/path/to/gleam-nix`.
The flake selects the current platform from x86-64 Linux, ARM64 Linux, and ARM64 macOS.

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
      ...
    }:
    let
      forSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
    in
    {
      packages = forSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          gleam = gleam-nix.lib.mkLib pkgs;
        in
        {
          default = (gleam.importProject { src = ./.; }).package;
        }
      );
      devShells = forSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          gleam = gleam-nix.lib.mkLib pkgs;
        in
        {
          default = pkgs.mkShell {
            nativeBuildInputs = [ gleam.erlang ];
            buildInputs = [ self.packages.${system}.default ];
          };
        }
      );
    };
}
```

In a Git-backed project, track the new flake with `git add flake.nix` before
building. Build your package, then run a module named `my_app` that exports `main`:

```sh
nix build
nix develop --command erl -noshell -eval 'my_app:main(), halt(0).'
```

Replace `my_app` with your entry module. `result` contains a compiled OTP library
and Gleam compiler metadata. The development shell adds that library and its
runtime dependencies to `ERL_LIBS` through standard setup hooks. Deployment
launchers and OTP/Mix releases remain the caller's responsibility.

The [hello example](examples/hello) contains this complete flake and a runnable
module. From this repository, `nix develop --command erl -noshell -eval
'hello:main(), halt(0).'` prints `Hello from a cached Gleam package`.
Commit the resulting `flake.lock` to keep the selected inputs reproducible.

## How builds and caching work

`importProject` reads the root dependency names from `gleam.toml` and each locked
package's dependency edges from `manifest.toml`. It fetches Hex sources using
their locked versions and checksums, or uses local sources and explicit overrides.

Each package gets its own derivation. `gleam compile-package` compiles it against
already compiled dependencies, retaining BEAM code and Gleam's compiler metadata.
The root application then builds against those outputs. Dependency derivations
exclude the consuming application's source, full manifest, and unrelated packages.

| Change                   | Outputs rebuilt                       |
| ------------------------ | ------------------------------------- |
| Application source       | The application                       |
| Dependency source        | That dependency and its consumers     |
| Separate frontend source | The frontend and final asset assembly |

Frontend isolation requires separate source inputs. If the backend's `src = ./.`
also includes frontend files, editing them rebuilds the backend too. Compiled
Gleam dependencies remain reusable.

Nix reuses matching outputs already present in its store. Sharing them across
machines uses the caller's configured binary cache and its usual trust settings.
Compatible package names and versions alone do not establish a cache hit: selected
Nixpkgs inputs, compiler derivations, platform, and build settings also matter.
Dependency ordering does not affect cache identity.

## Compose with Erlang and Elixir

Use one BEAM package set for the whole project. Build foreign packages with
Nixpkgs' `buildRebar3` or `buildMix`, then attach Gleam Nix metadata with
`fromBeamPackage`. The adapter reuses the compiled output.

This complete [composition example](examples/beam-composition.nix) imports a
manifest containing `native_math` and `elixir_math` at version `0.1.0`.
The former declares the OTP application name `actual_native`:

```nix
{ gleam, src }:
let
  inherit (gleam) beamPackages;
  project = gleam.importProject {
    inherit src;
    packageOverrides = _final: _prev: {
      native_math = gleam.fromBeamPackage {
        pname = "native_math";
        version = "0.1.0";
        otpAppName = "actual_native";
        package = beamPackages.buildRebar3 {
          name = "actual_native";
          version = "0.1.0";
          src = project.sources.native_math;
        };
      };
      elixir_math = gleam.fromBeamPackage {
        pname = "elixir_math";
        version = "0.1.0";
        package = beamPackages.buildMix {
          name = "elixir_math";
          version = "0.1.0";
          src = project.sources.elixir_math;
        };
      };
    };
  };
in
project
```

Save this as `beam-composition.nix`. In the quickstart, replace
`gleam.importProject { src = ./.; }` with
`import ./beam-composition.nix { inherit gleam; src = ./.; }`.
Names, versions, OTP application names, and direct dependency edges must match
the locked manifest. When a foreign package has dependencies, name the override
arguments `final: prev:` and pass the corresponding `final.<name>` values as
`beamDeps` to its builder. The adapter inherits that dependency list.

The [composition check](tests/composition.nix) imports this example, calls both
packages through Gleam FFI, and starts the resulting OTP application. Mixed
Elixir applications need the selected Elixir runtime. Add
`gleam.beamPackages.elixir` to the shell's `nativeBuildInputs` and start them with
`elixir`, `iex`, or an Elixir release.

## Compose with JavaScript assets

Build frontend assets in a separate npm, pnpm, or Yarn derivation. The
[frontend example](examples/composition.nix) uses `buildNpmPackage` with
`importNpmLock`, then uses `symlinkJoin` to place the assets beside the BEAM package.
Its combined output contains the backend library and `share/www/index.html`.

From this repository:

```sh
nix build .#frontend
nix build .#combined
cat result/share/www/index.html
```

Frontend changes stay outside Gleam dependency inputs. Gleam compilation to
JavaScript is outside the current scope.

## API reference

Create a scope with `gleam-nix.lib.mkLib pkgs`, or import a local checkout with
`import ../gleam-nix { inherit pkgs; }`. `gleam.importProject` accepts:

| Argument           | Default                  | Purpose                                                               |
| ------------------ | ------------------------ | --------------------------------------------------------------------- |
| `src`              | Required                 | Root project source, readable during evaluation.                      |
| `manifest`         | `src + "/manifest.toml"` | Locked graph, readable during evaluation.                             |
| `sourceOverrides`  | `{}`                     | Replace sources of declared packages.                                 |
| `packageOverrides` | `final: prev: {}`        | Replace how declared packages are built.                              |
| `includeDev`       | `false`                  | Compile root development/test modules and include their dependencies. |
| `packageArgs`      | `{}`                     | Root derivation attributes and hooks.                                 |

The result exposes `package` (compiled root), `packages` (compiled dependencies by
name), `sources` (source paths or fetcher derivations), and `manifest` (parsed lock).
Unused development dependencies remain lazy in production builds. `includeDev`
compiles test modules; run your test runner separately to execute them.

`packageArgs` cannot replace the project's identity, source, dependency edges,
target, or development mode. Use the project inputs for those choices.

### Toolchain selection

Override the scope to select a consistent BEAM package set:

```nix
gleam = (gleam-nix.lib.mkLib pkgs).overrideScope (_: _: {
  beamPackages = pkgs.beam29Packages;
});
```

The scope also permits overriding `gleam`. Compiled Gleam dependencies must use
the same Gleam and Erlang derivations. Use this same scope for the shell runtime
and foreign builders.

### Source overrides

Git sources require an explicit fetcher. Replace the placeholders with the
manifest's locked commit and the corresponding Nix source hash:

```nix
gleam.importProject {
  src = ./.;
  sourceOverrides.my_library = pkgs.fetchgit {
    url = "https://github.com/example/my_library.git";
    rev = "<locked commit>";
    hash = "<Nix source hash>";
  };
}
```

An override must implement the locked package identity. Local manifest paths
resolve relative to the root source; include them in the flake source or provide
source overrides. Overrides for undeclared packages fail evaluation.

### Individual package builds

```nix
gleam.buildGleamPackage {
  pname = "my_library";
  version = "0.1.0";
  src = ./my_library;
  beamDeps = [ project.packages.gleam_stdlib ];
}
```

This interface takes explicit metadata and supports fetched sources without
reading them during evaluation. Outputs follow `lib/erlang/lib/<otp-name>-<version>/`
and retain patched source under `src/`. Use `override` for builder arguments such
as `beamDeps`, and `overrideAttrs` for ordinary derivation attributes and hooks.

See the [design reference](docs/design.md) for output layout, source filtering,
metadata contracts, graph validation, and researched precedents.

## Checks and limitations

```sh
nix flake check --no-update-lock-file
```

The checks execute the quickstart and Erlang/Elixir/frontend examples. They also
cover cache identity, selective invalidation, development-code selection,
malformed graphs, conflicting outputs, fetched sources, and runtime closures.

The supported flake systems are x86-64 Linux, ARM64 Linux, and ARM64 macOS.
The pinned Nixpkgs revision excludes Intel macOS. Each platform needs a native
or remote builder; validation on one host does not establish builds on the others.
The library leaves dependency resolution, releases, and cross compilation to
Gleam and the caller's existing tools.
