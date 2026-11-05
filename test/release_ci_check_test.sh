#!/usr/bin/env bash
#
# Grep assertions that every release pipeline here refuses a tag whose commit
# did not pass CI: service-release.yml and notes-release.yml run the shared
# verified-commit step before anything is built or published, pass it the
# caller's verify_workflow, wait_minutes and skip_paths, and may read the
# per-push runs; the examples and this repository's own release grant that
# read. image-build.yml and cli-release.yml are checked in their own suites.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# Line of the first match of fixed string $2 in file $1, or 0.
line_of() {
    local n
    n=$(grep -nF -- "$2" "$1" | head -1 | cut -d: -f1)
    echo "${n:-0}"
}

check() {
    local name=$1 first=$2 wf="$REPO_ROOT/.github/workflows/$1"
    local check_at first_at
    printf "\033[1m%s\033[0m\n" "$name"

    check_at=$(line_of "$wf" 'uses: ./.latere-ci/actions/verified-commit')
    first_at=$(line_of "$wf" "$first")
    if [ "$check_at" -eq 0 ]; then
        fail "$name does not run verified-commit"
    elif [ "$first_at" -eq 0 ]; then
        fail "$name has no '$first' step to order the check against"
    elif [ "$check_at" -lt "$first_at" ]; then
        pass "verified-commit runs before '$first'"
    else
        fail "verified-commit runs after '$first' (line $check_at, not before $first_at)"
    fi

    # The step passes the caller's inputs through, so a repository can name
    # its gate, its wait and its skipped paths.
    local step
    step=$(sed -n "${check_at},$((check_at + 6))p" "$wf")
    for input in verify_workflow wait_minutes skip_paths gh_version; do
        if printf '%s\n' "$step" | grep -qF "$input: \${{ inputs.$input }}"; then
            pass "the check takes inputs.$input"
        else
            fail "the check does not pass inputs.$input"
        fi
        if grep -qE "^      $input:$" "$wf"; then
            pass "$input is an input"
        else
            fail "$input is not declared as an input"
        fi
    done

    local perms
    perms=$(sed -n '/^permissions:/,/^jobs:/p' "$wf")
    if printf '%s\n' "$perms" | grep -qx '  actions: read'; then
        pass "the workflow may read the per-push runs"
    else
        fail "actions: read is missing from the workflow permissions"
    fi
}

# service-release: the check comes before the tool versions, the first step
# that does work, so a refused tag holds the runner for seconds.
check service-release.yml 'name: Tool versions'
# notes-release: before the release is created.
check notes-release.yml 'uses: ./.latere-ci/actions/publish-release'

printf "\033[1mcallers\033[0m\n"
for f in examples/notes-release.yml examples/service-release.yml examples/service-release-dockerfile.yml .github/workflows/release.yml; do
    if sed -n '/^permissions:/,/^jobs:/p' "$REPO_ROOT/$f" | grep -qx '  actions: read'; then
        pass "$f grants actions: read"
    else
        fail "$f does not grant actions: read, so the release fails at startup"
    fi
done

# This repository's lateregate.yml is the reusable gate, which the empty
# verify_workflow would find by its own example, so the release names the
# per-push suite.
if grep -qE '^      verify_workflow: test\.yml$' "$REPO_ROOT/.github/workflows/release.yml"; then
    pass "this repository's release reads test.yml"
else
    fail "this repository's release does not name test.yml as its per-push gate"
fi

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d check(s) failed\n" "$FAILURES"
    exit 1
fi
