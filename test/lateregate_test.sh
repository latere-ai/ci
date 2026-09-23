#!/usr/bin/env bash
#
# Unit tests for lateregate.yml's plan step and fold step.
#
# The plan step turns `lateregate list -json` into three outputs: the gates
# that get jobs of their own, the gates that fold into one job on a
# self-hosted runner, and the systems the plain test matrix runs on. The fold
# step runs the folded gates one after another. A step that dropped a gate
# would skip it silently, which is the vacuous pass the whole design refuses,
# so both directions are tested against canned plans, for a lateregate with
# the suite gate and for one that predates it.
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
# The shell under test is the workflow's own: each step's `run: |` block is
# cut out of lateregate.yml and run against a stub `go`, so nothing here can
# drift from what the workflow ships.
# ---------------------------------------------------------------------------
step_script() {
    awk -v name="$1" '
        index($0, "- name: " name) && substr($0, length($0) - length(name) + 1) == name { instep = 1; next }
        instep && /^ +run: \|$/ { match($0, /^ +/); ind = RLENGTH; inrun = 1; next }
        inrun {
            if ($0 ~ /^[[:space:]]*$/) { print ""; next }
            match($0, /^ +/)
            if (RLENGTH <= ind) exit
            print substr($0, ind + 3)
        }
    ' "$WORKFLOW"
}

PLAN_SCRIPT=$(step_script "Read the plan")
LOOP_SCRIPT=$(step_script "Run the gates")
STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT

# The stub go answers `go tool lateregate list -json` with $PLAN, records
# every other gate it is asked to run with the TMPDIR it saw, and fails the
# gates named in $FAIL.
cat > "$STUB/go" <<'EOF'
#!/usr/bin/env bash
shift 2
if [ "$1" = list ]; then printf '%s\n' "$PLAN"; exit 0; fi
echo "$1 TMPDIR=${TMPDIR:-}" >> "$CALLS"
case " $FAIL " in *" $1 "*) exit 1 ;; esac
exit 0
EOF
chmod +x "$STUB/go"

plan_outputs() { # plan hosted runs_on test_os
    out=$(mktemp)
    PLAN="$1" HOSTED="$2" RUNS_ON="$3" TEST_OS="$4" GITHUB_OUTPUT="$out" PATH="$STUB:$PATH" \
        bash -c "set -euo pipefail; plan=\$(go tool lateregate list -json); $PLAN_SCRIPT" >/dev/null
    cat "$out"; rm -f "$out"
}

run_case() {
    name="$1"; plan="$2"; hosted="$3"; runs_on="$4"; test_os="$5"; want_gates="$6"; want_fold="$7"; want_tests="$8"
    got=$(plan_outputs "$plan" "$hosted" "$runs_on" "$test_os")
    got_gates=$(printf '%s\n' "$got" | sed -n 's/^gates=//p')
    got_fold=$(printf '%s\n' "$got" | sed -n 's/^fold=//p')
    got_tests=$(printf '%s\n' "$got" | sed -n 's/^tests=//p')
    if [ "$got_gates" = "$want_gates" ] && [ "$got_fold" = "$want_fold" ] && [ "$got_tests" = "$want_tests" ]; then
        pass "$name"
    else
        fail "$name: gates=$got_gates fold=$got_fold tests=$got_tests, want gates=$want_gates fold=$want_fold tests=$want_tests"
    fi
}

UB='["ubuntu-latest"]'
VM='["linux-vm"]'
echo "plan step, hosted runner"

run_case "every running gate but test is a matrix entry, in plan order" \
    '[{"name":"fmt-check","status":"run"},{"name":"test","status":"run"},{"name":"cover","status":"run"}]' \
    true ubuntu-latest "$UB" '["fmt-check","cover"]' '[]' "$UB"

run_case "a skipped gate is not a job" \
    '[{"name":"fmt-check","status":"run"},{"name":"spec-lint","status":"skip","reason":"tracks no specs/ files"}]' \
    true ubuntu-latest "$UB" '["fmt-check"]' '[]' '[]'

run_case "a waived gate is not a job" \
    '[{"name":"test","status":"run"},{"name":"cover","status":"waived","reason":"later","until":"2026-12-01"}]' \
    true ubuntu-latest "$UB" '[]' '[]' "$UB"

run_case "a waived test skips the OS matrix" \
    '[{"name":"test","status":"waived","reason":"r","until":"2026-12-01"},{"name":"race","status":"run"}]' \
    true ubuntu-latest "$UB" '["race"]' '[]' '[]'

run_case "an expired waiver runs; the plan carries the note, not the skip" \
    '[{"name":"cover","status":"run","reason":"waiver expired 2026-01-01: later","until":"2026-01-01"}]' \
    true ubuntu-latest "$UB" '["cover"]' '[]' '[]'

run_case "both enum gates survive matrix selection" \
    '[{"name":"enum-go","status":"run"},{"name":"test","status":"run"},{"name":"enum-typescript","status":"run"}]' \
    true ubuntu-latest "$UB" '["enum-go","enum-typescript"]' '[]' "$UB"

run_case "a waived TypeScript enum gate does not install frontend tools" \
    '[{"name":"enum-go","status":"run"},{"name":"enum-typescript","status":"waived","reason":"migration","until":"2026-12-01"}]' \
    true ubuntu-latest "$UB" '["enum-go"]' '[]' '[]'

run_case "suite is a gate job on runs_on, and the matrix keeps the other systems" \
    '[{"name":"fmt-check","status":"run"},{"name":"test","status":"folded","into":"suite"},{"name":"race","status":"folded","into":"suite"},{"name":"suite","status":"run"}]' \
    true ubuntu-latest '["ubuntu-latest","macos-latest"]' '["fmt-check","suite"]' '[]' '["macos-latest"]'

run_case "folded gates are never jobs, and a lone runs_on leaves no test matrix" \
    '[{"name":"test","status":"folded","into":"suite"},{"name":"cover","status":"folded","into":"suite"},{"name":"suite","status":"run"}]' \
    true ubuntu-latest "$UB" '["suite"]' '[]' '[]'

run_case "a waived suite runs no test anywhere" \
    '[{"name":"test","status":"folded","into":"suite"},{"name":"suite","status":"waived","reason":"r","until":"2026-12-01"}]' \
    true ubuntu-latest "$UB" '[]' '[]' '[]'

echo "plan step, self-hosted runner"

run_case "the suite gates keep jobs; the rest fold into one" \
    '[{"name":"fmt-check","status":"run"},{"name":"lint","status":"run"},{"name":"test","status":"folded","into":"suite"},{"name":"suite","status":"run"},{"name":"vuln","status":"run"}]' \
    false linux-vm "$VM" '["suite"]' '["fmt-check","lint","vuln"]' '[]'

run_case "a lateregate without suite keeps each suite gate as a job" \
    '[{"name":"fmt-check","status":"run"},{"name":"test","status":"run"},{"name":"race","status":"run"},{"name":"cover","status":"run"},{"name":"tempdir","status":"run"},{"name":"hermetic","status":"run"},{"name":"license","status":"run"}]' \
    false linux-vm "$VM" '["race","cover","tempdir","hermetic"]' '["fmt-check","license"]' "$VM"

run_case "a macOS leg beside the runner still runs plain test" \
    '[{"name":"test","status":"folded","into":"suite"},{"name":"suite","status":"run"},{"name":"modernize","status":"run"}]' \
    false linux-vm '["linux-vm","macos-latest"]' '["suite"]' '["modernize"]' '["macos-latest"]'

run_case "nothing to fold still leaves an empty list, not a missing one" \
    '[{"name":"test","status":"folded","into":"suite"},{"name":"suite","status":"run"}]' \
    false linux-vm "$VM" '["suite"]' '[]' '[]'

echo "fold step"

fold_case() {
    name="$1"; gates="$2"; fail_gates="$3"; want_calls="$4"; want_status="$5"; want_errors="$6"
    calls=$(mktemp)
    out=$(GATES="$gates" FAIL="$fail_gates" CALLS="$calls" RUNNER_TEMP=/runner/temp TMPDIR=/tmp PATH="$STUB:$PATH" \
        bash -c "set -uo pipefail; $LOOP_SCRIPT" 2>&1)
    status=$?
    got_calls=$(tr '\n' ';' < "$calls"); rm -f "$calls"
    got_errors=$(printf '%s\n' "$out" | sed -n 's/^::error title=\([^:]*\)::.*/\1/p' | tr '\n' ' ')
    if [ "$got_calls" = "$want_calls" ] && [ "$status" -eq "$want_status" ] && [ "$got_errors" = "$want_errors" ]; then
        pass "$name"
    else
        fail "$name: calls=$got_calls status=$status errors=[$got_errors], want calls=$want_calls status=$want_status errors=[$want_errors]"
    fi
}

fold_case "every gate runs, then the wiring check, and a clean run passes" \
    '["fmt-check","license"]' "" \
    "fmt-check TMPDIR=/tmp;license TMPDIR=/tmp;contract TMPDIR=/tmp;" 0 ""

fold_case "lint alone runs under the runner process's own TMPDIR" \
    '["lint","vuln"]' "" \
    "lint TMPDIR=/runner/temp;vuln TMPDIR=/tmp;contract TMPDIR=/tmp;" 0 ""

fold_case "a failed gate does not stop the rest, and each failure is annotated" \
    '["fmt-check","lint","license"]' "fmt-check license" \
    "fmt-check TMPDIR=/tmp;lint TMPDIR=/runner/temp;license TMPDIR=/tmp;contract TMPDIR=/tmp;" 1 "fmt-check license "

fold_case "the wiring check runs with no gate to fold and fails the job on its own" \
    '[]' "contract" \
    "contract TMPDIR=/tmp;" 1 "contract "

# ---------------------------------------------------------------------------
# The workflow wires the outputs the steps write.
# ---------------------------------------------------------------------------
echo "workflow"

for expr in \
    'gate: ${{ fromJSON(needs.probe.outputs.gates) }}' \
    'os: ${{ fromJSON(needs.probe.outputs.tests) }}' \
    'GATES: ${{ needs.probe.outputs.fold }}' \
    "needs.probe.outputs.tests != '[]'" \
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

if [ -n "$PLAN_SCRIPT" ] && [ -n "$LOOP_SCRIPT" ]; then
    pass "both steps under test were found in the workflow"
else
    fail "a step under test was not found in the workflow (plan=${#PLAN_SCRIPT} loop=${#LOOP_SCRIPT})"
fi

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
if [ "$fixed" -eq 0 ] && [ "$routed" -eq 4 ]; then
    pass "probe, gate, fold and contract run on inputs.runs_on"
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
# an adjacent step would still install Node/Bun for every Go gate. Both jobs
# that can run the TypeScript enum gate set it up, each on its own condition.
job_block() {
    awk -v job="$1" '
        $0 == "  " job ":" { injob = 1; next }
        injob && /^  [[:alnum:]_-]+:/ { exit }
        injob { print }
    ' "$WORKFLOW"
}

job_step() {
    printf '%s\n' "$1" | awk -v needle="$2" '
        function emit() { if (index(step, needle)) printf "%s", step }
        /^      - / { emit(); step = "" }
        { step = step $0 "\n" }
        END { emit() }
    '
}

check_enum_setup() { # job condition run-step
    block=$(job_block "$1")
    for target in 'uses: actions/setup-node@' 'uses: oven-sh/setup-bun@' 'run: go tool lateregate enum-typescript-prepare'; do
        if job_step "$block" "$target" | grep -qxF "        if: \${{ $2 }}"; then
            pass "$1: $target runs only for the TypeScript enum gate"
        else
            fail "$1: $target must be conditional on $2"
        fi
    done
    if job_step "$block" 'uses: actions/setup-node@' | grep -qxF '          node-version: "24"'; then
        pass "$1: the TypeScript enum gate has Node 24"
    else
        fail "$1: the TypeScript enum gate must set up Node 24"
    fi
    if job_step "$block" 'uses: oven-sh/setup-bun@' | grep -qxF '          bun-version: "1.3.14"'; then
        pass "$1: the TypeScript enum gate pins Bun"
    else
        fail "$1: the TypeScript enum gate must pin Bun 1.3.14"
    fi
    if printf '%s\n' "$block" | awk -v check="$3" '
        /uses: actions\/setup-node@/ { node = NR }
        /uses: oven-sh\/setup-bun@/ { bun = NR }
        /run: go tool lateregate enum-typescript-prepare$/ { prepare = NR }
        index($0, check) { run = NR }
        END { exit !(node && bun && prepare && run && node < prepare && bun < prepare && prepare < run) }
    '; then
        pass "$1: both runtimes are set up before frozen preparation and gate checking"
    else
        fail "$1: enum checking must follow both runtime setups and frozen preparation"
    fi
}

for target in 'uses: actions/setup-node@' 'uses: oven-sh/setup-bun@' 'run: go tool lateregate enum-typescript-prepare'; do
    count=$(grep -cF "$target" "$WORKFLOW")
    if [ "$count" -eq 2 ]; then
        pass "$target appears in the gate job and the fold job, nowhere else"
    else
        fail "$target appears $count times, want 2"
    fi
done
check_enum_setup gate "matrix.gate == 'enum-typescript'" 'run: go tool lateregate ${{ matrix.gate }}'
check_enum_setup fold "contains(fromJSON(needs.probe.outputs.fold), 'enum-typescript')" '- name: Run the gates'

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
