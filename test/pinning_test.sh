#!/usr/bin/env bash
#
# Supply-chain assertions for this repo's workflows.
#
# These are reusable workflows: a consumer calls them as
# latere-ai/ci/.github/workflows/<name>.yml@v1, so every `uses:` here runs
# on that consumer's runner with the permissions declared in this repo
# (contents: write, packages: write) and whatever secrets the caller
# inherits. A `uses:` pinned to a mutable tag re-resolves at run time, so
# whoever controls the upstream repository can repoint it and execute code
# with release and GHCR write access across every consumer.
#
# Two classes of mutable reference are checked:
#   1. `uses: owner/repo@vN` -- pin to a full 40-hex commit SHA instead.
#   2. a SHA-pinned action fetching a tool build at `latest` -- pin the
#      tool version too, or the second-order path stays open.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS="$REPO_ROOT/.github/workflows"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# Every third-party `uses:` must name a 40-hex commit. Local (./...) and
# reusable-workflow refs are not action references and are excluded.
assert_all_actions_sha_pinned() {
    local name="every 'uses:' is pinned to a full commit SHA"
    local refs unpinned
    # Anchored so the `uses:` lines inside each workflow's header comment
    # (which document how a consumer calls it, at @v1) are not scanned.
    refs=$(grep -rhoE '^ *-? *uses: +[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+@[^ ]+' "$WORKFLOWS" \
        | sed -E 's/^ *-? *uses: +//' | sort -u)
    if [ -z "$refs" ]; then
        fail "$name (no action references found at all)"
        return
    fi
    unpinned=$(printf '%s\n' "$refs" | grep -vE '@[0-9a-f]{40}$' || true)
    if [ -z "$unpinned" ]; then
        pass "$name ($(printf '%s\n' "$refs" | wc -l | tr -d ' ') refs)"
    else
        fail "$name"
        printf '    mutable: %s\n' $unpinned
    fi
}

# A SHA-pinned action can still fetch a mutable tool build at run time.
assert_no_latest_tool_versions() {
    local name="no action fetches a tool build at 'latest'"
    local hits
    hits=$(grep -rnE '^ *(bun-|go|goreleaser-)?version: +.?latest' "$WORKFLOWS" || true)
    if [ -z "$hits" ]; then
        pass "$name"
    else
        fail "$name"
        printf '%s\n' "$hits"
    fi
}

# A bare SHA is unreadable. Each pin carries a trailing `# vX.Y.Z` so a
# reviewer can tell at a glance what version is running.
assert_pins_are_annotated() {
    local name="every SHA pin carries a '# vX' version comment"
    local bare
    bare=$(grep -rnE '^ *-? *uses: +[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+@[0-9a-f]{40} *$' "$WORKFLOWS" || true)
    if [ -z "$bare" ]; then
        pass "$name"
    else
        fail "$name"
        printf '%s\n' "$bare"
    fi
}

# Pins go stale silently without an updater watching them.
assert_dependabot_watches_actions() {
    local name="dependabot keeps the action pins current"
    local cfg="$REPO_ROOT/.github/dependabot.yml"
    if [ -f "$cfg" ] && grep -q 'github-actions' "$cfg"; then
        pass "$name"
    else
        fail "$name (no .github/dependabot.yml with a github-actions ecosystem)"
    fi
}

assert_all_actions_sha_pinned
assert_no_latest_tool_versions
assert_pins_are_annotated
assert_dependabot_watches_actions

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
