# Design

Gleam Nix builds each Gleam package as an independent Nix derivation. It reads the
resolved dependency graph from Gleam's manifest and preserves compiled package
outputs across consumers with identical inputs.

## Scope and terms

A **locked package** is a package entry in `manifest.toml`. A **package output**
contains one compiled OTP application and Gleam's compiler metadata. A
**project** combines a root Gleam package with its locked packages.

The initial compiler target is Erlang. The library does not resolve dependency
versions, update manifests, replace Gleam's development workflow, or implement
Rebar3, Mix, npm, release assembly, or cross compilation.

Nix owns immutable output storage, build scheduling, and binary-cache access.
The caller owns the Nixpkgs revision and toolchain selection. Gleam owns source
compilation and the compiler metadata format.

## Public interfaces

`import ./default.nix { inherit pkgs; }` and `lib.mkLib pkgs` create the same
package scope. The scope supports `overrideScope`; changing `beamPackages`
selects a consistent Erlang/Elixir package set.

- `buildGleamPackage { pname; version; src; beamDeps ? []; includeDev ? false; ... }`
  compiles one package. Standard derivation attributes and build hooks remain
  available. It does not read a fetched source during evaluation.
  Use `override` to change builder arguments and `overrideAttrs` for ordinary
  derivation attributes and hooks.
- `importProject { src; manifest ? src + "/manifest.toml"; sourceOverrides ? {};
packageOverrides ? final: prev: {}; includeDev ? false; packageArgs ? {}; }`
  returns `package`, `packages`, `sources`, and the parsed `manifest`.
  The root source and manifest must be readable during evaluation.
  `packageArgs` customizes ordinary derivation attributes; it cannot replace
  the root identity, source, dependency graph, target, or development mode.
- `readManifest path` validates and returns the manifest's package entries.
- `fromBeamPackage { package; pname; version; otpAppName ? pname;
beamDeps ? package.beamDeps or []; appDir ? ...; }` attaches package metadata
  to an already compiled BEAM derivation. It does not rebuild that package.

A package output follows Nixpkgs' layout:
`lib/erlang/lib/<otp-application>-<version>/`. It retains `ebin`,
`_gleam_artefacts`, `include`, and `priv` when produced by Gleam.
`src/` retains the patched package source for consumers such as Mix.
Setup hooks and propagated dependency references live in `nix-support/`.
The output is a compiled library; executable launchers and deployment releases
belong to the caller. The example flake provides a development shell that loads
the library and its runtime dependencies through the setup hooks.

## Behavior and invariants

### D1: Locked graph

When importing a project, dependency edges come from locked package
`requirements`. Root edges come from `gleam.toml` dependency names.
Duplicate locked names, missing edges, and cycles fail evaluation with a
diagnostic naming the offending packages. The library does not perform version
resolution or silently repair the manifest.

### D2: Sources

Hex packages use their manifest version and outer checksum through
Nixpkgs' `fetchHex`. Local paths resolve relative to the root source.
`sourceOverrides` replaces a declared package source without changing its edges.
A Git or other unsupported source requires an explicit source override.
A source override for an undeclared package fails evaluation.

Fetching creates Nix fetcher derivations. The library never reads their output
to discover metadata during evaluation, so Hex builds do not require import
from derivation. The locked record supplies the package name and version.

### D3: Package compilation

A Gleam package compiles with `gleam compile-package`, the selected Erlang
toolchain, and previously compiled dependencies. It preserves compiler metadata
beside BEAM bytecode. Package outputs expose their direct `beamDeps`, OTP
application name, application directory, and Gleam compiler.
During compilation, the current package is discoverable under its OTP name so
Erlang FFI can use `include_lib` for its own generated record headers.

A package that ships Elixir sources next to its Gleam modules needs the Elixir
compiler on `PATH`: supply it through `nativeBuildInputs` (for a project root,
`packageArgs.nativeBuildInputs`). Gleam runs `elixir` from the library
directory and writes there, so the build hands it a writable copy of the
dependency link farm instead of the read-only store path.

The compiler input does not retain or load Elixir's runtime for consumers.
The caller retains the selected `beamPackages.elixir` in its runtime environment
or through the package's `propagatedBuildInputs` (for a project root,
`packageArgs.propagatedBuildInputs`). A bare Erlang launcher adds
`${elixir}/lib/elixir/lib` to `ERL_LIBS` and starts the `elixir` application
before calling Elixir modules. Use the same BEAM package set as the build.

The selected compiler must support `--no-dev` and application-file generation
(Gleam 1.19 or newer). A Gleam dependency compiled with another compiler or Erlang
derivation fails evaluation. The root project must select the Erlang target.
An unsupported locked build tool fails with guidance to provide a package
override.

### D4: Cache identity

Each dependency derivation depends on its own source, resolved compiled
dependencies, selected tools, and build options. It excludes the consuming
project's source, full manifest, and unrelated locked packages.
Equivalent dependencies across projects have equal derivation paths.
Dependency ordering does not affect the derivation path.
Changing application code changes the application derivation while leaving its
dependency derivations unchanged. Changing a dependency invalidates its consumers.
Local path inputs exclude `build`, `_build`, `node_modules`, and `.direnv`
directories only at the source root. Nested source namespaces and resources
with these names remain intact. Local inputs also use Nixpkgs' standard clean
source filter.
Prepared source objects and store-context strings are kept opaque during evaluation.

### D5: Development code

Dependency packages always compile without their development code and
development dependencies. Production root builds exclude root development
dependencies. With `includeDev = true`, only the root additionally compiles its
development/test modules and declares its development dependencies.

### D6: Composition

`beamDeps` retains dependency outputs in the Nix closure. A setup hook adds the
standard application directory to `ERL_LIBS`. Compiled Rebar3 and Mix packages
can enter the locked graph through `packageOverrides` and
`fromBeamPackage`. They must use the caller's selected BEAM package set.
Overrides replace the build method while preserving the locked name, version,
OTP application name, and resolved direct dependency edges.

The compiler library directory includes the transitive dependency closure.
Conflicting outputs or aliases with the same package name or OTP application
name fail evaluation, rather than depending on directory traversal order.
Multiple references to one physical output must agree on its compiler and
dependency metadata.
Builders and `fromBeamPackage` own that metadata declaration. Standalone callers
must reuse those canonical nodes; manually changing metadata fields on a
returned package is outside the supported API. Adapter metadata declares how
an output was built and does not inspect or prove its bytecode provenance.
The compiler receives explicit mappings when package and OTP application names
differ.

JavaScript assets belong to a separate npm/pnpm/Yarn derivation. Final
application assembly can consume those assets alongside the compiled BEAM
package. A Gleam JavaScript compiler backend is outside this initial scope.

## Implementation boundaries

`lib/manifest.nix` owns graph validation. `lib/import-project.nix` owns source
selection and graph construction. `lib/build-package.nix` owns compilation and
the BEAM output contract. `lib/beam.nix` owns dependency closure and compatibility
checks. `lib/default.nix` binds these functions to the caller's package set.

## Research and decisions

The implementation takes the package graph approach from
[crate2nix](https://github.com/nix-community/crate2nix), which builds individual
crates. It uses the input-isolation principle illustrated by
[Crane's dependency builds](https://crane.dev/API.html#cranelibbuilddepsonly):
application source changes must not invalidate dependency compilation.

[deps_nix](https://github.com/code-supply/deps_nix) demonstrates compiled Mix
dependencies as separate derivations. Reusing
[Nixpkgs' BEAM builders](https://github.com/NixOS/nixpkgs/tree/master/pkgs/development/beam-modules)
keeps native compilation, Mix configuration, and Rebar3 plugins with their
existing owners.

[Nixpkgs' JavaScript support](https://nixos.org/manual/nixpkgs/unstable/#javascript-buildNpmPackage)
provides a separate frontend dependency graph. Asset assembly can depend on its
output without coupling npm inputs to every Gleam dependency.

[Gleam's compilation API](https://gleam.run/documentation/command-line-reference/#compile-package)
accepts already compiled dependencies from the same compiler version. This
provides the package boundary without a compiler fork.
