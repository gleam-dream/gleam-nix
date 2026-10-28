# Coverage

| Part                                          | Status       | Owner or reason                                               |
| --------------------------------------------- | ------------ | ------------------------------------------------------------- |
| Locked graph and source selection             | captured     | [D1 and D2](design.md#d1-locked-graph)                        |
| Compiled package and cache identity           | captured     | [D3 and D4](design.md#d3-package-compilation)                 |
| Development code selection                    | captured     | [D5](design.md#d5-development-code)                           |
| BEAM and frontend composition                 | captured     | [D6](design.md#d6-composition)                                |
| Flake entry points and checks                 | standard     | Conventional Nix flake exports and executable checks          |
| Rebar3, Mix, npm, releases, cross compilation | out-of-scope | Existing builders compose through the public package boundary |
