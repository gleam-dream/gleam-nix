# Coverage

| Part                                                           | Status       | Owner or reason                                                                                     |
| -------------------------------------------------------------- | ------------ | --------------------------------------------------------------------------------------------------- |
| Locked graph and source selection                              | captured     | [D1 and D2](design.md#d1-locked-graph)                                                              |
| Compiled package and cache identity                            | captured     | [D3 and D4](design.md#d3-package-compilation)                                                       |
| Development code selection                                     | captured     | [D5](design.md#d5-development-code)                                                                 |
| BEAM and frontend composition                                  | captured     | [D6](design.md#d6-composition)                                                                      |
| Test checks, runners and services                              | captured     | [D7 to D9](design.md#d7-test-checks)                                                                |
| Release and image                                              | captured     | [D10](design.md#d10-release-and-image), unstable until a second user                                |
| Gleam JavaScript packages                                      | captured     | [D11](design.md#d11-javascript-packages), unstable until a second user                              |
| Flake entry points and checks                                  | standard     | Conventional Nix flake exports and executable checks                                                |
| Rebar3, Mix, npm, cross compilation, deploys, CI orchestration | out-of-scope | Existing builders compose through the public package boundary; deploys and CI stay with the adopter |
