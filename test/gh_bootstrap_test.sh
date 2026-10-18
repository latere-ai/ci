#!/usr/bin/env bash
#
# The self-hosted runner ships docker, git, jq and curl, and no GitHub CLI.
# A job in a reusable workflow that calls gh therefore fetches the pinned
# release first, in the same job; without it the job passes on a hosted
# runner and fails on the self-hosted one, which is where the runner policy
# sends every private repository. notes-release.yml was the job that broke:
# a private repository's release moved to a hosted runner to get gh.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS="$REPO_ROOT/.github/workflows"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

for f in $(grep -l '^  workflow_call:$' "$WORKFLOWS"/*.yml); do
    name=$(basename "$f")
    # The jobs that call gh with no "Ensure gh" step of their own.
    bare=$(awk '
        /^jobs:$/ { injobs = 1; next }
        injobs && /^  [a-z0-9_-]+:$/ { if (calls && !ensures) print job; job = $1; calls = 0; ensures = 0 }
        injobs && /name: Ensure gh$/ { ensures = 1 }
        injobs && /(^|[[:space:];(!])gh (release|api|run|pr|issue|workflow) / { calls = 1 }
        END { if (calls && !ensures) print job }
    ' "$f" | tr -d ':' | tr '\n' ' ')
    if [ -z "$bare" ]; then
        pass "$name fetches gh in every job that calls it"
    else
        fail "$name calls gh without fetching it first in: $bare"
    fi
    # Every fetch is the pinned input version, verified against the
    # release's checksums file.
    if grep -qF 'name: Ensure gh' "$f"; then
        if grep -qF 'GH_VERSION: ${{ inputs.gh_version }}' "$f" \
            && grep -A22 'name: Ensure gh' "$f" | grep -q 'sha256sum -c'; then
            pass "$name fetches gh at inputs.gh_version and verifies it"
        else
            fail "$name fetches gh unpinned or unverified"
        fi
    fi
done

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
