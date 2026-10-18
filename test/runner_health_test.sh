#!/usr/bin/env bash
#
# runner-health.yml moves CI_RUNNER_PRIVATE between linux-vm and
# ubuntu-latest by two rules: offline (no linux-vm runner online) and busy
# (a queued linux-vm job has waited past a threshold), offline first. This
# runs the workflow's own script, cut out of the YAML, against a stub gh that
# serves canned API responses through the script's real jq filters and
# records every variable write, so the rules are tested as shipped. A second
# part evaluates the script's decide function alone over a table of runner
# counts, waits and current values.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/runner-health.yml"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

if ! command -v jq >/dev/null 2>&1; then
    fail "jq is not installed; the script and its stub need it"
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The step's script: everything under its `run: |`, which is the last key of
# the last step, with the YAML indentation removed.
awk '/^        run: \|$/ { on = 1; next } on { sub(/^          /, ""); print }' "$WORKFLOW" > "$WORK/script.sh"
if ! grep -q 'gh api -X PATCH' "$WORK/script.sh"; then
    fail "cannot cut the script out of runner-health.yml"
    printf "\n1 failure(s)\n"
    exit 1
fi

# The workflow's own constants, as the step's env sets them.
env_of() { sed -n "s/^          $1: \"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$WORKFLOW"; }
BUSY=$(env_of BUSY_AFTER_MINUTES)
CLEAR=$(env_of CLEAR_BELOW_MINUTES)
if [ "$BUSY" = 20 ] && [ "$CLEAR" = 5 ]; then
    pass "the thresholds are named constants: BUSY_AFTER_MINUTES=$BUSY, CLEAR_BELOW_MINUTES=$CLEAR"
else
    fail "the thresholds are not the approved constants (BUSY_AFTER_MINUTES='$BUSY' CLEAR_BELOW_MINUTES='$CLEAR')"
fi
if grep -nE '\b(20|5|300|1200)\b' "$WORK/script.sh" | grep -v '20\[0-9\]' >/dev/null; then
    fail "the script spells a threshold as a number instead of reading the constant"
    grep -nE '\b(20|5|300|1200)\b' "$WORK/script.sh" | grep -v '20\[0-9\]' | sed 's/^/      /'
else
    pass "the script reads its thresholds from the constants only"
fi

# A stub gh. It serves a fixture for each endpoint the script reads, applies
# the script's --jq filter to it with the real jq, and records writes.
#   $WORK/online         one line per runners listing; numbers on a line are
#                        pages, each the count of online linux-vm runners
#   $WORK/repos.json     the organization's repositories
#   $WORK/runs/R.S.json  repository R's runs in status S (queued, in_progress)
#   $WORK/jobs/ID.json   run ID's jobs
#   $WORK/log            CI_RUNNER_SWITCHES's value
#   $WORK/writes         one NAME=value line per variable write
mkdir -p "$WORK/bin" "$WORK/runs" "$WORK/jobs"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
method=GET path="" filter="." value=""
while [ $# -gt 0 ]; do
    case "$1" in
        api|--paginate) ;;
        -X) method=$2; shift ;;
        --jq) filter=$2; shift ;;
        -f) value=${2#value=}; shift ;;
        *) path=$1 ;;
    esac
    shift
done
echo "$method $path" >> "$WORK/calls"
serve() { jq -r "$filter"; }
case "$method $path" in
    "GET /orgs/"*"/actions/runners"*)
        [ "${STUB_LIST_FAIL:-}" = 1 ] && { echo "gh: Forbidden (HTTP 403)" >&2; exit 1; }
        n=$(grep -c 'actions/runners' "$WORK/calls")
        line=$(sed -n "${n}p" "$WORK/online")
        [ -n "$line" ] || line=$(tail -n 1 "$WORK/online")
        for page in $line; do
            jq -n --argjson n "$page" '{runners: ([range($n)] | map({status: "online", labels: [{name: "self-hosted"}, {name: "linux-vm"}]}) + [{status: "offline", labels: [{name: "linux-vm"}]}])}' | serve
        done
        ;;
    "GET /orgs/"*"/repos"*)
        [ "${STUB_QUEUE_FAIL:-}" = 1 ] && { echo "gh: Forbidden (HTTP 403)" >&2; exit 1; }
        serve < "$WORK/repos.json"
        ;;
    "GET /repos/"*"/actions/runs?status="*)
        repo=${path#/repos/*/}; repo=${repo%%/*}
        status=${path#*status=}; status=${status%%&*}
        f="$WORK/runs/$repo.$status.json"
        if [ -f "$f" ]; then serve < "$f"; else echo '{"workflow_runs": []}' | serve; fi
        ;;
    "GET /repos/"*"/actions/runs/"*"/jobs"*)
        id=${path#*/actions/runs/}; id=${id%%/*}
        serve < "$WORK/jobs/$id.json"
        ;;
    "GET /orgs/"*"/actions/variables/CI_RUNNER_PRIVATE")
        [ "${STUB_READ_FAIL:-}" = 1 ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        jq -n --arg v "$STUB_HAVE" '{name: "CI_RUNNER_PRIVATE", value: $v}' | serve
        ;;
    "GET /orgs/"*"/actions/variables/CI_RUNNER_SWITCHES")
        [ "${STUB_LOG_READ_FAIL:-}" = 1 ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        jq -n --rawfile v "$WORK/log" '{name: "CI_RUNNER_SWITCHES", value: ($v | rtrimstr("\n"))}' | serve
        ;;
    "PATCH /orgs/"*"/actions/variables/"*)
        name=${path##*/}
        [ "${STUB_PATCH_FAIL:-}" = "$name" ] && { echo "gh: Forbidden (HTTP 403)" >&2; exit 1; }
        if [ "$name" = CI_RUNNER_SWITCHES ]; then
            printf '%s\n' "$value" > "$WORK/log"
            echo "$name=$(printf '%s\n' "$value" | tail -n 1)" >> "$WORK/writes"
        else
            echo "$name=$value" >> "$WORK/writes"
        fi
        ;;
    *) echo "stub gh: unexpected call: $method $path" >&2; exit 2 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

# The clock every case runs at, and the ISO time a number of minutes before.
NOW=1792336800
ago() { jq -nr --argjson t $((NOW - $1 * 60)) '$t | todate'; }

# Fixtures: two private repositories, one archived private one, one public.
repos() {
    cat > "$WORK/repos.json" <<EOF
[{"name": "alpha", "private": true, "archived": false},
 {"name": "beta", "private": true, "archived": false},
 {"name": "attic", "private": true, "archived": true},
 {"name": "open", "private": false, "archived": false}]
EOF
}
# queue REPO STATUS RUN [JOB...]: run RUN of REPO in STATUS holds the jobs,
# each "status:label:minutes-ago".
queue() {
    local repo=$1 status=$2 run=$3 jobs="" j s l m
    shift 3
    for j in "$@"; do
        s=${j%%:*}; l=${j#*:}; l=${l%%:*}; m=${j##*:}
        jobs="$jobs${jobs:+,}{\"status\": \"$s\", \"labels\": [\"$l\"], \"created_at\": \"$(ago "$m")\"}"
    done
    local f="$WORK/runs/$repo.$status.json"
    if [ -f "$f" ]; then
        jq --argjson id "$run" '.workflow_runs += [{id: $id}]' "$f" > "$f.new" && mv "$f.new" "$f"
    else
        jq -n --argjson id "$run" '{workflow_runs: [{id: $id}]}' > "$f"
    fi
    echo "{\"jobs\": [$jobs]}" > "$WORK/jobs/$run.json"
}

# run_case name token have online-lines want-exit want-writes [env...]
run_case() {
    local name="$1" token="$2" have="$3" online="$4" want_exit="$5" want_writes="$6"
    shift 6
    : > "$WORK/calls"
    : > "$WORK/writes"
    printf '%b\n' "$online" > "$WORK/online"
    : > "$WORK/summary"
    local code
    env WORK="$WORK" PATH="$WORK/bin:$PATH" GH_TOKEN="$token" ORG=latere-ai LABEL=linux-vm \
        FALLBACK=ubuntu-latest VARIABLE=CI_RUNNER_PRIVATE LOG_VARIABLE=CI_RUNNER_SWITCHES \
        LOG_LINES=200 SAMPLES=6 INTERVAL=0 BUSY_AFTER_MINUTES="$BUSY" CLEAR_BELOW_MINUTES="$CLEAR" \
        NOW="$NOW" STUB_HAVE="$have" GITHUB_STEP_SUMMARY="$WORK/summary" "$@" \
        bash "$WORK/script.sh" > "$WORK/out" 2>&1
    code=$?
    local writes
    writes=$(sed 's/: .*//' "$WORK/writes" | tr '\n' '|' | sed 's/|$//')
    if [ "$code" = "$want_exit" ] && [ "$writes" = "$want_writes" ]; then
        pass "$name"
    else
        fail "$name: exit=$code writes='$writes', want exit=$want_exit writes='$want_writes'"
        sed 's/^/      /' "$WORK/out"
    fi
}
fresh() {
    rm -f "$WORK"/runs/*.json "$WORK"/jobs/*.json
    repos
    printf '%s\n' "# moves of CI_RUNNER_PRIVATE, oldest first" > "$WORK/log"
}
queue_reads() { grep -c 'actions/runs' "$WORK/calls"; }
last_has() { tail -n 1 "$WORK/log" | grep -qF "$1"; }
not() { ! "$@"; }
expect() { # name command...
    local name=$1
    shift
    if "$@"; then pass "$name"; else fail "$name"; sed 's/^/      /' "$WORK/out"; fi
}

echo "the script against a stub gh"

fresh
run_case "no token: warns, looks at nothing, writes nothing" "" linux-vm "1" 0 ""
expect "  and calls no API" test ! -s "$WORK/calls"

fresh
run_case "online and nothing queued keeps linux-vm" t linux-vm "1" 0 ""
expect "  and says why in the summary" grep -qF "stays linux-vm. clear: 1 runner(s) online" "$WORK/summary"

fresh
queue alpha queued 11 "queued:linux-vm:40"
run_case "offline on every look moves to ubuntu-latest" t linux-vm "0" 0 \
    "CI_RUNNER_PRIVATE=ubuntu-latest|CI_RUNNER_SWITCHES=$(ago 0) linux-vm -> ubuntu-latest"
expect "  and reads no queue, since offline wins" test "$(queue_reads)" = 0
expect "  and logs the offline rule" last_has "offline: no linux-vm runner online"

fresh
run_case "a gap of two looks moves nothing" t linux-vm "0\n0\n2" 0 ""

fresh
run_case "two runners online, one per page, count as online" t ubuntu-latest "0 1\n" 0 \
    "CI_RUNNER_PRIVATE=linux-vm|CI_RUNNER_SWITCHES=$(ago 0) ubuntu-latest -> linux-vm"

fresh
queue alpha queued 11 "queued:linux-vm:25"
queue beta queued 12 "queued:linux-vm:3"
run_case "online with a job queued 25 minutes moves to ubuntu-latest" t linux-vm "2" 0 \
    "CI_RUNNER_PRIVATE=ubuntu-latest|CI_RUNNER_SWITCHES=$(ago 0) linux-vm -> ubuntu-latest"
expect "  and logs the busy rule with the oldest wait" last_has "busy: the oldest queued linux-vm job has waited 25m, over 20m, with 2 runner(s) online"

fresh
queue alpha queued 11 "queued:linux-vm:10"
run_case "a 10-minute wait keeps linux-vm" t linux-vm "2" 0 ""

fresh
queue alpha queued 11 "queued:linux-vm:10"
run_case "a 10-minute wait keeps ubuntu-latest" t ubuntu-latest "2" 0 ""

fresh
printf '%s\n' "$(ago 34) linux-vm -> ubuntu-latest: busy: the oldest queued linux-vm job has waited 22m, over 20m, with 2 runner(s) online" >> "$WORK/log"
queue alpha queued 11 "queued:linux-vm:3"
run_case "a 3-minute wait moves back to linux-vm" t ubuntu-latest "2" 0 \
    "CI_RUNNER_PRIVATE=linux-vm|CI_RUNNER_SWITCHES=$(ago 0) ubuntu-latest -> linux-vm"
expect "  and logs how long ubuntu-latest held" last_has "clear: 2 runner(s) online and the oldest queued linux-vm job has waited 3m, 5m or less; ubuntu-latest held for 34m"
expect "  and keeps the earlier lines" test "$(grep -c . "$WORK/log")" = 3

fresh
queue alpha queued 11 "queued:ubuntu-latest:40" "completed:linux-vm:50" "in_progress:linux-vm:45"
run_case "hosted, finished and running jobs are not the queue" t linux-vm "2" 0 ""

fresh
queue alpha in_progress 13 "in_progress:linux-vm:30" "queued:linux-vm:30"
run_case "a queued job in a run in progress counts" t linux-vm "2" 0 \
    "CI_RUNNER_PRIVATE=ubuntu-latest|CI_RUNNER_SWITCHES=$(ago 0) linux-vm -> ubuntu-latest"

fresh
queue attic queued 14 "queued:linux-vm:30"
queue open queued 15 "queued:linux-vm:30"
run_case "archived and public repositories are not read" t linux-vm "2" 0 ""
expect "  and their runs are never listed" not grep -qE 'repos/latere-ai/(attic|open)/' "$WORK/calls"

fresh
run_case "a failed runners listing fails the run and writes nothing" t linux-vm "1" 1 "" STUB_LIST_FAIL=1

fresh
run_case "a failed queue read fails the run and writes nothing" t linux-vm "1" 1 "" STUB_QUEUE_FAIL=1

fresh
run_case "a failed variable read fails the run and writes nothing" t linux-vm "0" 1 "" STUB_READ_FAIL=1

fresh
run_case "a failed write fails the run and logs nothing" t linux-vm "0" 1 "" STUB_PATCH_FAIL=CI_RUNNER_PRIVATE

fresh
run_case "a move that cannot be logged fails the run" t linux-vm "0" 1 \
    "CI_RUNNER_PRIVATE=ubuntu-latest" STUB_PATCH_FAIL=CI_RUNNER_SWITCHES

fresh
for n in 1 2 3; do echo "$(ago $((60 - n))) ubuntu-latest -> linux-vm: clear: line $n" >> "$WORK/log"; done
run_case "the log keeps its newest lines" t linux-vm "0" 0 \
    "CI_RUNNER_PRIVATE=ubuntu-latest|CI_RUNNER_SWITCHES=$(ago 0) linux-vm -> ubuntu-latest" LOG_LINES=3
expect "  and keeps LOG_LINES lines" test "$(grep -c . "$WORK/log")" = 3
expect "  and drops the oldest" not grep -qE '^#|line 1' "$WORK/log"
expect "  and times linux-vm from the last move to it" last_has "linux-vm held for 57m"

echo "the decide function, evaluated"
# decide, cut out of the script by its definition and closing brace.
awk '/^decide\(\) \{$/ { on = 1 } on { print } on && /^\}$/ { exit }' "$WORK/script.sh" > "$WORK/decide.sh"
if ! grep -q '^decide() {$' "$WORK/decide.sh"; then
    fail "cannot cut decide out of the script"
else
    check_decide() { # want online oldest-seconds have
        local got
        got=$(env FALLBACK=ubuntu-latest LABEL=linux-vm VARIABLE=CI_RUNNER_PRIVATE \
            BUSY_AFTER_MINUTES="$BUSY" CLEAR_BELOW_MINUTES="$CLEAR" \
            bash -c '. "$1"; decide "$2" "$3" "$4"' _ "$WORK/decide.sh" "$2" "$3" "$4" | cut -f1)
        if [ "$got" = "$1" ]; then
            pass "online=$2 oldest=${3}s have=$4: $got"
        else
            fail "online=$2 oldest=${3}s have=$4: got $got, want $1"
        fi
    }
    check_decide ubuntu-latest 0 0    linux-vm
    check_decide ubuntu-latest 0 9999 ubuntu-latest
    check_decide ubuntu-latest 0 0    ubuntu-latest
    check_decide linux-vm      2 0    linux-vm
    check_decide linux-vm      2 0    ubuntu-latest
    check_decide linux-vm      1 300  ubuntu-latest
    check_decide ubuntu-latest 1 301  ubuntu-latest
    check_decide linux-vm      1 301  linux-vm
    check_decide linux-vm      1 1200 linux-vm
    check_decide ubuntu-latest 1 1200 ubuntu-latest
    check_decide ubuntu-latest 1 1201 linux-vm
    check_decide ubuntu-latest 2 7200 ubuntu-latest
    check_decide linux-vm      2 60   something-else
    check_decide something-else 2 600 something-else
fi

# The workflow must not run for a pull request, where a fork's change would
# run with the token, and must hold no permission of GITHUB_TOKEN's.
if awk '/^on:$/ { on = 1; next } on && /^[a-z]/ { exit } on' "$WORKFLOW" | grep -q 'pull_request'; then
    fail "runner-health.yml runs on a pull request"
else
    pass "runner-health.yml never runs on a pull request"
fi
if grep -qx 'permissions: {}' "$WORKFLOW"; then
    pass "runner-health.yml grants GITHUB_TOKEN nothing"
else
    fail "runner-health.yml grants GITHUB_TOKEN permissions it does not use"
fi

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
