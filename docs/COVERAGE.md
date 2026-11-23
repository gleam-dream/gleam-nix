# Coverage

| Part                                         | Status             | Owner or reason                                                                              |
| -------------------------------------------- | ------------------ | -------------------------------------------------------------------------------------------- |
| Locked graph and source selection            | captured           | [D1 and D2](design.md#d1-locked-graph)                                                       |
| Compiled package and cache identity          | captured           | [D3 and D4](design.md#d3-package-compilation)                                                |
| Development code selection                   | captured           | [D5](design.md#d5-development-code)                                                          |
| BEAM and frontend composition                | captured           | [D6](design.md#d6-composition)                                                               |
| Test checks, runners and services            | designed           | [D7 to D9](design.md#d7-test-checks)                                                         |
| Release and image                            | designed, unstable | [D10](design.md#d10-release-and-image)                                                       |
| Gleam JavaScript packages                    | designed, unstable | [D11](design.md#d11-javascript-packages)                                                     |
| CI commands and cache adapters               | designed           | [D12 and D13](design.md#d12-ci-commands)                                                     |
| Flake entry points and checks                | standard           | Conventional Nix flake exports and executable checks                                         |
| Rebar3, Mix, npm, cross compilation, deploys | out-of-scope       | Existing builders compose through the public package boundary; deploys stay with the adopter |
