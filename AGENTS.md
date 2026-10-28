# Working on Gleam Nix

The public API and invariants are in `docs/design.md`. Keep package compilation,
manifest handling, and foreign build systems at their documented boundaries.

Run `nix flake check --no-update-lock-file` after changes. It owns evaluation,
compilation, runtime composition, dependency propagation, and formatting checks.
Run `nix fmt -- default.nix flake.nix lib/*.nix tests/*.nix examples/*.nix examples/hello/flake.nix`
to format the Nix files, including the executable examples.

Keep dependency derivations independent of the consuming application's source
and full manifest. Do not read fetched package sources during evaluation.
