#!/usr/bin/env bash
#
# Structural checks over the composite actions under actions/: each is a
# composite action, each `run:` step names its shell (a composite step has
# no default), each script a step runs exists and passes shellcheck, and no
# action calls another through `uses:`, which would resolve the other at a
# ref of its own rather than beside this one. An action shares a script
# through $GITHUB_ACTION_PATH/../<other>/run.sh instead.
#
# Kept bash 3.2 compatible.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

for action in "$REPO_ROOT"/actions/*/action.yml; do
    dir=$(dirname "$action")
    name=$(basename "$dir")
    if grep -qE '^  using: composite$' "$action"; then
        pass "$name is a composite action"
    else
        fail "$name is a composite action"
    fi
    runs=$(grep -cE '^ +(- )?run: ' "$action")
    shells=$(grep -cE '^ +(- )?shell: bash$' "$action")
    if [ "$runs" -eq "$shells" ]; then
        pass "$name: every run step names bash ($runs)"
    else
        fail "$name: $runs run steps and $shells shell: bash lines"
    fi
    missing=""
    for script in $(grep -oE '\$GITHUB_ACTION_PATH/[A-Za-z0-9_./-]+\.sh' "$action" | sed 's|\$GITHUB_ACTION_PATH/||'); do
        [ -f "$dir/$script" ] || missing="$missing $script"
    done
    if [ -z "$missing" ]; then
        pass "$name: every script it runs exists"
    else
        fail "$name runs scripts that do not exist:$missing"
    fi
    if grep -qE '^ +(- )?uses: +(\./|latere-ai/ci/)' "$action"; then
        fail "$name calls another action of this repository through uses:"
    else
        pass "$name calls no other action of this repository through uses:"
    fi
done

if command -v shellcheck > /dev/null 2>&1; then
    if out=$(shellcheck -x "$REPO_ROOT"/actions/*/*.sh 2>&1); then
        pass "every action script passes shellcheck"
    else
        fail "every action script passes shellcheck"
        printf '%s\n' "$out"
    fi
else
    printf "  \033[33mSKIP\033[0m shellcheck is not installed; CI runs it\n"
fi

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
