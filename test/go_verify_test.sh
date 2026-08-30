#!/usr/bin/env bash
#
# Unit tests for go-verify.yml's target probe.
#
# The probe is the whole of the consumer contract: three required targets
# whose absence must fail by name, and six optional ones whose absence must
# skip a job rather than fail one. Both directions matter. A probe that is too
# strict blocks the fifteen repos that have only the required three; a probe
# that is too lax lets a repo believe it has a coverage gate it never runs.
#
# The workflow's shell cannot run here, so a copy of it is tested and a grep
# assertion checks the copy still matches what the workflow ships.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/go-verify.yml"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# The copy under test. Keep in step with the "Probe the Makefile" step.
# ---------------------------------------------------------------------------
probe() {
    if [ ! -f Makefile ]; then
        echo "::error::go-verify needs a Makefile: it runs the repo's own targets rather than guessing commands."
        return 1
    fi
    has() { make -n "$1" >/dev/null 2>&1; }

    missing=""
    for t in fmt-check test lint-modernize; do
        has "$t" || missing="$missing $t"
    done
    if [ -n "$missing" ]; then
        echo "::error::Makefile has no required target(s):$missing. See ci/README.md for the go-verify contract."
        return 1
    fi

    emit() {
        if has "$2"; then
            echo "$1=true"  >> "$GITHUB_OUTPUT"; echo "found $2"
        else
            echo "$1=false" >> "$GITHUB_OUTPUT"; echo "skipping $2 (no such target)"
        fi
    }
    emit hermetic  test-hermetic
    emit race      test-race
    emit cover     cover
    emit spec_lint spec-lint
    emit dist      dist
    emit validate  validate
    emit lint_config lint-config
    emit license   license
}

# run_probe <makefile-body> -- runs the probe in a scratch repo and leaves its
# stdout in $OUT, its GITHUB_OUTPUT in $OUTPUTS and its status in $STATUS.
run_probe() {
    local dir
    dir="$(mktemp -d)"
    if [ -n "$1" ]; then printf '%s\n' "$1" > "$dir/Makefile"; fi
    OUTPUTS="$dir/github_output"
    : > "$OUTPUTS"
    OUT="$(cd "$dir" && GITHUB_OUTPUT="$OUTPUTS" probe 2>&1)"
    STATUS=$?
    OUTPUTS="$(cat "$OUTPUTS")"
    rm -rf "$dir"
}

# A repo with the three required targets and nothing else. Fifteen of the
# twenty-one Go repos are in exactly this shape, so it has to be the easy case.
required_only=$'fmt-check:\n\t@true\ntest:\n\t@true\nlint-modernize:\n\t@true'

test_required_only_passes() {
    local name="a repo with only the required targets passes"
    run_probe "$required_only"
    if [ "$STATUS" -ne 0 ]; then fail "$name (status $STATUS: $OUT)"; return; fi
    case "$OUTPUTS" in
        *"cover=false"*) pass "$name" ;;
        *) fail "$name (outputs: $OUTPUTS)" ;;
    esac
}

test_optional_targets_are_skipped_not_failed() {
    local name="every optional target absent skips rather than fails"
    run_probe "$required_only"
    local missing="" k
    for k in hermetic=false race=false cover=false spec_lint=false dist=false validate=false lint_config=false license=false; do
        case "$OUTPUTS" in *"$k"*) ;; *) missing="$missing $k" ;; esac
    done
    if [ -n "$missing" ]; then fail "$name (never emitted:$missing)"; else pass "$name"; fi
}

test_optional_targets_are_found() {
    local name="an optional target that exists is reported true"
    run_probe "$required_only"$'\ntest-hermetic:\n\t@true\ncover:\n\t@true\nspec-lint:\n\t@true\nlicense:\n\t@true'
    local wrong="" k
    for k in hermetic=true cover=true spec_lint=true license=true race=false dist=false; do
        case "$OUTPUTS" in *"$k"*) ;; *) wrong="$wrong $k" ;; esac
    done
    if [ -n "$wrong" ]; then fail "$name (expected:$wrong; got: $OUTPUTS)"; else pass "$name"; fi
}

test_a_missing_required_target_fails_by_name() {
    local name="a missing required target fails and names it"
    run_probe $'fmt-check:\n\t@true\ntest:\n\t@true'
    if [ "$STATUS" -eq 0 ]; then fail "$name (probe passed)"; return; fi
    case "$OUT" in
        *"no required target(s): lint-modernize"*) pass "$name" ;;
        *) fail "$name (message was: $OUT)" ;;
    esac
}

test_several_missing_required_targets_are_all_named() {
    local name="every missing required target is named, not just the first"
    run_probe $'build:\n\t@true'
    case "$OUT" in
        *"fmt-check"*) ;;
        *) fail "$name (fmt-check not named: $OUT)"; return ;;
    esac
    case "$OUT" in
        *"lint-modernize"*) pass "$name" ;;
        *) fail "$name (lint-modernize not named: $OUT)" ;;
    esac
}

test_no_makefile_fails_clearly() {
    local name="a repo with no Makefile fails with a reason"
    run_probe ""
    if [ "$STATUS" -eq 0 ]; then fail "$name (probe passed)"; return; fi
    case "$OUT" in
        *"needs a Makefile"*) pass "$name" ;;
        *) fail "$name (message was: $OUT)" ;;
    esac
}

# make -n resolves a target without running it. A probe that ran the targets
# would run the whole suite six times before the first job started.
test_the_probe_does_not_run_the_targets() {
    local name="probing does not execute the targets"
    local dir; dir="$(mktemp -d)"
    printf 'fmt-check:\n\t@touch %s/ran\ntest:\n\t@true\nlint-modernize:\n\t@true\n' "$dir" > "$dir/Makefile"
    ( cd "$dir" && GITHUB_OUTPUT="$dir/out" probe >/dev/null 2>&1 )
    if [ -f "$dir/ran" ]; then fail "$name (the target executed)"; else pass "$name"; fi
    rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# The copy above must still be the shell the workflow ships.
# ---------------------------------------------------------------------------
test_the_workflow_matches_this_copy() {
    local name="go-verify.yml still ships the shell tested here"
    local line missing=""
    while IFS= read -r line; do
        grep -qF "$line" "$WORKFLOW" || missing="$missing|$line"
    done <<'EOF'
for t in fmt-check test lint-modernize; do
emit hermetic  test-hermetic
emit spec_lint spec-lint
emit validate  validate
emit license   license
has() { make -n "$1" >/dev/null 2>&1; }
EOF
    if [ -n "$missing" ]; then fail "$name (workflow lacks:$missing)"; else pass "$name"; fi
}

test_every_optional_job_is_gated_on_the_probe() {
    local name="every optional job is gated on its probe output"
    local k missing=""
    for k in hermetic race cover spec_lint dist validate lint_config license; do
        grep -qF "needs.probe.outputs.$k == 'true'" "$WORKFLOW" || missing="$missing $k"
    done
    if [ -n "$missing" ]; then fail "$name (ungated:$missing)"; else pass "$name"; fi
}

# The OS matrix is the point of the test job: development happens on macOS and
# deployment on Linux, and a repo that only tests one finds out late.
# The config is generated and gitignored, so it must exist before the linter
# runs: with no config golangci-lint falls back to its own default linters.
test_lint_config_runs_before_the_linter() {
    local name="lint-config runs before golangci-lint"
    local gen act
    gen=$(grep -n "run: make lint-config" "$WORKFLOW" | head -1 | cut -d: -f1)
    act=$(grep -n "uses: golangci/golangci-lint-action" "$WORKFLOW" | head -1 | cut -d: -f1)
    if [ -z "$gen" ] || [ -z "$act" ]; then
        fail "$name (step not found: gen=$gen act=$act)"
    elif [ "$gen" -lt "$act" ]; then
        pass "$name"
    else
        fail "$name (generated at line $gen, linter at $act)"
    fi
}

test_the_matrix_covers_both_operating_systems() {
    local name="the default test matrix is ubuntu and macos"
    if grep -qF '["ubuntu-latest", "macos-latest"]' "$WORKFLOW"; then
        pass "$name"
    else
        fail "$name"
    fi
}

printf "\033[1mgo-verify probe\033[0m\n"
test_required_only_passes
test_optional_targets_are_skipped_not_failed
test_optional_targets_are_found
test_a_missing_required_target_fails_by_name
test_several_missing_required_targets_are_all_named
test_no_makefile_fails_clearly
test_the_probe_does_not_run_the_targets
test_the_workflow_matches_this_copy
test_every_optional_job_is_gated_on_the_probe
test_lint_config_runs_before_the_linter
test_the_matrix_covers_both_operating_systems

if [ "$FAILURES" -gt 0 ]; then
    printf "\033[31m%d check(s) failed\033[0m\n" "$FAILURES"
    exit 1
fi
