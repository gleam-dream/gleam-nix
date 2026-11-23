#!/usr/bin/env bash
# gleam-nix-ci: plan, build and verify the checks a CI declaration lists.
#
#   gleam-nix-ci plan   DECLARATION [--out FILE]
#   gleam-nix-ci build  DECLARATION (--check NAME | --external NAME | --shared PLAN_FILE)
#   gleam-nix-ci verify DECLARATION
#
# DECLARATION is a flake reference to a declaration, such as .#ci.x86_64-linux.
# The commands contain no Gleam and no cache vendor: the declaration's adapter
# supplies the substituter, the credentials check and the push.
set -euo pipefail

NIX=${GLEAM_NIX_CI_NIX:-nix}
EVAL=${GLEAM_NIX_CI_EVAL:-nix-eval-jobs}
LOCAL_STORE=${GLEAM_NIX_CI_LOCAL_STORE:-}

say() { printf 'gleam-nix-ci: %s\n' "$*" >&2; }
fail() {
  say "$*"
  exit 1
}
output() {
  # Step outputs for GitHub Actions; harmless elsewhere.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi
}
summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}

[ $# -ge 2 ] || fail "usage: gleam-nix-ci plan|build|verify DECLARATION [options]"
command=$1
declaration=$2
shift 2

# Metadata of every declared check: names, derivations and outputs. Nothing
# is built and no build output is read.
metadata() {
  "$NIX" eval --json "$declaration" --apply '
    d:
    let
      describe = group: builtins.mapAttrs (_: c: { drv = c.drvPath; out = c.outPath; }) (d.${group} or { });
    in
    {
      version = d.version;
      checks = describe "checks";
      always = describe "always";
      derived = describe "derived";
      external = describe "external";
    }'
}

# Builds the adapter, configures its substituter, and runs its setup. Sets
# can_push to 1 when the run holds a write credential.
adapter=""
can_push=0
degraded=0
substituters=()
use_adapter() {
  adapter=$("$NIX" build --no-link --print-out-paths "$declaration.adapter")
  local substituter key
  substituter=$(jq -r '.substituter // empty' "$adapter/adapter.json")
  key=$(jq -r '.publicKey // empty' "$adapter/adapter.json")
  if [ "$substituter" = local ]; then
    substituter=""
  fi
  if [ -n "$substituter" ]; then substituters+=("$substituter"); fi
  if [ -n "$LOCAL_STORE" ]; then
    mkdir -p "$LOCAL_STORE"
    substituters+=("file://$LOCAL_STORE?trusted=1")
  fi
  local config=""
  if [ "${#substituters[@]}" -gt 0 ]; then config="extra-substituters = ${substituters[*]}"; fi
  if [ -n "$key" ]; then config="$config"$'\n'"extra-trusted-public-keys = $key"; fi
  export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG$'\n'}$config"
  local status=0
  "$adapter/bin/setup" || status=$?
  case "$status" in
    0) can_push=1 ;;
    3) can_push=0 ;;
    *) fail "the $(adapter_name) adapter's setup failed with status $status." ;;
  esac
}
adapter_name() { jq -r '.name' "$adapter/adapter.json"; }
adapter_scope() { jq -r ".scope.$1" "$adapter/adapter.json"; }
teardown() { if [ -n "$adapter" ]; then "$adapter/bin/teardown" || true; fi; }
trap teardown EXIT

push() {
  # A run without a write credential keeps results in the run-local store, if
  # the workflow carries one, and reports itself degraded.
  local failures=0
  if [ "$can_push" -eq 1 ]; then
    "$adapter/bin/push" "$@" || failures=1
  else
    degraded=1
    if [ -n "$LOCAL_STORE" ]; then
      "$NIX" copy --to "file://$LOCAL_STORE" "$@" || failures=1
    else
      say "no write credential and no run-local store: results stay on this runner."
    fi
  fi
  say "push failures: $failures"
  output push-failures "$failures"
  if [ "$degraded" -eq 1 ]; then
    say "degraded: this run cannot write to the $(adapter_name) cache."
    output degraded true
    summary "Degraded: this run cannot write to the $(adapter_name) cache."
  fi
}

case "$command" in
  plan)
    out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --out) out=$2; shift 2 ;;
        *) fail "plan: unknown option $1" ;;
      esac
    done
    started=$(date +%s)
    use_adapter
    meta=$(metadata)
    # The evaluator's own cache-status query; its output format is pinned by
    # the library's checks.
    checks=$("$EVAL" --flake "$declaration.checks" --check-cache-status --workers "${GLEAM_NIX_CI_WORKERS:-4}" | jq -sc .)
    external=$("$EVAL" --flake "$declaration.external" --check-cache-status --workers 1 | jq -sc .)
    plan=$(jq -nc \
      --argjson checks "$checks" --argjson external "$external" --argjson meta "$meta" \
      --arg adapter "$(adapter_name)" --argjson started "$started" --argjson now "$(date +%s)" '
      def present: .cacheStatus == "cached" or .cacheStatus == "local";
      def short: sub("^/nix/store/[a-z0-9]{32}-"; "") | sub("\\.drv$"; "");
      ($checks | map(select(has("error")))) as $errors
      | ($checks | map(select(has("error") | not))) as $evaluated
      | ($evaluated | map(select(present | not))) as $missing
      | ($missing | map(.drvPath)) as $own
      # A build that two missing checks need, such as a shared compile, runs
      # once in an earlier stage.
      | ([$missing[] | .neededBuilds[] | select(. as $d | $own | index($d) | not)]
          | group_by(.) | map(select(length > 1) | .[0])) as $shared
      | {
          version: $meta.version,
          adapter: $adapter,
          errors: ($errors | map({ (.attr): .error }) | add // {}),
          cached: ($evaluated | map(select(present) | .attr)),
          missing: ($missing | map({ (.attr): ("not in the cache; it needs " + (.neededBuilds | map(short) | join(", "))) }) | add // {}),
          stages: (
            (if ($shared | length) > 0 then [{ name: "shared", jobs: [{ name: "shared", drvs: $shared }] }] else [] end)
            + [{ name: "checks", jobs: (($missing | map(.attr)) + ($meta.always | keys) | unique | map({ name: . })) }]
          ),
          external: {
            run: ($external | map(select(present | not) | .attr)),
            cached: ($external | map(select(present) | .attr))
          },
          seconds: ($now - $started)
        }')
    if [ -n "$out" ]; then printf '%s\n' "$plan" > "$out"; fi
    printf '%s\n' "$plan"
    jq -r '.missing | to_entries[] | "gleam-nix-ci: \(.key) misses: \(.value)"' <<< "$plan" >&2
    jq -r '.errors | to_entries[] | "gleam-nix-ci: \(.key) failed to evaluate: \(.value)"' <<< "$plan" >&2
    output plan "$plan"
    output shared "$(jq -c '[.stages[] | select(.name == "shared") | .jobs[]]' <<< "$plan")"
    output checks "$(jq -c '[.stages[] | select(.name == "checks") | .jobs[].name]' <<< "$plan")"
    output external "$(jq -c '.external.run' <<< "$plan")"
    summary "$(jq -r '"Planned \(.missing | length) missing, \(.cached | length) cached in \(.seconds) s."' <<< "$plan")"
    if [ "$(jq '.errors | length' <<< "$plan")" -gt 0 ]; then exit 1; fi
    ;;

  build)
    target=""
    kind=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --check) kind=checks; target=$2; shift 2 ;;
        --external) kind=external; target=$2; shift 2 ;;
        --shared) kind=shared; target=$2; shift 2 ;;
        *) fail "build: unknown option $1" ;;
      esac
    done
    [ -n "$kind" ] || fail "build needs --check NAME, --external NAME or --shared PLAN_FILE."
    use_adapter
    started=$(date +%s)
    if [ "$kind" = shared ]; then
      mapfile -t drvs < <(jq -r '.stages[] | select(.name == "shared") | .jobs[].drvs[]' "$target")
      [ "${#drvs[@]}" -gt 0 ] || { say "no shared builds planned."; exit 0; }
      mapfile -t paths < <("$NIX" build --no-link --print-out-paths "${drvs[@]/%/^*}")
      label="shared builds"
    else
      group=$kind
      if [ "$kind" = checks ] && [ "$(metadata | jq --arg n "$target" '.always | has($n)')" = true ]; then
        group=always
      fi
      mapfile -t paths < <("$NIX" build --no-link --print-out-paths "$declaration.$group.$target")
      label=$target
    fi
    seconds=$(($(date +%s) - started))
    say "built $label in $seconds s."
    summary "Built $label in $seconds s."
    for path in "${paths[@]}"; do
      if [ -f "$path/report" ]; then
        summary "$(printf '| Module | Verdict | Tests | ms |\n| --- | --- | --- | --- |\n'; awk -F '\t' '{ printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }' "$path/report")"
      fi
    done
    push "${paths[@]}"
    ;;

  verify)
    [ $# -eq 0 ] || fail "verify takes no options."
    use_adapter
    meta=$(metadata)
    missing=0
    # Every declared result must come from a substituter: local builds are
    # forbidden, so a skipped or failed job never counts as a pass.
    while IFS=$'\t' read -r group name out; do
      if ! "$NIX" build --no-link --max-jobs 0 "$out" 2> /dev/null; then
        missing=$((missing + 1))
        if [ "$group" = external ]; then job="external job $name"; else job="job $name"; fi
        say "$group $name is missing: $out came from no substituter. The $job should have pushed it to the $(adapter_name) cache, which $(adapter_scope write) can write and $(adapter_scope read) can read."
      fi
    done < <(jq -r '(["checks", "always", "external"][]) as $g | .[$g] | to_entries[] | [$g, .key, .value.out] | @tsv' <<< "$meta")
    if [ "$missing" -gt 0 ]; then
      fail "$missing declared results are missing; the run fails."
    fi
    # Derived checks, such as coverage, build here from the substituted results.
    while IFS= read -r name; do
      "$NIX" build --no-link "$declaration.derived.$name" || fail "derived check $name failed."
    done < <(jq -r '.derived | keys[]' <<< "$meta")
    if [ "$can_push" -eq 0 ]; then
      say "degraded: this run cannot write to the $(adapter_name) cache."
      output degraded true
    fi
    say "every declared result is present."
    summary "Verified every declared result."
    ;;

  *)
    fail "unknown command $command; use plan, build or verify."
    ;;
esac
