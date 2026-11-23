{ lib, cleanSource }:
let
  # Agent documents, such as a design gate's notes, that no build reads.
  agentDocuments =
    directory:
    lib.fileset.fileFilter (
      file:
      builtins.elem file.name [
        "AGENTS.md"
        "CLAUDE.md"
      ]
    ) directory;
in
{
  # The files a Gleam package's build reads: its configuration, manifest, src,
  # priv and include, and its development code, test and dev, when that
  # compiles. Anything else in the directory, such as a README, docs or agent
  # documents, is not an input, so editing it rebuilds nothing. The standard
  # clean source filter still applies.
  __functor =
    _:
    {
      directory,
      includeDev ? false,
    }:
    lib.fileset.difference (lib.fileset.intersection (lib.fileset.fromSource (cleanSource directory)) (
      lib.fileset.unions (
        map (name: lib.fileset.maybeMissing (directory + "/${name}")) (
          [
            "gleam.toml"
            "manifest.toml"
            "src"
            "priv"
            "include"
          ]
          ++ lib.optionals includeDev [
            "test"
            "dev"
          ]
        )
      )
    )) (agentDocuments directory);

  # A path without its agent documents, for inputs an adopter adds.
  withoutAgentDocuments = path: lib.fileset.difference path (agentDocuments path);
}
