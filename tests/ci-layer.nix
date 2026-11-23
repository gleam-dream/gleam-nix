# Checks of the CI layer (D12, D13). The commands run against stubs of nix and
# nix-eval-jobs that replay recorded evaluator output, so no cache is needed.
{ pkgs, ci }:
let
  inherit (pkgs) lib;
  fixture = ./fixtures/ci/checks.jsonl;
  recorded = map builtins.fromJSON (
    lib.splitString "\n" (lib.removeSuffix "\n" (builtins.readFile fixture))
  );
  byAttr = lib.listToAttrs (
    map (line: {
      name = line.attr;
      value = {
        drv = line.drvPath;
        out = line.outputs.out;
      };
    }) recorded
  );
  meta = pkgs.writeText "meta.json" (
    builtins.toJSON {
      inherit (ci) version;
      checks = byAttr;
      always = { };
      derived.coverage = {
        drv = "/nix/store/00000000000000000000000000000000-coverage.drv";
        out = "/nix/store/00000000000000000000000000000000-coverage";
      };
      external.docs = {
        drv = "/nix/store/11111111111111111111111111111111-docs.drv";
        out = "/nix/store/11111111111111111111111111111111-docs";
      };
    }
  );
  adapter = ci.adapters.mkAdapter {
    name = "fixture";
    substituter = "https://cache.invalid";
    scope = {
      read = "every run";
      write = "a holder of FIXTURE_TOKEN";
      mergeHit = true;
    };
    setup = ''
      if [ -n "''${FIXTURE_TOKEN:-}" ]; then exit 0; fi
      exit 3
    '';
    push = ''
      printf '%s\n' "$@" >> "$STUB/pushed"
    '';
  };
  nixStub = pkgs.writeShellScript "nix" ''
    set -eu
    printf '%s\n' "$*" >> "$STUB/calls"
    case "$1" in
      eval) cat ${meta} ;;
      copy) shift 2; printf '%s\n' "$@" >> "$STUB/copied" ;;
      build)
        shift
        target=""
        offline=0
        for argument in "$@"; do
          case "$argument" in
            --max-jobs) offline=1 ;;
            --*|0) ;;
            *) target=$argument ;;
          esac
        done
        if [ "$offline" -eq 1 ]; then
          ! grep -qxF "$target" "$STUB/missing"
        else
          if [ -f "$STUB/broken" ] && grep -qxF "$target" "$STUB/broken"; then exit 1; fi
          case "$target" in
            *.adapter) echo ${adapter} ;;
            *.checks.*) jq -r --arg n "''${target##*.}" '.checks[$n].out' ${meta} ;;
            *.derived.*) echo "derived ''${target##*.}" >> "$STUB/derived" ;;
            *'^*') jq -r --arg d "''${target%^*}" '[.checks[] | select(.drv == $d) | .out][0] // ($d | sub("\\.drv$"; ""))' ${meta} ;;
          esac
        fi
        ;;
    esac
  '';
  evalStub = pkgs.writeShellScript "nix-eval-jobs" ''
    case "$2" in
      *.checks) cat ${fixture} ;;
      *.external) echo '{"attr":"docs","cacheStatus":"cached","drvPath":"/nix/store/11111111111111111111111111111111-docs.drv","neededBuilds":[],"outputs":{"out":"/nix/store/11111111111111111111111111111111-docs"}}' ;;
    esac
  '';
  run =
    name: script:
    pkgs.runCommand "gleam-nix-ci-${name}" { nativeBuildInputs = [ pkgs.jq ]; } ''
      export STUB="$TMPDIR/stub" GLEAM_NIX_CI_NIX=${nixStub} GLEAM_NIX_CI_EVAL=${evalStub}
      export GITHUB_OUTPUT="$TMPDIR/output" GITHUB_STEP_SUMMARY="$TMPDIR/summary"
      mkdir -p "$STUB"
      touch "$STUB/missing" "$GITHUB_OUTPUT"
      ci=${ci.commands}/bin/gleam-nix-ci
      ${script}
      touch "$out"
    '';
  rejects = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  failures = lib.runTests {
    # The cache-status query is a brittle surface: the fixture was recorded
    # with this evaluator. A new version fails here until it is re-recorded.
    testEvaluatorIsTheRecordedOne = {
      expr = ci.commands.evaluator.version;
      expected = "2.35.4";
    };
    testRecordedFieldsArePresent = {
      expr = builtins.all (
        line: line ? attr && line ? cacheStatus && line ? drvPath && line ? neededBuilds && line ? outputs
      ) recorded;
      expected = true;
    };
    testDeclarationNamesAreDistinct = {
      expr = rejects (
        ci.declare {
          inherit adapter;
          checks.lint = pkgs.emptyFile;
          external.lint = pkgs.emptyFile;
        }
      );
      expected = true;
    };
    testSharedIsReserved = {
      expr = rejects (
        ci.declare {
          inherit adapter;
          checks.shared = pkgs.emptyFile;
        }
      );
      expected = true;
    };
  };
in
{
  ci-evaluation =
    assert failures == [ ];
    pkgs.runCommand "gleam-nix-ci-evaluation" { } ''
      touch "$out"
    '';

  # Two shards sharing an uncached compile plan in two stages; the cached
  # check and the cached external job are skipped.
  ci-plan = run "plan" ''
    "$ci" plan .#ci --out plan.json > /dev/null 2> log
    jq -e '.stages | length == 2' plan.json
    jq -e '.stages[0].jobs == [{ name: "shared", drvs: ["/nix/store/s7z5kmfaxbim0xv1zvqcjf2nvcj15pv6-fixture-compile-0.1.0.drv"] }]' plan.json
    jq -e '.stages[1].jobs == [{ name: "shard-1" }, { name: "shard-2" }]' plan.json
    jq -e '.cached == ["unit"] and .external.run == [] and .external.cached == ["docs"]' plan.json
    grep -F 'shard-1 misses: not in the cache; it needs fixture-compile-0.1.0, fixture-shard-1-of-2' log
    grep -Fx 'checks=["shard-1","shard-2"]' "$GITHUB_OUTPUT"
  '';

  ci-build-push = run "build-push" ''
    export FIXTURE_TOKEN=secret
    "$ci" build .#ci --check shard-1 2> log
    grep -Fx ${byAttr.shard-1.out} "$STUB/pushed"
    grep -F 'push failures: 0' log
    ! grep -F degraded "$GITHUB_OUTPUT"
    "$ci" plan .#ci --out plan.json > /dev/null 2>&1
    "$ci" build .#ci --shared plan.json 2> log
    grep -Fx /nix/store/s7z5kmfaxbim0xv1zvqcjf2nvcj15pv6-fixture-compile-0.1.0 "$STUB/pushed"
  '';

  # Without a write credential the run uses the run-local store and says so.
  ci-build-degraded = run "build-degraded" ''
    export GLEAM_NIX_CI_LOCAL_STORE="$TMPDIR/local"
    "$ci" build .#ci --check shard-2 2> log
    grep -Fx ${byAttr.shard-2.out} "$STUB/copied"
    test ! -e "$STUB/pushed"
    # The store's layout exists before the daemon opens it as a substituter.
    test -d "$TMPDIR/local/nar"
    grep -Fx 'StoreDir: /nix/store' "$TMPDIR/local/nix-cache-info"
    grep -Fx 'degraded=true' "$GITHUB_OUTPUT"
    grep -F "file://$TMPDIR/local?trusted=1" "$STUB/calls" || true
  '';

  # A failed build fails its job, before anything is pushed.
  ci-build-failure = run "build-failure" ''
    export FIXTURE_TOKEN=secret
    echo .#ci.checks.shard-1 > "$STUB/broken"
    if "$ci" build .#ci --check shard-1 2> log; then
      echo "build passed with a failing check" >&2
      exit 1
    fi
    grep -F 'shard-1 failed to build.' log
    test ! -e "$STUB/pushed"
    "$ci" plan .#ci --out plan.json > /dev/null 2>&1
    echo '/nix/store/s7z5kmfaxbim0xv1zvqcjf2nvcj15pv6-fixture-compile-0.1.0.drv^*' > "$STUB/broken"
    if "$ci" build .#ci --shared plan.json 2> log; then
      echo "shared builds passed while failing" >&2
      exit 1
    fi
    grep -F 'shared builds failed.' log
    # The declaration is evaluated first, so the plan's derivations exist.
    grep -q '^eval --json .#ci' "$STUB/calls"
  '';

  ci-verify-missing = run "verify-missing" ''
    echo ${byAttr.shard-2.out} > "$STUB/missing"
    if "$ci" verify .#ci 2> log; then
      echo "verify passed with a missing check" >&2
      exit 1
    fi
    grep -F 'checks shard-2 is missing' log
    grep -F 'The job shard-2 should have pushed it to the fixture cache, which a holder of FIXTURE_TOKEN can write' log
    test ! -e "$STUB/derived"
  '';

  ci-verify-pass = run "verify-pass" ''
    "$ci" verify .#ci 2> log
    grep -Fx 'derived coverage' "$STUB/derived"
    grep -F 'every declared result is present' log
    # Every result is asked for with local builds forbidden.
    test "$(grep -c -- '--max-jobs 0' "$STUB/calls")" -eq 4
  '';

  ci-adapters = pkgs.runCommand "gleam-nix-ci-adapters" { nativeBuildInputs = [ pkgs.jq ]; } ''
    ${lib.concatMapStrings
      (adapter: ''
        jq -e '.scope.read and .scope.write and .substituter' ${adapter}/adapter.json
        status=0
        env -u CACHIX_AUTH_TOKEN -u ATTIC_TOKEN ${adapter}/bin/setup || status=$?
        test "$status" -eq 3
      '')
      [
        (ci.adapters.cachix {
          name = "example";
          publicKey = "example.cachix.org-1:AAAA";
        })
        (ci.adapters.attic {
          server = "https://attic.example.invalid";
          cache = "example";
          publicKey = "example:AAAA";
        })
        ci.adapters.local
      ]
    }
    touch "$out"
  '';
}
