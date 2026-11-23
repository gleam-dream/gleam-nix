{
  lib,
  runCommand,
  perl,
  erlang,
}:
# Copies the scope's cached Erlang and removes the listed OTP applications. The
# copy keeps the original's name, so its store path has the same length and
# every embedded reference to the original is rewritten in place, binaries
# included. Nothing is rebuilt.
{ without }:
let
  original = erlang;
in
if without == [ ] then
  throw "gleam-nix: trimErlang needs at least one application to remove."
else
  runCommand original.name
    {
      nativeBuildInputs = [ perl ];
      passthru = {
        inherit original without;
        inherit (original) version;
      };
      meta = original.meta or { };
    }
    ''
      old=${original}
      if [ "''${#old}" -ne "''${#out}" ]; then
        echo "gleam-nix: the trimmed Erlang's store path differs in length from $old." >&2
        exit 1
      fi
      cp -a "$old"/. "$out"/
      chmod -R u+w "$out"

      for application in ${lib.escapeShellArgs without}; do
        found=0
        for directory in "$out"/lib/erlang/lib/"$application"-*; do
          if [ -d "$directory" ]; then
            rm -r "$directory"
            found=1
          fi
        done
        if [ "$found" -eq 0 ]; then
          echo "gleam-nix: Erlang has no application $application to remove." >&2
          exit 1
        fi
      done

      # Same-length rewrite: byte offsets in binaries stay valid.
      grep -rlFZ --no-messages "$old" "$out" | xargs -0 -r perl -pi -e "s|\Q$old\E|$out|g"
      find "$out" -type l -print0 | while IFS= read -r -d "" link; do
        target=$(readlink "$link")
        case "$target" in
          "$old"*) ln -sfn "$out''${target#"$old"}" "$link" ;;
        esac
      done
      if grep -rqF "$old" "$out"; then
        echo "gleam-nix: the trimmed Erlang still embeds $old." >&2
        exit 1
      fi
    ''
