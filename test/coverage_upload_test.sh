#!/usr/bin/env bash
# Coverage is a required gate; storing a copy of its profile is optional.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

step_for() {
    awk -v marker="$2" '
        /^      - / { if (found) exit; found = index($0, marker) > 0 }
        found { print }
    ' "$1"
}

for name in go-verify lateregate; do
    workflow="$REPO_ROOT/.github/workflows/$name.yml"
    upload=$(step_for "$workflow" 'uses: actions/upload-artifact@')
    if ! printf '%s\n' "$upload" | grep -q 'continue-on-error: true'; then
        echo "FAIL: $name makes coverage depend on artifact storage quota"
        FAILURES=$((FAILURES + 1))
    fi
    if [ "$name" = go-verify ]; then
        command='run: make cover'
    else
        command='run: go tool lateregate ${{ matrix.gate }}'
    fi
    gate=$(step_for "$workflow" "$command")
    if [ -z "$gate" ] || printf '%s\n' "$gate" | grep -q 'continue-on-error: true' \
        || grep -q '^    continue-on-error: true' "$workflow"; then
        echo "FAIL: $name no longer fails on a broken coverage gate"
        FAILURES=$((FAILURES + 1))
    fi
done

if [ "$FAILURES" -ne 0 ]; then exit 1; fi
echo 'PASS: coverage failures block CI; artifact storage failures do not'
