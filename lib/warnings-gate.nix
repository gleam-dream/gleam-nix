{ lib }:
# Fails a root package's compile on any Gleam or Erlang warning. The test
# check and the release apply the same gate, so what ships passed it twice.
purpose: package:
package.overrideAttrs (previous: {
  buildPhase = ''
    # Gleam's package compiler has no warnings-as-errors flag. It compiles
    # only this package, so every warning it prints is the root's own.
    gleamNixCompileLog="$TMPDIR/gleam-nix-compile.log"
    exec 3>&2 2> >(tee "$gleamNixCompileLog" >&3)
    gleamNixTee=$!
    ${previous.buildPhase}
    exec 2>&3 3>&-
    wait "$gleamNixTee"
    if grep -q '^warning: ' "$gleamNixCompileLog"; then
      echo "gleam-nix: Gleam warnings in ${package.gleamPackageName} fail ${purpose}." >&2
      exit 1
    fi
    # Erlang sources compile again with warnings as errors, against the
    # compiled dependencies and this package's own generated headers.
    gleamNixErlang=()
    for gleamNixDirectory in src ${lib.optionalString package.includeDev "test"}; do
      if [ -d "$gleamNixDirectory" ]; then
        while IFS= read -r -d "" gleamNixFile; do
          gleamNixErlang+=("$gleamNixFile")
        done < <(find "$gleamNixDirectory" -type f -name '*.erl' -print0)
      fi
    done
    if [ "''${#gleamNixErlang[@]}" -gt 0 ]; then
      gleamNixIncludes=()
      for gleamNixDirectory in compiled/${package.otpAppName}/include include src; do
        if [ -d "$gleamNixDirectory" ]; then gleamNixIncludes+=(-I "$gleamNixDirectory"); fi
      done
      mkdir -p "$TMPDIR/gleam-nix-erlc"
      if ! erlc -Werror -o "$TMPDIR/gleam-nix-erlc" -pa compiled/${package.otpAppName}/ebin \
        "''${gleamNixIncludes[@]}" "''${gleamNixErlang[@]}"; then
        echo "gleam-nix: Erlang warnings in ${package.gleamPackageName} fail ${purpose}." >&2
        exit 1
      fi
    fi
  '';
})
