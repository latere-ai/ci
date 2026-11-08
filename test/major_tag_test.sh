#!/usr/bin/env bash
#
# major-tag.yml moves the v1 tag consumers pin. Two rules, both tested here:
# v1 moves only once CI is verified green on the tagged commit, and only
# forward, to the highest v1.MINOR.PATCH release tag. The move is
# tools/major-tag.sh, run whole against a real origin; the workflow is read
# for the verification that stands ahead of it.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/major-tag.yml"
SCRIPT="$REPO_ROOT/tools/major-tag.sh"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git_in() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }

# new_repo NAME: a bare origin with a clone at $TMP/NAME/work.
new_repo() {
    git init -q --bare "$TMP/$1.git"
    git clone -q "$TMP/$1.git" "$TMP/$1" 2> /dev/null
}
# release DIR TAG: a commit tagged TAG (annotated), pushed with the tag.
# Prints the commit.
release() {
    git_in "$1" commit -q --allow-empty -m "$2"
    git_in "$1" tag -a "$2" -m "$2"
    git_in "$1" push -q origin HEAD:refs/heads/main "refs/tags/$2" 2> /dev/null
    git -C "$1" rev-parse HEAD
}
# at_tag DIR TAG: a commit TAG names, with no new commit made.
tag_commit() { git -C "$1" rev-parse "$2^{}"; }
origin_v1() { git --git-dir="$TMP/$1.git" rev-parse 'refs/tags/v1^{}' 2> /dev/null || echo none; }
# move DIR TAG: runs the script for TAG in DIR.
move() { (cd "$1" && TAG=$2 bash "$SCRIPT" 2>&1); }

new_repo a
c1=$(release "$TMP/a" v1.1.0)
move "$TMP/a" v1.1.0 > /dev/null
if [ "$(origin_v1 a)" = "$c1" ]; then
    pass "the first release tag creates v1 at its commit"
else
    fail "the first release tag creates v1 at its commit"
fi

c2=$(release "$TMP/a" v1.2.0)
move "$TMP/a" v1.2.0 > /dev/null
if [ "$(origin_v1 a)" = "$c2" ]; then
    pass "a higher release tag moves v1 forward"
else
    fail "a higher release tag moves v1 forward"
fi

# A backport: v1.1.1 is cut from the old line after v1.2.0 exists.
git_in "$TMP/a" checkout -q -b backport "$c1"
cb=$(release "$TMP/a" v1.1.1)
out=$(move "$TMP/a" v1.1.1)
if [ "$(origin_v1 a)" = "$c2" ] && printf '%s' "$out" | grep -qF "v1.1.1 is not the highest v1 release (v1.2.0)"; then
    pass "a backport tag does not move v1 backwards"
else
    fail "a backport tag does not move v1 backwards (v1 at $(origin_v1 a), want $c2; output: $out)"
fi
[ "$cb" != "$c2" ] || fail "the backport fixture shares a commit with v1.2.0"

# Versions compare as numbers, not text.
git_in "$TMP/a" checkout -q main
git_in "$TMP/a" checkout -q -b more
release "$TMP/a" v1.9.0 > /dev/null
c10=$(release "$TMP/a" v1.10.0)
move "$TMP/a" v1.10.0 > /dev/null
if [ "$(origin_v1 a)" = "$c10" ]; then
    pass "v1.10.0 is higher than v1.9.0"
else
    fail "v1.10.0 is higher than v1.9.0"
fi
out=$(move "$TMP/a" v1.9.0)
if [ "$(origin_v1 a)" = "$c10" ]; then
    pass "v1.9.0 pushed after v1.10.0 leaves v1 alone"
else
    fail "v1.9.0 pushed after v1.10.0 leaves v1 alone"
fi

# A prerelease neither moves v1 nor counts as the highest release.
cpre=$(release "$TMP/a" v1.11.0-rc1)
out=$(move "$TMP/a" v1.11.0-rc1)
if [ "$(origin_v1 a)" = "$c10" ] && printf '%s' "$out" | grep -qF "prerelease"; then
    pass "a prerelease tag leaves v1 alone"
else
    fail "a prerelease tag leaves v1 alone (output: $out)"
fi
[ -n "$cpre" ] || fail "the prerelease fixture has no commit"
c11=$(release "$TMP/a" v1.10.1)
move "$TMP/a" v1.10.1 > /dev/null
if [ "$(origin_v1 a)" = "$c11" ]; then
    pass "a release after a prerelease of a higher version still moves v1"
else
    fail "a release after a prerelease of a higher version still moves v1"
fi

# An origin that cannot be listed moves nothing.
new_repo b
release "$TMP/b" v1.1.0 > /dev/null
git -C "$TMP/b" remote set-url origin "$TMP/nowhere.git"
if out=$(move "$TMP/b" v1.1.0); then
    fail "an unreadable origin refuses ($out)"
else
    pass "an unreadable origin refuses rather than moving v1"
fi

# The workflow verifies the commit before it moves v1, and only for a
# release tag.
verify_at=$(grep -nF 'uses: ./actions/verified-commit' "$WORKFLOW" | head -1 | cut -d: -f1)
move_at=$(grep -nF 'run: bash tools/major-tag.sh' "$WORKFLOW" | head -1 | cut -d: -f1)
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
