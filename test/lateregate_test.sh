#!/usr/bin/env bash
#
# Unit tests for lateregate.yml's plan steps, its gate loop and its result
# check, and grep assertions on the shape of its jobs.
#
# The probe's plan step turns `lateregate list -json` into two outputs: the
# gates that get jobs of their own on a hosted runner, and the systems the
# plain test matrix runs on. On the self-hosted runner the all gates passed
# job lists the running gates itself and runs them one after another. A step
# that dropped a gate would skip it silently, which is the vacuous pass the
# whole design refuses, so both directions are tested against canned plans,
# for a lateregate with the suite gate and for one that predates it.
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

# The expression every job uses to tell a hosted label from a self-hosted one.
HOSTED_EXPR="startsWith(inputs.runs_on, 'ubuntu-') || startsWith(inputs.runs_on, 'macos-') || startsWith(inputs.runs_on, 'windows-')"

# ---------------------------------------------------------------------------
# The shell under test is the workflow's own: each step's `run: |` block is
# cut out of lateregate.yml and run against a stub `go`, so nothing here can
# drift from what the workflow ships. It runs under `bash -e`, as a `run:`
# step with no `shell:` does on a Linux runner, so a failing command the
# script does not catch stops it here as it would there.
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
LIST_SCRIPT=$(step_script "List the running gates")
LOOP_SCRIPT=$(step_script "Run the gates")
PASSED_SCRIPT=$(step_script "Check every job's result")
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
        bash -e -c "$PLAN_SCRIPT" >/dev/null
    cat "$out"; rm -f "$out"
}

run_case() {
    name="$1"; plan="$2"; hosted="$3"; runs_on="$4"; test_os="$5"; want_gates="$6"; want_tests="$7"
    got=$(plan_outputs "$plan" "$hosted" "$runs_on" "$test_os")
    got_gates=$(printf '%s\n' "$got" | sed -n 's/^gates=//p')
    got_tests=$(printf '%s\n' "$got" | sed -n 's/^tests=//p')
    if [ "$got_gates" = "$want_gates" ] && [ "$got_tests" = "$want_tests" ]; then
        pass "$name"
    else
        fail "$name: gates=$got_gates tests=$got_tests, want gates=$want_gates tests=$want_tests"
    fi
}

UB='["ubuntu-latest"]'
VM='["linux-vm"]'
echo "plan step, hosted runner"

run_case "every running gate but test is a matrix entry, in plan order" \
    '[{"name":"fmt-check","status":"run"},{"name":"test","status":"run"},{"name":"cover","status":"run"}]' \
    true ubuntu-latest "$UB" '["fmt-check","cover"]' "$UB"

run_case "a skipped gate is not a job" \
    '[{"name":"fmt-check","status":"run"},{"name":"spec-lint","status":"skip","reason":"tracks no specs/ files"}]' \
    true ubuntu-latest "$UB" '["fmt-check"]' '[]'

run_case "a waived gate is not a job" \
    '[{"name":"test","status":"run"},{"name":"cover","status":"waived","reason":"later","until":"2026-12-01"}]' \
    true ubuntu-latest "$UB" '[]' "$UB"

run_case "a waived test skips the OS matrix" \
    '[{"name":"test","status":"waived","reason":"r","until":"2026-12-01"},{"name":"race","status":"run"}]' \
    true ubuntu-latest "$UB" '["race"]' '[]'

run_case "an expired waiver runs; the plan carries the note, not the skip" \
    '[{"name":"cover","status":"run","reason":"waiver expired 2026-01-01: later","until":"2026-01-01"}]' \
    true ubuntu-latest "$UB" '["cover"]' '[]'

run_case "both enum gates survive matrix selection" \
    '[{"name":"enum-go","status":"run"},{"name":"test","status":"run"},{"name":"enum-typescript","status":"run"}]' \
    true ubuntu-latest "$UB" '["enum-go","enum-typescript"]' "$UB"

run_case "a waived TypeScript enum gate does not install frontend tools" \
    '[{"name":"enum-go","status":"run"},{"name":"enum-typescript","status":"waived","reason":"migration","until":"2026-12-01"}]' \
    true ubuntu-latest "$UB" '["enum-go"]' '[]'

run_case "suite is a gate job on runs_on, and the matrix keeps the other systems" \
    '[{"name":"fmt-check","status":"run"},{"name":"test","status":"folded","into":"suite"},{"name":"race","status":"folded","into":"suite"},{"name":"suite","status":"run"}]' \
    true ubuntu-latest '["ubuntu-latest","macos-latest"]' '["fmt-check","suite"]' '["macos-latest"]'

run_case "folded gates are never jobs, and a lone runs_on leaves no test matrix" \
    '[{"name":"test","status":"folded","into":"suite"},{"name":"cover","status":"folded","into":"suite"},{"name":"suite","status":"run"}]' \
    true ubuntu-latest "$UB" '["suite"]' '[]'

run_case "a waived suite runs no test anywhere" \
    '[{"name":"test","status":"folded","into":"suite"},{"name":"suite","status":"waived","reason":"r","until":"2026-12-01"}]' \
    true ubuntu-latest "$UB" '[]' '[]'

echo "plan step, self-hosted runner"

run_case "no gate gets a job; all gates passed runs them" \
    '[{"name":"fmt-check","status":"run"},{"name":"lint","status":"run"},{"name":"test","status":"folded","into":"suite"},{"name":"suite","status":"run"},{"name":"vuln","status":"run"}]' \
    false linux-vm "$VM" '[]' '[]'

run_case "a lateregate without suite runs test on runs_on in the one job, not the matrix" \
    '[{"name":"fmt-check","status":"run"},{"name":"test","status":"run"},{"name":"race","status":"run"},{"name":"cover","status":"run"},{"name":"tempdir","status":"run"},{"name":"hermetic","status":"run"},{"name":"license","status":"run"}]' \
    false linux-vm "$VM" '[]' '[]'

run_case "a macOS leg beside the runner still runs plain test" \
    '[{"name":"test","status":"folded","into":"suite"},{"name":"suite","status":"run"},{"name":"modernize","status":"run"}]' \
    false linux-vm '["linux-vm","macos-latest"]' '[]' '["macos-latest"]'

run_case "without suite, the macOS leg runs test and runs_on stays in the one job" \
    '[{"name":"test","status":"run"},{"name":"modernize","status":"run"}]' \
    false linux-vm '["macos-latest","linux-vm"]' '[]' '["macos-latest"]'

run_case "a waived test runs no macOS leg either" \
    '[{"name":"test","status":"waived","reason":"r","until":"2026-12-01"},{"name":"modernize","status":"run"}]' \
    false linux-vm '["macos-latest"]' '[]' '[]'

echo "gate list step, self-hosted runner"

list_case() {
    name="$1"; plan="$2"; want="$3"
    out=$(mktemp)
    log=$(PLAN="$plan" GITHUB_OUTPUT="$out" PATH="$STUB:$PATH" bash -e -c "$LIST_SCRIPT" 2>&1)
    status=$?
    got=$(sed -n 's/^gates=//p' "$out"); rm -f "$out"
    if [ "$status" -eq 0 ] && [ "$got" = "$want" ]; then
        pass "$name"
    else
        fail "$name: status=$status gates=$got, want gates=$want; output: $log"
    fi
}

list_case "every running gate in plan order, suite carrying the folded ones" \
    '[{"name":"fmt-check","status":"run"},{"name":"spec-lint","status":"skip","reason":"no specs"},{"name":"lint","status":"run"},{"name":"suite","status":"run"},{"name":"test","status":"folded","into":"suite"},{"name":"cover","status":"folded","into":"suite"}]' \
    '["fmt-check","lint","suite"]'

list_case "test is listed when it runs, since this job is the test run on runs_on" \
    '[{"name":"fmt-check","status":"run"},{"name":"test","status":"run"},{"name":"cover","status":"run"}]' \
    '["fmt-check","test","cover"]'

list_case "a waived gate is not listed" \
    '[{"name":"fmt-check","status":"run"},{"name":"enum-typescript","status":"waived","reason":"r","until":"2026-12-01"}]' \
    '["fmt-check"]'

list_case "a waived suite lists no test" \
    '[{"name":"test","status":"folded","into":"suite"},{"name":"suite","status":"waived","reason":"r","until":"2026-12-01"}]' \
    '[]'

echo "gate loop"

loop_case() {
    name="$1"; gates="$2"; fail_gates="$3"; enum_setup="$4"; want_calls="$5"; want_status="$6"; want_errors="$7"
    calls=$(mktemp); summary=$(mktemp)
    out=$(GATES="$gates" FAIL="$fail_gates" ENUM_SETUP="$enum_setup" CALLS="$calls" GITHUB_STEP_SUMMARY="$summary" \
        RUNNER_TEMP=/runner/temp TMPDIR=/tmp PATH="$STUB:$PATH" \
        bash -e -c "$LOOP_SCRIPT" 2>&1)
    status=$?
    got_calls=$(tr '\n' ';' < "$calls")
    got_errors=$(printf '%s\n' "$out" | sed -n 's/^::error title=\([^:]*\)::.*/\1/p' | tr '\n' ' ')
    # The step summary names the same failures as the annotations, one row
    # per gate that ran or should have.
    got_rows=$(sed -n 's/^| \([^ ]*\) | \*\*failed\*\* | [0-9]* |$/\1/p' "$summary" | tr '\n' ' ')
    rm -f "$calls" "$summary"
    want_rows=$want_errors
    [ "$want_errors" = "plan " ] && want_rows=""
    if [ "$got_calls" = "$want_calls" ] && [ "$status" -eq "$want_status" ] \
        && [ "$got_errors" = "$want_errors" ] && [ "$got_rows" = "$want_rows" ]; then
        pass "$name"
    else
        fail "$name: calls=$got_calls status=$status errors=[$got_errors] summary=[$got_rows], want calls=$want_calls status=$want_status errors=[$want_errors] summary=[$want_rows]; output: $out"
    fi
}

loop_case "every gate runs in plan order, then the wiring check, and a clean run passes" \
    '["fmt-check","suite","license"]' "" skipped \
    "fmt-check TMPDIR=/tmp;suite TMPDIR=/tmp;license TMPDIR=/tmp;contract TMPDIR=/tmp;" 0 ""

loop_case "lint alone runs under the runner process's own TMPDIR" \
    '["lint","vuln","suite"]' "" skipped \
    "lint TMPDIR=/runner/temp;vuln TMPDIR=/tmp;suite TMPDIR=/tmp;contract TMPDIR=/tmp;" 0 ""

loop_case "a failed gate does not stop the rest, and each failure is annotated and summarized" \
    '["fmt-check","lint","suite","license"]' "fmt-check suite" skipped \
    "fmt-check TMPDIR=/tmp;lint TMPDIR=/runner/temp;suite TMPDIR=/tmp;license TMPDIR=/tmp;contract TMPDIR=/tmp;" 1 "fmt-check suite "

loop_case "the wiring check runs with no gate and fails the job on its own" \
    '[]' "contract" skipped \
    "contract TMPDIR=/tmp;" 1 "contract "

loop_case "a prepared TypeScript setup runs enum-typescript" \
    '["enum-go","enum-typescript"]' "" success \
    "enum-go TMPDIR=/tmp;enum-typescript TMPDIR=/tmp;contract TMPDIR=/tmp;" 0 ""

loop_case "a failed TypeScript setup fails enum-typescript unrun, and the rest still run" \
    '["enum-go","enum-typescript","suite"]' "" skipped \
    "enum-go TMPDIR=/tmp;suite TMPDIR=/tmp;contract TMPDIR=/tmp;" 1 "enum-typescript "

loop_case "an empty gate list fails before the wiring check could pass alone" \
    '' "" skipped "" 1 "plan "

loop_case "a gate list that is not a list fails" \
    '{"gates":["fmt-check"]}' "" skipped "" 1 "plan "

loop_case "a gate list that is not JSON fails" \
    'fmt-check' "" skipped "" 1 "plan "

echo "result check"

passed_case() {
    name="$1"; needs="$2"; want_status="$3"; want_errors="$4"
    out=$(NEEDS="$needs" bash -e -c "$PASSED_SCRIPT" 2>&1)
    status=$?
    got_errors=$(printf '%s\n' "$out" | sed -n 's/^::error title=\([^:]*\)::.*/\1/p' | tr '\n' ' ')
    if [ "$status" -eq "$want_status" ] && [ "$got_errors" = "$want_errors" ]; then
        pass "$name"
    else
        fail "$name: status=$status errors=[$got_errors], want status=$want_status errors=[$want_errors]; output: $out"
    fi
}

passed_case "every job succeeded" \
    '{"probe":{"result":"success","outputs":{}},"test":{"result":"success","outputs":{}},"gate":{"result":"success","outputs":{}},"contract":{"result":"success","outputs":{}}}' \
    0 ""

passed_case "a job that did not apply was skipped" \
    '{"probe":{"result":"success","outputs":{}},"test":{"result":"skipped","outputs":{}},"gate":{"result":"success","outputs":{}},"contract":{"result":"skipped","outputs":{}}}' \
    0 ""

passed_case "on the self-hosted runner every needed job is skipped" \
    '{"probe":{"result":"skipped","outputs":{}},"test":{"result":"skipped","outputs":{}},"gate":{"result":"skipped","outputs":{}},"contract":{"result":"skipped","outputs":{}}}' \
    0 ""

passed_case "a failed gate fails the check and is named" \
    '{"probe":{"result":"success","outputs":{}},"test":{"result":"success","outputs":{}},"gate":{"result":"failure","outputs":{}},"contract":{"result":"success","outputs":{}}}' \
    1 "gate "

passed_case "a failed macOS leg beside the self-hosted runner fails the check and is named" \
    '{"probe":{"result":"success","outputs":{}},"test":{"result":"failure","outputs":{}},"gate":{"result":"skipped","outputs":{}},"contract":{"result":"skipped","outputs":{}}}' \
    1 "test "

passed_case "a cancelled job fails the check" \
    '{"probe":{"result":"success","outputs":{}},"test":{"result":"cancelled","outputs":{}},"gate":{"result":"success","outputs":{}},"contract":{"result":"success","outputs":{}}}' \
    1 "test "

passed_case "a failed probe skips the rest and still fails the check" \
    '{"probe":{"result":"failure","outputs":{}},"test":{"result":"skipped","outputs":{}},"gate":{"result":"skipped","outputs":{}},"contract":{"result":"failure","outputs":{}}}' \
    1 "probe contract "

# ---------------------------------------------------------------------------
# The aggregate job is the one check branch protection requires, so its id,
# its name and its needs are part of the interface: a renamed job leaves a
# required check that never reports, and a job left out of needs is a gate
# the check passes over.
# ---------------------------------------------------------------------------
echo "passed job"

jobs=$(awk '
    /^jobs:$/ { injobs = 1; next }
    injobs && /^[^[:space:]#]/ { exit }
    injobs && /^  [[:alnum:]_-]+:$/ { sub(/^  /, ""); sub(/:$/, ""); print }
' "$WORKFLOW")

job_block() {
    awk -v job="$1" '
        $0 == "  " job ":" { injob = 1; next }
        injob && /^  [[:alnum:]_-]+:/ { exit }
        injob { print }
    ' "$WORKFLOW"
}

# Prints the step of a job block that contains a needle, from its `- ` line
# to the next step.
job_step() {
    printf '%s\n' "$1" | awk -v needle="$2" '
        function emit() { if (index(step, needle)) printf "%s", step }
        /^      - / { emit(); step = "" }
        { step = step $0 "\n" }
        END { emit() }
    '
}

passed_block=$(job_block passed)

if [ -n "$passed_block" ]; then
    pass "the workflow has a job with id passed"
else
    fail "the workflow has no job with id passed; jobs are: $(printf '%s' "$jobs" | tr '\n' ' ')"
fi

if printf '%s\n' "$passed_block" | grep -qxF '    name: all gates passed'; then
    pass "the passed job is named 'all gates passed'"
else
    fail "the passed job must be named 'all gates passed', got: $(printf '%s\n' "$passed_block" | sed -n 's/^    name: //p')"
fi

# A cancelled run cancels the job, which reports cancelled, except a pull
# request run on a hosted label, where the job runs and fails. On the
# self-hosted runner the job is the gates, and running on after a
# cancellation would hold a runner slot for the whole bar.
want_if="    if: \${{ !cancelled() || (github.event_name != 'push' && ($HOSTED_EXPR)) }}"
if printf '%s\n' "$passed_block" | grep -qxF "$want_if"; then
    pass "the passed job runs whatever the jobs it needs did, and stops in a cancelled run except a hosted pull request run"
else
    fail "the passed job must run with$want_if"
fi

want_needs=$(printf '%s\n' "$jobs" | grep -vx passed | sort | tr '\n' ' ')
got_needs=$(printf '%s\n' "$passed_block" | sed -n 's/^    needs: \[\(.*\)\]$/\1/p' | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sort | tr '\n' ' ')
if [ -n "$want_needs" ] && [ "$got_needs" = "$want_needs" ]; then
    pass "the passed job needs every other job: $want_needs"
else
    fail "the passed job needs [$got_needs], want every other job [$want_needs]"
fi

if printf '%s\n' "$passed_block" | grep -qF 'NEEDS: ${{ toJSON(needs) }}'; then
    pass "the result check reads every result from toJSON(needs)"
else
    fail "the result check must read NEEDS: \${{ toJSON(needs) }}"
fi

if job_step "$passed_block" "- name: Check every job's result" | grep -qxF '        if: ${{ always() }}'; then
    pass "the result check runs after a failed gate and in a cancelled hosted pull request run"
else
    fail "the result check must run with if: \${{ always() }}"
fi

# ---------------------------------------------------------------------------
# One job on the self-hosted runner. Each job a run adds there is one more
# wait for one of a few runner slots, so on a self-hosted label with the
# default test_os the run is the passed job alone: the probe, the gate jobs
# and the hosted wiring check are skipped, and the test matrix, which needs
# the probe, with them. A new job, or a condition that lets one of these run
# on the self-hosted runner, is a queue wait added to every private push.
# ---------------------------------------------------------------------------
echo "one job on the self-hosted runner"

got_jobs=$(printf '%s\n' "$jobs" | tr '\n' ' ')
if [ "$got_jobs" = "probe test gate contract passed " ]; then
    pass "the jobs are probe, test, gate, contract and passed"
else
    fail "the jobs are [$got_jobs]; a job added here runs on every self-hosted push unless it is skipped there, so add it to this list with a condition that says so"
fi

check_if() { # job want-if what
    if job_block "$1" | grep -qxF "    if: \${{ $2 }}"; then
        pass "$1: $3"
    else
        fail "$1 must run with if: \${{ $2 }} ($3)"
    fi
}
check_if probe "$HOSTED_EXPR || ((inputs.test_os || format('[\"{0}\"]', inputs.runs_on)) != format('[\"{0}\"]', inputs.runs_on))" \
    "runs on a hosted label, and on the self-hosted runner only when test_os names another system"
check_if contract "$HOSTED_EXPR" "runs on a hosted label only"
check_if gate "needs.probe.outputs.gates != '[]'" "runs only for the gates the probe hands out, none on the self-hosted runner"
check_if test "needs.probe.outputs.tests != '[]'" "runs only for the systems the probe hands out"
for job in gate test; do
    if job_block "$job" | grep -qxF '    needs: probe'; then
        pass "$job needs the probe, so it is skipped with it"
    else
        fail "$job must need the probe"
    fi
done

if printf '%s\n' "$passed_block" | grep -qxF "      RUN_GATES: \${{ !($HOSTED_EXPR) }}"; then
    pass "the passed job runs the gates itself on a self-hosted label only"
else
    fail "the passed job must set RUN_GATES: \${{ !($HOSTED_EXPR) }}"
fi

for target in 'uses: actions/checkout@' 'uses: actions/setup-go@' '- name: List the running gates'; do
    if job_step "$passed_block" "$target" | grep -qxF "        if: \${{ env.RUN_GATES == 'true' }}"; then
        pass "passed: $target runs only where the job runs the gates"
    else
        fail "passed: $target must be conditional on env.RUN_GATES == 'true'"
    fi
done

gates_step=$(job_step "$passed_block" '- name: Run the gates')
if printf '%s\n' "$gates_step" | grep -qxF "        if: \${{ !cancelled() && steps.plan.outcome == 'success' }}" \
    && printf '%s\n' "$gates_step" | grep -qxF '          GATES: ${{ steps.plan.outputs.gates }}' \
    && printf '%s\n' "$gates_step" | grep -qxF '          ENUM_SETUP: ${{ steps.prepare.outcome }}'; then
    pass "the gate loop runs the listed gates after a failed TypeScript setup too"
else
    fail "the gate loop must run on !cancelled() && steps.plan.outcome == 'success' with GATES and ENUM_SETUP from its steps"
fi
if printf '%s\n' "$gates_step" | grep -q 'continue-on-error'; then
    fail "the gate loop must fail the job when a gate fails"
else
    pass "the gate loop fails the job when a gate fails"
fi

# Plan, setup, gates, coverage copy, result: in that order, so the TypeScript
# tools exist before the gates and the result check reads them all.
order=$(printf '%s\n' "$passed_block" | awk '
    /uses: actions\/checkout@/ { print "checkout" }
    /uses: actions\/setup-go@/ { print "setup-go" }
    /- name: List the running gates$/ { print "list" }
    /uses: actions\/setup-node@/ { print "setup-node" }
    /uses: oven-sh\/setup-bun@/ { print "setup-bun" }
    /run: go tool lateregate enum-typescript-prepare$/ { print "prepare" }
    /- name: Run the gates$/ { print "gates" }
    /uses: actions\/upload-artifact@/ { print "upload" }
    /- name: Check every job.s result$/ { print "check" }
' | tr '\n' ' ')
if [ "$order" = "checkout setup-go list setup-node setup-bun prepare gates upload check " ]; then
    pass "the passed job sets up, lists, prepares, runs the gates, keeps coverage and checks, in that order"
else
    fail "the passed job's steps are [$order], want checkout setup-go list setup-node setup-bun prepare gates upload check"
fi

upload=$(job_step "$passed_block" 'uses: actions/upload-artifact@')
if printf '%s\n' "$upload" | grep -qxF "        if: \${{ !cancelled() && (contains(fromJSON(steps.plan.outputs.gates || '[]'), 'cover') || contains(fromJSON(steps.plan.outputs.gates || '[]'), 'suite')) }}"; then
    pass "the passed job keeps coverage.out when cover or suite ran, failed or not"
else
    fail "the passed job's upload must run when cover or suite is listed and the run was not cancelled"
fi

# ---------------------------------------------------------------------------
# The workflow wires the outputs the steps write.
# ---------------------------------------------------------------------------
echo "workflow"

for expr in \
    'gate: ${{ fromJSON(needs.probe.outputs.gates) }}' \
    'os: ${{ fromJSON(needs.probe.outputs.tests) }}' \
    'gates: ${{ steps.plan.outputs.gates }}' \
    'tests: ${{ steps.plan.outputs.tests }}' \
    'GATES: ${{ steps.plan.outputs.gates }}' \
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

if [ -n "$PLAN_SCRIPT" ] && [ -n "$LIST_SCRIPT" ] && [ -n "$LOOP_SCRIPT" ] && [ -n "$PASSED_SCRIPT" ]; then
    pass "every step under test was found in the workflow"
else
    fail "a step under test was not found in the workflow (plan=${#PLAN_SCRIPT} list=${#LIST_SCRIPT} loop=${#LOOP_SCRIPT} passed=${#PASSED_SCRIPT})"
fi

# Both plan steps print the plan the same way, so the reason a gate does not
# run is in the log on either kind of runner.
print_line=$(printf '%s\n' "$PLAN_SCRIPT" | grep -F "jq -r '.[] |")
if [ -n "$print_line" ] && printf '%s\n' "$LIST_SCRIPT" | grep -qxF -- "$print_line"; then
    pass "both plan steps print every gate's status and reason"
else
    fail "the gate list step must print the plan as the probe does"
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
    pass "probe, gate, contract and passed run on inputs.runs_on"
else
    fail "runs_on does not route every non-matrix job (fixed=$fixed routed=$routed)"
fi

# setup-go's cache restore is for hosted runners, which start empty. On the
# self-hosted machine the module cache is already there and the restore
# fails file by file, so every setup-go step gates it on a hosted label, or
# turns it off where only a self-hosted runner reaches it.
setups=$(grep -c 'uses: actions/setup-go' "$WORKFLOW")
gated=$(grep -cE "cache: (false|\\$\\{\\{ startsWith\\((inputs.runs_on|matrix.os), 'ubuntu-'\\))" "$WORKFLOW")
if [ "$setups" -eq "$gated" ]; then
    pass "every setup-go caches only on a hosted runner"
else
    fail "setup-go steps without a hosted-only cache gate (setups=$setups gated=$gated)"
fi

# Check the actual step blocks, not independent occurrences: a condition on
# an adjacent step would still install Node/Bun for every Go gate. Both jobs
# that can run the TypeScript enum gate set it up, each on its own condition.
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
    if job_step "$block" 'uses: oven-sh/setup-bun@' | grep -qxF '          HOME: ${{ runner.temp }}'; then
        pass "$1: Bun installs into the job's own temp directory"
    else
        fail "$1: Bun must install under HOME: \${{ runner.temp }}"
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
        pass "$target appears in the gate job and the passed job, nowhere else"
    else
        fail "$target appears $count times, want 2"
    fi
done
check_enum_setup gate "matrix.gate == 'enum-typescript'" 'run: go tool lateregate ${{ matrix.gate }}'
check_enum_setup passed "contains(fromJSON(steps.plan.outputs.gates || '[]'), 'enum-typescript')" '- name: Run the gates'

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
