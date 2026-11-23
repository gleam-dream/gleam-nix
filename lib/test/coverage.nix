{ lib, runCommand }:
# A derived check: every test module the sources declare ran in exactly one of
# the given checks. The expected set comes from each check's compile, never from
# what a runner reported.
{
  checks,
  name ? "coverage",
}:
let
  compiles = lib.unique (map (check: check.testModules) checks);
  reports = lib.concatMapStrings (check: ''
    cut -f1 ${check}/report | sed 's|$|\t${check.name}|' >> ran
  '') checks;
in
runCommand "gleam-nix-${name}" { } ''
  LC_ALL=C sort -u ${lib.escapeShellArgs compiles} > expected
  : > ran
  ${reports}
  cut -f1 ran | LC_ALL=C sort -u > seen
  missing=$(LC_ALL=C comm -23 expected seen)
  duplicated=$(cut -f1 ran | LC_ALL=C sort | uniq -d)
  status=0
  if [ -n "$missing" ]; then
    echo "gleam-nix: test modules that ran in no check:" >&2
    printf '  %s\n' $missing >&2
    status=1
  fi
  if [ -n "$duplicated" ]; then
    echo "gleam-nix: test modules that ran in more than one check:" >&2
    for module in $duplicated; do
      printf '  %s (%s)\n' "$module" "$(awk -F '\t' -v m="$module" '$1 == m { printf "%s%s", sep, $2; sep = ", " }' ran)" >&2
    done
    status=1
  fi
  [ "$status" -eq 0 ]
  mkdir -p "$out"
  cp expected "$out/expected"
  cp ran "$out/ran"
''
