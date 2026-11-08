#!/usr/bin/env bash
#
# major-tag.yml moves the v1 tag consumers pin, and only once CI is verified
# green on the tagged commit: the workflow is read for the verification that
# stands ahead of the move.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/major-tag.yml"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# The workflow verifies the commit before it moves v1, and only for a
# release tag.
verify_at=$(grep -nF 'uses: ./actions/verified-commit' "$WORKFLOW" | head -1 | cut -d: -f1)
move_at=$(grep -nF 'git push -f origin refs/tags/v1' "$WORKFLOW" | head -1 | cut -d: -f1)
if [ -n "$verify_at" ] && [ -n "$move_at" ] && [ "$verify_at" -lt "$move_at" ]; then
    pass "major-tag.yml verifies the tagged commit before it moves v1"
else
    fail "major-tag.yml does not verify the tagged commit before it moves v1 (verify=$verify_at move=$move_at)"
fi
if grep -qx '      actions: read' "$WORKFLOW" \
    && sed -n "${verify_at:-1},$((${verify_at:-1} + 3))p" "$WORKFLOW" | grep -qF 'verify_workflow: test.yml'; then
    pass "the check reads test.yml's runs with actions: read"
else
    fail "the check does not read test.yml's runs, or the job lacks actions: read"
fi

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
