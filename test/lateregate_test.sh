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

run_case "both enum gates survive matrix selection" \
    '[{"name":"enum-go","status":"run"},{"name":"test","status":"run"},{"name":"enum-typescript","status":"run"}]' \
    '["enum-go","enum-typescript"]' 'true'

run_case "a waived TypeScript enum gate does not install frontend tools" \
    '[{"name":"enum-go","status":"run"},{"name":"enum-typescript","status":"waived","reason":"migration","until":"2026-12-01"}]' \
    '["enum-go"]' 'false'

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

# Every job except the test matrix runs where runs_on says, so a repository
# that adopts the self-hosted runner moves the whole pipeline with one input.
# A bare ubuntu-latest on a job would pin that job to hosted runners.
fixed=$(grep -cE '^\s+runs-on: ubuntu-latest$' "$WORKFLOW")
routed=$(grep -cF 'runs-on: ${{ inputs.runs_on }}' "$WORKFLOW")
if [ "$fixed" -eq 0 ] && [ "$routed" -eq 3 ]; then
    pass "probe, gate and contract run on inputs.runs_on"
else
    fail "runs_on does not route every non-matrix job (fixed=$fixed routed=$routed)"
fi

# setup-go's cache restore is for hosted runners, which start empty. On the
# self-hosted machine the module cache is already there and the restore
# fails file by file, so every setup-go step gates it on a hosted label.
setups=$(grep -c 'uses: actions/setup-go' "$WORKFLOW")
gated=$(grep -cE "cache: \\$\\{\\{ startsWith\\((inputs.runs_on|matrix.os), 'ubuntu-'\\)" "$WORKFLOW")
if [ "$setups" -eq "$gated" ]; then
    pass "every setup-go caches only on a hosted runner"
else
    fail "setup-go steps without a hosted-only cache gate (setups=$setups gated=$gated)"
fi

# Check the actual step blocks, not independent occurrences: a condition on
# an adjacent step would still install Node/Bun for every Go gate.
gate_job=$(awk '
    /^  gate:$/ { gate = 1; next }
    gate && /^  [[:alnum:]_-]+:/ { exit }
    gate { print }
' "$WORKFLOW")

gate_step() {
    printf '%s\n' "$gate_job" | awk -v needle="$1" '
        function emit() { if (index(step, needle)) printf "%s", step }
        /^      - / { emit(); step = "" }
        { step = step $0 "\n" }
        END { emit() }
    '
}

for target in 'uses: actions/setup-node@' 'uses: oven-sh/setup-bun@' 'run: go tool lateregate enum-typescript-prepare'; do
    block=$(gate_step "$target")
    count=$(grep -cF "$target" "$WORKFLOW")
    if [ "$count" -eq 1 ] && printf '%s\n' "$block" | grep -qxF "        if: \${{ matrix.gate == 'enum-typescript' }}"; then
        pass "$target runs only for the TypeScript enum gate"
    else
        fail "$target must appear once, in the gate job, conditional on enum-typescript"
    fi
done

if gate_step 'uses: actions/setup-node@' | grep -qxF '          node-version: "24"'; then
    pass "the TypeScript enum gate has Node 24"
else
    fail "the TypeScript enum gate must set up Node 24"
fi

if gate_step 'uses: oven-sh/setup-bun@' | grep -qxF '          bun-version: "1.3.14"'; then
    pass "the TypeScript enum gate pins Bun"
else
    fail "the TypeScript enum gate must pin Bun 1.3.14"
fi

if printf '%s\n' "$gate_job" | awk '
    /uses: actions\/setup-node@/ { node = NR }
    /uses: oven-sh\/setup-bun@/ { bun = NR }
    /run: go tool lateregate enum-typescript-prepare$/ { prepare = NR }
    /run: go tool lateregate \$\{\{ matrix.gate \}\}$/ { check = NR }
    END { exit !(node && bun && prepare && check && node < prepare && bun < prepare && prepare < check) }
'; then
    pass "both runtimes are set up before frozen preparation and gate checking"
else
    fail "enum checking must follow both runtime setups and frozen preparation"
fi

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
