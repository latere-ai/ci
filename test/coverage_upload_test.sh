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

# Every step that holds the marker, each followed by a line holding only "--".
steps_for() {
    awk -v marker="$2" '
        /^      - / { if (found) print "--"; found = index($0, marker) > 0 }
        /^  [[:alnum:]_-]+:$/ { if (found) print "--"; found = 0 }
        found { print }
        END { if (found) print "--" }
    ' "$1"
}

for name in go-verify lateregate; do
    workflow="$REPO_ROOT/.github/workflows/$name.yml"
    uploads=$(steps_for "$workflow" 'uses: actions/upload-artifact@')
    total=$(printf '%s\n' "$uploads" | grep -c 'uses: actions/upload-artifact@' || true)
    optional=$(printf '%s\n' "$uploads" | grep -c 'continue-on-error: true' || true)
    if [ "$total" -eq 0 ] || [ "$optional" -ne "$total" ]; then
        echo "FAIL: $name makes coverage depend on artifact storage quota ($optional of $total uploads optional)"
        FAILURES=$((FAILURES + 1))
    fi
    if [ "$name" = go-verify ]; then
        commands='run: make cover'
    else
        # A hosted runner runs cover or suite in a gate job of its own; the
        # self-hosted runner runs it in the all gates passed job's loop.
        commands='run: go tool lateregate ${{ matrix.gate }}
- name: Run the gates'
    fi
    while IFS= read -r command; do
        gate=$(step_for "$workflow" "$command")
        if [ -z "$gate" ] || printf '%s\n' "$gate" | grep -q 'continue-on-error: true' \
            || grep -q '^    continue-on-error: true' "$workflow"; then
            echo "FAIL: $name no longer fails on a broken coverage gate ($command)"
            FAILURES=$((FAILURES + 1))
        fi
    done <<< "$commands"
done

# lateregate keeps a copy wherever coverage runs: the gate job on a hosted
# runner and the all gates passed job on the self-hosted one.
uploads=$(grep -c 'uses: actions/upload-artifact@' "$REPO_ROOT/.github/workflows/lateregate.yml" || true)
if [ "$uploads" -ne 2 ]; then
    echo "FAIL: lateregate has $uploads coverage uploads, want one in the gate job and one in the passed job"
    FAILURES=$((FAILURES + 1))
fi

if [ "$FAILURES" -ne 0 ]; then exit 1; fi
echo 'PASS: coverage failures block CI; artifact storage failures do not'
