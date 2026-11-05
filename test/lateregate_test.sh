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

MODULE_SCRIPT=$(step_script "Find the gate module")
INSTALL_SCRIPT=$(step_script "Install the browsers a frontend's tests drive")
PLAN_SCRIPT=$(step_script "Read the plan")
LIST_SCRIPT=$(step_script "List the running gates")
LOOP_SCRIPT=$(step_script "Run the gates")
PASSED_SCRIPT=$(step_script "Check every job's result")
STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT
# The workflow's env sets GATE_MODULE and the runner GITHUB_WORKSPACE for
# every step; the steps read both under set -u.
export GATE_MODULE=. GITHUB_WORKSPACE=/workspace

# The stub go answers `go tool lateregate list -json` with $PLAN and logs the
# arguments it was given to $LISTLOG. It answers `base` as $BASE says: a
# commit, "none" for no base with the reason on stderr (exit 0), or "old" for
# a lateregate that does not have the command. Every other gate it is asked to
# run is recorded with the TMPDIR it saw, and the gates named in $FAIL fail.
cat > "$STUB/go" <<'EOF'
#!/usr/bin/env bash
# go -C <gate module> tool lateregate <gate> -C <root>
[ "$1" = -C ] && shift 2
shift 2
if [ "$1" = list ]; then echo "$*" >> "${LISTLOG:-/dev/null}"; printf '%s\n' "$PLAN"; exit 0; fi
if [ "$1" = base ]; then
    case "${BASE:-old}" in
    old) echo 'lateregate: unknown command "base"' >&2; exit 2 ;;
    none) echo 'no green run of this workflow on the default branch' >&2; exit 0 ;;
    *) echo "$BASE"; exit 0 ;;
    esac
fi
gate=$1
# A gate run by name carries -since only when the plan had a base.
since=""
while [ $# -gt 0 ]; do [ "$1" = -since ] && since=" since=$2"; shift; done
echo "$gate TMPDIR=${TMPDIR:-}$since" >> "$CALLS"
set -- "$gate"
case " $FAIL " in *" $1 "*) exit 1 ;; esac
exit 0
EOF
chmod +x "$STUB/go"

# The environment both plan steps read; BROWSER is the superseded
# frontend_browser_package input, and BASE picks the stub's base answer.
plan_outputs() { # plan hosted runs_on test_os
    out=$(mktemp)
    PLAN="$1" HOSTED="$2" RUNS_ON="$3" TEST_OS="$4" BROWSER="${BROWSER:-}" GITHUB_OUTPUT="$out" \
        GITHUB_STEP_SUMMARY=/dev/null GITHUB_TOKEN=t PATH="$STUB:$PATH" \
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
    log=$(PLAN="$plan" RUNS_ON="${RUNS_ON:-linux-vm}" PROBE_RESULT="${PROBE_RESULT:-success}" BROWSER="${BROWSER:-}" \
        GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY=/dev/null GITHUB_TOKEN=t PATH="$STUB:$PATH" bash -e -c "$LIST_SCRIPT" 2>&1)
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

# With a base from the plan step, every gate run by name is measured from it,
# so a gate that holds parts of its own skips the parts the change misses.
calls=$(mktemp)
GATES='["suite","lint"]' FAIL="" ENUM_SETUP=skipped CALLS="$calls" GITHUB_STEP_SUMMARY=/dev/null BASE=abc123 \
    RUNNER_TEMP=/runner/temp TMPDIR=/tmp PATH="$STUB:$PATH" bash -e -c "$LOOP_SCRIPT" >/dev/null 2>&1
got=$(tr '\n' ';' < "$calls"); rm -f "$calls"
want="suite TMPDIR=/tmp since=abc123;lint TMPDIR=/runner/temp since=abc123;contract TMPDIR=/tmp since=abc123;"
if [ "$got" = "$want" ]; then
    pass "a base reaches every gate run by name"
else
    fail "a base reaches every gate run by name: got $got, want $want"
fi

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

for target in 'uses: actions/checkout@' '- name: Find the gate module' 'uses: actions/setup-go@' '- name: List the running gates'; do
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
    /- name: Find the gate module$/ { print "module" }
    /uses: actions\/setup-go@/ { print "setup-go" }
    /- name: List the running gates$/ { print "list" }
    /uses: actions\/setup-node@/ { print "setup-node" }
    /uses: oven-sh\/setup-bun@/ { print "setup-bun" }
    /- name: Install the browsers/ { print "browsers" }
    /tool lateregate enum-typescript-prepare -C/ { print "prepare" }
    /- name: Run the gates$/ { print "gates" }
    /uses: actions\/upload-artifact@/ { print "upload" }
    /- name: Check every job.s result$/ { print "check" }
' | tr '\n' ' ')
if [ "$order" = "checkout module setup-go list setup-node setup-bun browsers prepare gates upload check " ]; then
    pass "the passed job sets up, lists, prepares, runs the gates, keeps coverage and checks, in that order"
else
    fail "the passed job's steps are [$order], want checkout module setup-go list setup-node setup-bun browsers prepare gates upload check"
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

# A call that skipped the gate module would run a root pin that a nested
# gate module does not have, or none at all.
if bare=$(grep -n 'go tool lateregate' "$WORKFLOW"); then
    fail "every lateregate call runs from the gate module; these do not: $bare"
else
    pass "every lateregate call runs from the gate module against the root"
fi

for expr in \
    'gate: ${{ fromJSON(needs.probe.outputs.gates) }}' \
    'os: ${{ fromJSON(needs.probe.outputs.tests) }}' \
    'gates: ${{ steps.plan.outputs.gates }}' \
    'tests: ${{ steps.plan.outputs.tests }}' \
    'GATES: ${{ steps.plan.outputs.gates }}' \
    'go -C "$GATE_MODULE" tool lateregate list -json -C "$GITHUB_WORKSPACE"' \
    'go -C "$GATE_MODULE" tool lateregate contract -C "$GITHUB_WORKSPACE"' \
    'go -C "$GATE_MODULE" tool lateregate ${{ matrix.gate }} -C "$GITHUB_WORKSPACE"' \
    'go -C "$GATE_MODULE" tool lateregate test -C "$GITHUB_WORKSPACE"' \
    'GATE_INPUT: ${{ inputs.gate_module }}' \
    'echo "GATE_MODULE=$module" >> "$GITHUB_ENV"' \
    'base: ${{ steps.plan.outputs.base }}' \
    'gate_needs: ${{ steps.plan.outputs.gate_needs }}' \
    'GITHUB_TOKEN: ${{ github.token }}'
do
    if grep -qF -- "$expr" "$WORKFLOW"; then
        pass "workflow carries: $expr"
    else
        fail "workflow lost: $expr"
    fi
done

if [ -n "$MODULE_SCRIPT" ] && [ -n "$INSTALL_SCRIPT" ] && [ -n "$PLAN_SCRIPT" ] && [ -n "$LIST_SCRIPT" ] && [ -n "$LOOP_SCRIPT" ] && [ -n "$PASSED_SCRIPT" ]; then
    pass "every step under test was found in the workflow"
else
    fail "a step under test was not found in the workflow (module=${#MODULE_SCRIPT} install=${#INSTALL_SCRIPT} plan=${#PLAN_SCRIPT} list=${#LIST_SCRIPT} loop=${#LOOP_SCRIPT} passed=${#PASSED_SCRIPT})"
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
gated=$(grep -cE "cache: (false|\\$\\{\\{ runner\\.environment == 'github-hosted' \\}\\})" "$WORKFLOW")
if [ "$setups" -eq "$gated" ]; then
    pass "every setup-go caches only on a hosted runner"
else
    fail "setup-go steps without a hosted-only cache gate (setups=$setups gated=$gated)"
fi

# Check the actual step blocks, not independent occurrences: a condition on
# an adjacent step would still install Node/Bun for every Go gate. Both jobs
# that can run the TypeScript enum or frontend gate set up the runtimes for
# either, and prepare enum projects only for the enum gate.
check_enum_setup() { # job node-condition bun-condition prepare-condition run-step
    block=$(job_block "$1")
    if job_step "$block" 'uses: actions/setup-node@' | grep -qxF "        if: \${{ $2 }}"; then
        pass "$1: Node is installed only where the plan needs it"
    else
        fail "$1: setup-node must be conditional on $2"
    fi
    if job_step "$block" 'uses: oven-sh/setup-bun@' | grep -qxF "        if: \${{ $3 }}"; then
        pass "$1: Bun is installed only where the plan needs it"
    else
        fail "$1: setup-bun must be conditional on $3"
    fi
    if job_step "$block" 'run: go -C "$GATE_MODULE" tool lateregate enum-typescript-prepare -C "$GITHUB_WORKSPACE"' | grep -qxF "        if: \${{ $4 }}"; then
        pass "$1: enum projects are prepared only for the TypeScript enum gate"
    else
        fail "$1: enum-typescript-prepare must be conditional on $4"
    fi
    if job_step "$block" 'uses: actions/setup-node@' | grep -qxE '          node-version: "[0-9]+"'; then
        pass "$1: the TypeScript enum gate pins a Node major"
    else
        fail "$1: the TypeScript enum gate must pin a Node major"
    fi
    if job_step "$block" 'uses: oven-sh/setup-bun@' | grep -qxF '          bun-version: "1.4.4"'; then
        pass "$1: the TypeScript enum gate pins Bun"
    else
        fail "$1: the TypeScript enum gate must pin Bun 1.4.4"
    fi
    if job_step "$block" 'uses: oven-sh/setup-bun@' | grep -qxF '          HOME: ${{ runner.temp }}'; then
        pass "$1: Bun installs into the job's own temp directory"
    else
        fail "$1: Bun must install under HOME: \${{ runner.temp }}"
    fi
    if printf '%s\n' "$block" | awk -v check="$5" '
        /uses: actions\/setup-node@/ { node = NR }
        /uses: oven-sh\/setup-bun@/ { bun = NR }
        /tool lateregate enum-typescript-prepare -C/ { prepare = NR }
        index($0, check) { run = NR }
        END { exit !(node && bun && prepare && run && node < prepare && bun < prepare && prepare < run) }
    '; then
        pass "$1: both runtimes are set up before frozen preparation and gate checking"
    else
        fail "$1: enum checking must follow both runtime setups and frozen preparation"
    fi
}

for target in 'uses: actions/setup-node@' 'uses: oven-sh/setup-bun@' 'run: go -C "$GATE_MODULE" tool lateregate enum-typescript-prepare -C "$GITHUB_WORKSPACE"'; do
    count=$(grep -cF "$target" "$WORKFLOW")
    if [ "$count" -eq 2 ]; then
        pass "$target appears in the gate job and the passed job, nowhere else"
    else
        fail "$target appears $count times, want 2"
    fi
done
GATE_NEEDS="fromJSON(needs.probe.outputs.gate_needs)[matrix.gate] || fromJSON('[]')"
check_enum_setup gate "contains($GATE_NEEDS, 'node')" "contains($GATE_NEEDS, 'bun')" \
    "matrix.gate == 'enum-typescript'" 'tool lateregate ${{ matrix.gate }} -C'
PASSED_NEEDS="fromJSON(steps.plan.outputs.needs || '[]')"
check_enum_setup passed "contains($PASSED_NEEDS, 'node')" "contains($PASSED_NEEDS, 'bun')" \
    "contains(fromJSON(steps.plan.outputs.gates || '[]'), 'enum-typescript')" '- name: Run the gates'

# ---------------------------------------------------------------------------
# The base of the plan. Both steps that read the plan resolve it once with
# `lateregate base -since green`. A pin without the command, a failure, or an
# empty answer lists the whole tree and says why; a commit is passed to list
# as -since, and the base is in the log and the step summary.
# ---------------------------------------------------------------------------
echo "plan base"

BASE_PLAN='[{"name":"fmt-check","status":"run"},{"name":"test","status":"run"}]'

base_case() { # name script base want-list-args want-log-fragment
    name="$1"; script="$2"; base="$3"; want_args="$4"; want_log="$5"
    listlog=$(mktemp); out=$(mktemp); summary=$(mktemp)
    log=$(PLAN="$BASE_PLAN" BASE="$base" LISTLOG="$listlog" HOSTED=true RUNS_ON=ubuntu-latest TEST_OS="$UB" \
        PROBE_RESULT=success BROWSER= GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary" GITHUB_TOKEN=t \
        PATH="$STUB:$PATH" bash -e -c "$script" 2>&1)
    status=$?
    got_args=$(cat "$listlog"); got_base=$(sed -n 's/^base=//p' "$out"); got_summary=$(cat "$summary")
    rm -f "$listlog" "$out" "$summary"
    want_base=""; case "$base" in old | none) ;; *) want_base=$base ;; esac
    if [ "$status" -eq 0 ] && [ "$got_args" = "$want_args" ] && [ "$got_base" = "$want_base" ] \
        && printf '%s\n' "$log" | grep -qF -- "$want_log" && printf '%s\n' "$got_summary" | grep -qF -- "$want_log"; then
        pass "$name"
    else
        fail "$name: status=$status list args=[$got_args] base=[$got_base], want args=[$want_args] base=[$want_base] log containing [$want_log]; log: $log; summary: $got_summary"
    fi
}

for which in plan list; do
    if [ "$which" = plan ]; then script=$PLAN_SCRIPT; else script=$LIST_SCRIPT; fi
    base_case "$which: a lateregate without the base command lists the whole tree and says so" "$script" old \
        "list -json -C /workspace" 'lateregate base failed: lateregate: unknown command "base"'
    base_case "$which: no base lists the whole tree with the reason base gave" "$script" none \
        "list -json -C /workspace" "The whole tree is checked: no green run of this workflow on the default branch"
    base_case "$which: a base is passed to list as -since and named" "$script" 0123abcd \
        "list -json -since 0123abcd -C /workspace" "last green commit 0123abcd"
done

# Without GITHUB_STEP_SUMMARY writable the plan still reads.
if out=$(PLAN="$BASE_PLAN" BASE=none HOSTED=true RUNS_ON=ubuntu-latest TEST_OS="$UB" BROWSER= GITHUB_OUTPUT=/dev/null \
    GITHUB_STEP_SUMMARY=/nonexistent/summary GITHUB_TOKEN=t PATH="$STUB:$PATH" bash -e -c "$PLAN_SCRIPT" 2>&1) \
    && printf '%s\n' "$out" | grep -qF '::warning::cannot write the step summary'; then
    pass "an unwritable step summary warns and the plan still reads"
else
    fail "an unwritable step summary must warn, not stop the plan: $out"
fi

# ---------------------------------------------------------------------------
# What a gate installs comes from the plan's needs. A pin that predates the
# field gets today's rule: Node and Bun for enum-typescript and frontend, and
# the browser package the caller names for frontend.
# ---------------------------------------------------------------------------
echo "needs"

needs_case() { # name plan browser want-gate-needs
    name="$1"; plan="$2"; browser="$3"; want="$4"
    got=$(BROWSER="$browser" plan_outputs "$plan" true ubuntu-latest "$UB" | sed -n 's/^gate_needs=//p')
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name: gate_needs=$got, want $want"; fi
}

needs_case "needs in the plan are handed to each gate by name" \
    '[{"name":"frontend","status":"run","needs":["node","bun","chromium:web"]},{"name":"enum-typescript","status":"run","needs":["node","bun"]},{"name":"lint","status":"run"}]' \
    "" '{"frontend":["node","bun","chromium:web"],"enum-typescript":["node","bun"],"lint":[]}'

needs_case "a plan with needs ignores the superseded browser input" \
    '[{"name":"frontend","status":"run","needs":["node","bun"]},{"name":"lint","status":"run"}]' \
    "web" '{"frontend":["node","bun"],"lint":[]}'

needs_case "a skipped gate hands out nothing" \
    '[{"name":"frontend","status":"skip","reason":"unchanged","needs":["node","bun"]},{"name":"lint","status":"run"}]' \
    "" '{"lint":[]}'

needs_case "without the field, enum-typescript and frontend get node and bun" \
    '[{"name":"frontend","status":"run"},{"name":"enum-typescript","status":"run"},{"name":"lint","status":"run"}]' \
    "" '{"frontend":["node","bun"],"enum-typescript":["node","bun"],"lint":[]}'

needs_case "without the field, the browser package input gives frontend its browser" \
    '[{"name":"frontend","status":"run"},{"name":"enum-typescript","status":"run"}]' \
    "app/web" '{"frontend":["node","bun","chromium:app/web"],"enum-typescript":["node","bun"]}'

needs_case "without the field and without a frontend, nothing is installed" \
    '[{"name":"lint","status":"run"},{"name":"suite","status":"run"}]' \
    "app/web" '{"lint":[],"suite":[]}'

list_needs_case() { # name plan browser want-needs
    name="$1"; plan="$2"; browser="$3"; want="$4"
    out=$(mktemp)
    BROWSER="$browser" PLAN="$plan" RUNS_ON=linux-vm PROBE_RESULT=skipped BASE=none GITHUB_OUTPUT="$out" \
        GITHUB_STEP_SUMMARY=/dev/null GITHUB_TOKEN=t PATH="$STUB:$PATH" bash -e -c "$LIST_SCRIPT" >/dev/null 2>&1
    got=$(sed -n 's/^needs=//p' "$out"); rm -f "$out"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name: needs=$got, want $want"; fi
}

list_needs_case "self-hosted: the job installs the union of what the running gates need" \
    '[{"name":"frontend","status":"run","needs":["node","bun","chromium:web"]},{"name":"enum-typescript","status":"run","needs":["node","bun"]},{"name":"lint","status":"run"},{"name":"vuln","status":"skip","needs":["x"]}]' \
    "" '["bun","chromium:web","node"]'
list_needs_case "self-hosted: a pin without the field gets node, bun and the named browser" \
    '[{"name":"frontend","status":"run"},{"name":"lint","status":"run"}]' \
    "web" '["bun","chromium:web","node"]'
list_needs_case "self-hosted: no frontend gate installs nothing" \
    '[{"name":"lint","status":"run"}]' "web" '[]'

# The install step runs bun in each named directory, keeps going after a
# failure, and fails the step so the caller sees it, with the gate failing on
# its own test.
mkdir -p "$STUB/ws/web" "$STUB/ws/app/e2e"
cat > "$STUB/bun" <<'EOF'
#!/usr/bin/env bash
echo "bun $* in ${PWD#"$WS"/}" >> "$CALLS"
[ -n "$BAD" ] && case "$PWD" in *"$BAD") exit 1 ;; esac
exit 0
EOF
cat > "$STUB/bunx" <<'EOF'
#!/usr/bin/env bash
echo "bunx $* in ${PWD#"$WS"/}" >> "$CALLS"
EOF
chmod +x "$STUB/bun" "$STUB/bunx"

install_case() { # name needs bad want-calls want-status
    name="$1"; needs="$2"; bad="$3"; want_calls="$4"; want_status="$5"
    calls=$(mktemp)
    NEEDS="$needs" BAD="$bad" WS="$STUB/ws" CALLS="$calls" GITHUB_WORKSPACE="$STUB/ws" PATH="$STUB:$PATH" \
        bash -e -c "$INSTALL_SCRIPT" >/dev/null 2>&1
    status=$?
    got=$(tr '\n' ';' < "$calls"); rm -f "$calls"
    if [ "$got" = "$want_calls" ] && [ "$status" -eq "$want_status" ]; then
        pass "$name"
    else
        fail "$name: calls=$got status=$status, want calls=$want_calls status=$want_status"
    fi
}

install_case "each chromium need installs its package, then the browser" \
    '["node","bun","chromium:web","chromium:app/e2e"]' "" \
    "bun install --frozen-lockfile in web;bunx playwright install --with-deps chromium in web;bun install --frozen-lockfile in app/e2e;bunx playwright install --with-deps chromium in app/e2e;" 0
install_case "needs with no browser install nothing" '["node","bun"]' "" "" 0
install_case "a gate that needs nothing installs nothing" '[]' "" "" 0
install_case "a gate with no needs entry installs nothing" 'null' "" "" 0
install_case "a failed install is reported, skips that browser, and the others still install" \
    '["chromium:web","chromium:app/e2e"]' "web" \
    "bun install --frozen-lockfile in web;bun install --frozen-lockfile in app/e2e;bunx playwright install --with-deps chromium in app/e2e;" 1

# ---------------------------------------------------------------------------
# The systems test runs on come from the test entry's os, else test_os.
# ---------------------------------------------------------------------------
echo "test systems"

OS_PLAN_SUITE='[{"name":"test","status":"folded","into":"suite","os":["ubuntu-latest","macos-latest"]},{"name":"suite","status":"run"}]'
run_case "os in the plan beats test_os; the matrix keeps the other systems" \
    "$OS_PLAN_SUITE" true ubuntu-latest '["ubuntu-latest","windows-latest"]' '["suite"]' '["macos-latest"]'
run_case "os in the plan runs a plain test on each system when there is no suite" \
    '[{"name":"test","status":"run","os":["ubuntu-latest","macos-latest"]}]' \
    true ubuntu-latest "$UB" '[]' '["ubuntu-latest","macos-latest"]'
run_case "an empty os in the plan falls back to test_os" \
    '[{"name":"test","status":"run","os":[]}]' \
    true ubuntu-latest '["macos-latest"]' '[]' '["macos-latest"]'
run_case "no os in the plan falls back to test_os" \
    '[{"name":"test","status":"run"}]' \
    true ubuntu-latest '["ubuntu-latest","macos-latest"]' '[]' '["ubuntu-latest","macos-latest"]'
run_case "self-hosted: os in the plan gives the matrix its other systems" \
    "$OS_PLAN_SUITE" false linux-vm '["linux-vm"]' '[]' '["ubuntu-latest","macos-latest"]'

os_guard_case() { # name plan probe want-status
    name="$1"; plan="$2"; probe="$3"; want="$4"
    out=$(mktemp)
    log=$(PLAN="$plan" RUNS_ON=linux-vm PROBE_RESULT="$probe" BASE=none BROWSER= GITHUB_OUTPUT="$out" \
        GITHUB_STEP_SUMMARY=/dev/null GITHUB_TOKEN=t PATH="$STUB:$PATH" bash -e -c "$LIST_SCRIPT" 2>&1)
    status=$?; rm -f "$out"
    if [ "$status" -eq "$want" ]; then pass "$name"; else fail "$name: status=$status, want $want; $log"; fi
}
os_guard_case "self-hosted: a plan naming another system fails when the probe did not run for it" \
    '[{"name":"test","status":"run","os":["linux-vm","macos-latest"]}]' skipped 1
os_guard_case "self-hosted: the same plan passes when the probe ran" \
    '[{"name":"test","status":"run","os":["linux-vm","macos-latest"]}]' success 0
os_guard_case "self-hosted: a waived test needs no other system" \
    '[{"name":"test","status":"waived","reason":"r","until":"2026-12-01","os":["macos-latest"]}]' skipped 0
os_guard_case "self-hosted: a plan naming only runs_on passes" \
    '[{"name":"test","status":"run","os":["linux-vm"]}]' skipped 0

# ---------------------------------------------------------------------------
# The module that pins the tool: the input, else the root go.mod when it has
# a tool line for lateregate, else the one tracked go.mod that does.
# ---------------------------------------------------------------------------
echo "gate module"

TOOL=latere.ai/x/ci-gate/cmd/lateregate
module_case() { # name input want-module want-status files...
    name="$1"; input="$2"; want="$3"; want_status="$4"; shift 4
    repo=$(mktemp -d); env_file=$(mktemp)
    git -C "$repo" init -q
    while [ $# -gt 0 ]; do
        mkdir -p "$repo/$(dirname "$1")"
        printf '%b' "$2" > "$repo/$1"
        git -C "$repo" add "$1"
        shift 2
    done
    out=$(GATE_INPUT="$input" GITHUB_WORKSPACE="$repo" GITHUB_ENV="$env_file" bash -e -c "$MODULE_SCRIPT" 2>&1)
    status=$?
    got=$(sed -n 's/^GATE_MODULE=//p' "$env_file")
    rm -rf "$repo" "$env_file"
    if [ "$status" -eq "$want_status" ] && [ "$got" = "$want" ]; then
        pass "$name"
    else
        fail "$name: status=$status module=[$got], want status=$want_status module=[$want]; $out"
    fi
}

NO_TOOL="module example.com/m\n\ngo 1.27\n"
module_case "root: a single-line tool directive" "" "." 0 \
    go.mod "module m\n\ntool $TOOL\n"
module_case "root: a tool block" "" "." 0 \
    go.mod "module m\n\ntool (\n\texample.com/x/other/cmd/x\n\t$TOOL\n)\n"
module_case "root: a tool line beside other tools" "" "." 0 \
    go.mod "module m\n\ntool example.com/other\ntool $TOOL\n"
module_case "root wins over a nested module that also pins it" "" "." 0 \
    go.mod "module m\ntool $TOOL\n" internal/gate/go.mod "module g\ntool $TOOL\n"
module_case "nested: the one tracked go.mod with the tool line" "" "internal/gate" 0 \
    go.mod "$NO_TOOL" internal/gate/go.mod "module g\n\ntool (\n\t$TOOL\n)\n" other/go.mod "$NO_TOOL"
module_case "nested: no root go.mod at all" "" "tools/gate" 0 \
    tools/gate/go.mod "module g\ntool $TOOL\n"
module_case "a comment or a require is not a tool line" "" "." 0 \
    go.mod "module m\n// tool $TOOL\nrequire $TOOL v1.0.0\n"
module_case "a file merely named like go.mod is not a module" "" "." 0 \
    go.mod "$NO_TOOL" mygo.mod "tool $TOOL\n"
module_case "none: no go.mod pins the tool, so the root stays and the contract check says why" "" "." 0 \
    go.mod "$NO_TOOL" sub/go.mod "$NO_TOOL"
module_case "no go.mod at all stays on the root" "" "." 0 \
    README.md "hi\n"
module_case "several nested modules pin it: the run fails and names the input" "" "" 1 \
    a/go.mod "module a\ntool $TOOL\n" b/go.mod "module b\ntool $TOOL\n"
module_case "the input wins over a root pin" "internal/gate" "internal/gate" 0 \
    go.mod "module m\ntool $TOOL\n"
module_case "the input wins when nothing is detectable" "x/y" "x/y" 0 \
    README.md "hi\n"

# Every job finds the module in a step of its own before any lateregate call.
for job in probe test gate contract passed; do
    block=$(job_block "$job")
    first_call=$(printf '%s\n' "$block" | grep -n 'go -C "$GATE_MODULE"' | head -1 | cut -d: -f1)
    find_line=$(printf '%s\n' "$block" | grep -n -- '- name: Find the gate module' | cut -d: -f1)
    if [ -n "$find_line" ] && [ -n "$first_call" ] && [ "$find_line" -lt "$first_call" ]; then
        pass "$job finds the gate module before it runs lateregate"
    else
        fail "$job must find the gate module (line [$find_line]) before its first lateregate call (line [$first_call])"
    fi
done
# A reusable workflow that asks for more than its caller grants fails at
# startup, so the workflow asks for nothing beyond contents: read and a
# caller's grant of actions: read reaches the plan through the caller's
# token.
extra=$(awk '/^permissions:/ { p = 1; next } p && /^[^ ]/ { exit } p && NF' "$WORKFLOW" | grep -vxF '  contents: read' || true)
if [ -z "$extra" ]; then
    pass "the workflow asks for no permission a contents: read caller lacks"
else
    fail "the workflow asks for permissions a contents: read caller does not grant: $extra"
fi

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
