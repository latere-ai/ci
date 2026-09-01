#!/usr/bin/env bash
#
# Unit tests for lateregate.yml's plan step.
#
# The step turns `lateregate list -json` into two outputs: the matrix of
# gates that run (minus test, which has its own OS matrix) and whether test
# runs at all. A plan step that dropped a gate would skip its job silently,
# which is the vacuous pass the whole design refuses, so both directions are
# tested here against a canned plan.
#
# The workflow's shell cannot run here, so a copy of it is tested and a grep
# assertion checks the copy still matches what the workflow ships.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/lateregate.yml"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP jq is not installed; the runners have it"
    exit 0
fi

# ---------------------------------------------------------------------------
# The copy under test. Keep in step with the "Read the plan" step.
# ---------------------------------------------------------------------------
plan_outputs() {
    plan="$1"
    gates=$(printf '%s\n' "$plan" | jq -c '[.[] | select(.status == "run" and .name != "test") | .name]')
    test=$(printf '%s\n' "$plan" | jq -r '[.[] | select(.status == "run" and .name == "test")] | length > 0')
    echo "gates=$gates" >> "$GITHUB_OUTPUT"
    echo "test=$test" >> "$GITHUB_OUTPUT"
}

run_case() {
    name="$1"; plan="$2"; want_gates="$3"; want_test="$4"
    GITHUB_OUTPUT=$(mktemp)
    plan_outputs "$plan"
    got_gates=$(sed -n 's/^gates=//p' "$GITHUB_OUTPUT")
    got_test=$(sed -n 's/^test=//p' "$GITHUB_OUTPUT")
    rm -f "$GITHUB_OUTPUT"
    if [ "$got_gates" = "$want_gates" ] && [ "$got_test" = "$want_test" ]; then
        pass "$name"
    else
        fail "$name: gates=$got_gates test=$got_test, want gates=$want_gates test=$want_test"
    fi
}

echo "plan step"

run_case "every running gate but test is a matrix entry, in plan order" \
    '[{"name":"fmt-check","status":"run"},{"name":"test","status":"run"},{"name":"cover","status":"run"}]' \
    '["fmt-check","cover"]' 'true'

run_case "a skipped gate is not a job" \
    '[{"name":"fmt-check","status":"run"},{"name":"spec-lint","status":"skip","reason":"tracks no specs/ files"}]' \
    '["fmt-check"]' 'false'

run_case "a waived gate is not a job" \
    '[{"name":"test","status":"run"},{"name":"cover","status":"waived","reason":"later","until":"2026-12-01"}]' \
    '[]' 'true'

run_case "a waived test skips the OS matrix" \
    '[{"name":"test","status":"waived","reason":"r","until":"2026-12-01"},{"name":"race","status":"run"}]' \
    '["race"]' 'false'

run_case "an expired waiver runs; the plan carries the note, not the skip" \
    '[{"name":"cover","status":"run","reason":"waiver expired 2026-01-01: later","until":"2026-01-01"}]' \
    '["cover"]' 'false'

# ---------------------------------------------------------------------------
# The copy matches the workflow.
# ---------------------------------------------------------------------------
echo "workflow"

for expr in \
    "select(.status == \"run\" and .name != \"test\") | .name" \
    "select(.status == \"run\" and .name == \"test\")] | length > 0" \
    'gate: ${{ fromJSON(needs.probe.outputs.gates) }}' \
    "needs.probe.outputs.test == 'true'" \
    "needs.probe.outputs.gates != '[]'" \
    "go tool lateregate list -json" \
    "go tool lateregate contract" \
    'go tool lateregate ${{ matrix.gate }}' \
    "go tool lateregate test"
do
    if grep -qF -- "$expr" "$WORKFLOW"; then
        pass "workflow carries: $expr"
    else
        fail "workflow lost: $expr"
    fi
done

# Every uses: is SHA-pinned, as in every other workflow here.
if grep -E '^\s*-?\s*uses:' "$WORKFLOW" | grep -vE '@[0-9a-f]{40}' >/dev/null; then
    fail "an action is not pinned to a commit SHA"
else
    pass "every action is pinned to a commit SHA"
fi

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
