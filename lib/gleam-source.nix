{ lib, cleanSource }:
# The files a Gleam package's build reads: its configuration, manifest, src,
# priv and include, and test when its development code compiles. Anything
# else in the directory, such as a README or docs, is not an input, so editing
# it rebuilds nothing. The standard clean source filter still applies.
{
  directory,
  includeTest ? false,
}:
lib.fileset.intersection (lib.fileset.fromSource (cleanSource directory)) (
  lib.fileset.unions (
    map (name: lib.fileset.maybeMissing (directory + "/${name}")) (
      [
        "gleam.toml"
        "manifest.toml"
        "src"
        "priv"
        "include"
      ]
      ++ lib.optional includeTest "test"
    )
  )
)
