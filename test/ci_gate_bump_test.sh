#!/usr/bin/env bash
#
# Unit tests for ci-gate-bump.yml's steps.
#
# The workflow decides whether a repository's ci-gate pin is behind, moves it,
# runs the bar, and then either pushes the pin and dispatches the per-push gate
# on the new commit, or opens an issue naming what failed. Each decision is
# inline shell, cut out of the workflow here and run against a stub go, a stub
# curl that records every API call, and, for the push, real git against a
# local bare repository, so the rebase and the replay after a conflict run for
# real.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/ci-gate-bump.yml"
EXAMPLE="$REPO_ROOT/examples/ci-gate-bump.yml"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

for tool in jq git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "  SKIP $tool is not installed; the runners have it"
        exit 0
    fi
done

# The shell under test is the workflow's own: each step's `run: |` block is
# cut out of ci-gate-bump.yml, so nothing here can drift from what ships.
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

PIN_SCRIPT=$(step_script "Read the pin")
CLOSE_SCRIPT=$(step_script "Close the issues the pin has resolved")
MOVE_SCRIPT=$(step_script "Move the pin")
PLAN_SCRIPT=$(step_script "Read the plan")
BAR_SCRIPT=$(step_script "Run the bar")
PUSH_SCRIPT=$(step_script "Push the pin")
DISPATCH_SCRIPT=$(step_script "Run the per-push gate on the new commit")
ISSUE_SCRIPT=$(step_script "Open or update the issue")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/stub"
mkdir -p "$STUB"

# The stub go. Module queries answer from PIN_* variables; `get` and `mod`
# edit GOMOD_FILE the way the real commands would; `tool lateregate` answers
# the plan from PLAN and records every gate it runs with the TMPDIR it saw,
# failing the gates named in FAIL.
cat > "$STUB/go" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "list -m")
        if [ "$3" = -u ]; then
            [ -n "${PIN_LIST_FAIL:-}" ] && { echo "go: $PIN_LIST_FAIL" >&2; exit 1; }
            printf '%s %s\n' "$PIN_CURRENT" "${PIN_UPDATE:-}"
            exit 0
        fi
        [ -n "${PIN_LATEST_FAIL:-}" ] && { echo "go: $PIN_LATEST_FAIL" >&2; exit 1; }
        printf '%s\n' "$PIN_LATEST"
        exit 0 ;;
    "get -tool")
        echo "go get $3" >> "$CALLS"
        [ -n "${GET_FAIL:-}" ] && { echo "go: $GET_FAIL" >&2; exit 1; }
        version=${3##*@}
        sed "s|latere.ai/x/ci-gate v[^ ]*|latere.ai/x/ci-gate $version|" go.mod > go.mod.new && mv go.mod.new go.mod
        [ -n "${RAISE_GO:-}" ] && { sed "s|^go .*|go $RAISE_GO|" go.mod > go.mod.new && mv go.mod.new go.mod; }
        echo "go: upgraded latere.ai/x/ci-gate => $version"
        exit 0 ;;
    "mod tidy")
        echo "go mod tidy" >> "$CALLS"
        exit 0 ;;
    "mod edit")
        printf '{"Go":"%s","Toolchain":null}\n' "$(sed -n 's/^go //p' go.mod)"
        exit 0 ;;
    "tool lateregate")
        if [ "$3" = list ]; then
            [ -n "${PLAN_FAIL:-}" ] && { echo "lateregate: $PLAN_FAIL" >&2; exit 1; }
            printf '%s\n' "$PLAN"
            exit 0
        fi
        echo "$3 TMPDIR=${TMPDIR:-}" >> "$CALLS"
        echo "output of $3"
        case " ${FAIL:-} " in *" $3 "*) echo "FAIL $3: it failed"; exit 1 ;; esac
        exit 0 ;;
esac
echo "stub go: unexpected: $*" >&2
exit 2
EOF

# The stub curl records "METHOD path data" and answers the issue list from
# ISSUES_JSON and an issue create with number 7.
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
method=GET; url=""; data=""
while [ $# -gt 0 ]; do
    case "$1" in
        -X) method=$2; shift 2 ;;
        --data) data=$2; shift 2 ;;
        -H) shift 2 ;;
        http*) url=$1; shift ;;
        *) shift ;;
    esac
done
path=${url#"$GITHUB_API_URL/"}
printf '%s %s %s\n' "$method" "$path" "$data" >> "$CALLS"
case "$method $path" in
    "GET repos/"*"/issues?"*) printf '%s' "${ISSUES_JSON:-[]}" ;;
    "POST repos/"*"/issues") printf '{"number": 7}' ;;
    *) printf '{}' ;;
esac
EOF

# The push waits between attempts; the tests do not.
printf '#!/bin/sh\nexit 0\n' > "$STUB/sleep"
chmod +x "$STUB/go" "$STUB/curl" "$STUB/sleep"

export GITHUB_API_URL=https://api.github.test
export GITHUB_SERVER_URL=https://github.test
export GITHUB_REPOSITORY=latere-ai/example
export GH_TOKEN=token

# run_step script dir [VAR=value ...]: runs a step in dir with the stubs first
# on PATH and fresh GITHUB_OUTPUT, GITHUB_STEP_SUMMARY and CALLS files. The
# exit status, the outputs and the calls land in $TMP/status, out and calls.
run_step() {
    script="$1"; dir="$2"; shift 2
    : > "$TMP/out"; : > "$TMP/summary"; : > "$TMP/calls"
    (
        cd "$dir" || exit 99
        env "$@" GITHUB_OUTPUT="$TMP/out" GITHUB_STEP_SUMMARY="$TMP/summary" CALLS="$TMP/calls" \
            RUNNER_TEMP="$TMP/runner" PATH="$STUB:$PATH" bash -c "$script"
    ) > "$TMP/log" 2>&1
    echo $? > "$TMP/status"
}
output() { sed -n "s/^$1=//p" "$TMP/out"; }
status() { cat "$TMP/status"; }
mkdir -p "$TMP/runner"

# ---------------------------------------------------------------------------
echo "read the pin"

pin_case() { # name current update latest latest_fail want_status want_latest
    run_step "$PIN_SCRIPT" "$TMP" PIN_CURRENT="$2" PIN_UPDATE="$3" PIN_LATEST="$4" PIN_LATEST_FAIL="$5"
    if [ "$(status)" = "$6" ] && [ "$(output latest)" = "$7" ]; then
        pass "$1"
    else
        fail "$1: status=$(status) latest=$(output latest), want status=$6 latest=$7; log: $(cat "$TMP/log")"
    fi
}

pin_case "a current pin sets no latest, so the bump job does not run" \
    v0.50.1 "" v0.50.1 "" 0 ""
pin_case "a pin behind the latest release names the release to try" \
    v0.45.0 v0.50.1 v0.50.1 "" 0 v0.50.1
pin_case "a pin ahead of the latest release is not moved back" \
    v0.51.0-rc.1 "" v0.50.1 "" 0 ""
pin_case "a proxy that does not answer fails the check instead of reading as current" \
    v0.45.0 "" "" "module lookup disabled by GOPROXY=off" 1 ""
pin_case "an answer that is not a release version fails the check" \
    v0.45.0 'v1.0.0;rm' v1.0.0 "" 1 ""

run_step "$PIN_SCRIPT" "$TMP" PIN_CURRENT=v0.45.0 PIN_UPDATE="" PIN_LATEST=v0.50.1 PIN_LIST_FAIL="not a known dependency"
if [ "$(status)" != 0 ]; then
    pass "a repository that pins no ci-gate fails the check"
else
    fail "a repository that pins no ci-gate passed the check"
fi

run_step "$PIN_SCRIPT" "$TMP" PIN_CURRENT=v0.49.0 PIN_UPDATE=v0.50.1 PIN_LATEST=v0.50.1
if [ "$(output current)" = v0.49.0 ] && grep -q 'v0.50.1 is out' "$TMP/summary"; then
    pass "the pin and the release to try reach the output and the summary"
else
    fail "outputs: $(cat "$TMP/out"); summary: $(cat "$TMP/summary")"
fi

# ---------------------------------------------------------------------------
echo "close the issues the pin has resolved"

ISSUES='[
  {"number": 1, "title": "ci-gate v0.49.0 does not pass the gate"},
  {"number": 2, "title": "ci-gate v0.51.0 does not pass the gate"},
  {"number": 3, "title": "ci-gate v0.9.0 does not pass the gate"},
  {"number": 4, "title": "something else entirely"},
  {"number": 5, "title": "ci-gate v0.48.0 does not pass the gate", "pull_request": {}},
  {"number": 6, "title": "ci-gate v0.50.1 does not pass the gate"}
]'
run_step "$CLOSE_SCRIPT" "$TMP" CURRENT=v0.50.1 ISSUES_JSON="$ISSUES"
closed=$(sed -n 's|^PATCH repos/latere-ai/example/issues/\([0-9]*\) .*"closed".*|\1|p' "$TMP/calls" | tr '\n' ' ')
commented=$(sed -n 's|^POST repos/latere-ai/example/issues/\([0-9]*\)/comments .*|\1|p' "$TMP/calls" | tr '\n' ' ')
if [ "$(status)" = 0 ] && [ "$closed" = "1 3 6 " ] && [ "$commented" = "1 3 6 " ]; then
    pass "issues for versions the pin has reached are commented on and closed, newer ones and others kept"
else
    fail "closed=[$closed] commented=[$commented] status=$(status), want 1 3 6; log: $(cat "$TMP/log")"
fi
if head -n 1 "$TMP/calls" | grep -q '^GET repos/latere-ai/example/issues?state=open&creator=github-actions%5Bbot%5D'; then
    pass "only open issues this workflow's bot opened are read"
else
    fail "the issue list query is $(head -n 1 "$TMP/calls")"
fi

run_step "$CLOSE_SCRIPT" "$TMP" CURRENT=v0.50.1 ISSUES_JSON='[]'
if [ "$(status)" = 0 ] && [ "$(wc -l < "$TMP/calls" | tr -d ' ')" = 1 ]; then
    pass "no open issue costs one read and nothing else"
else
    fail "status=$(status) calls=$(cat "$TMP/calls")"
fi

# ---------------------------------------------------------------------------
echo "move the pin"

new_module() { # dir
    rm -rf "$1"; mkdir -p "$1"
    printf 'module example.test/m\n\ngo 1.27.0\n\nrequire latere.ai/x/ci-gate v0.45.0 // indirect\n\ntool latere.ai/x/ci-gate/cmd/lateregate\n' > "$1/go.mod"
    : > "$1/go.sum"
    git -C "$1" init -q
    git -C "$1" add go.mod go.sum
    git -C "$1" -c user.name=t -c user.email=t@t commit -q -m init
}

logs="$TMP/runner/ci-gate-bump"
new_module "$TMP/m"
run_step "$MOVE_SCRIPT" "$TMP/m" LATEST=v0.50.1
if [ "$(status)" = 0 ] && [ "$(output moved)" = true ] && [ ! -e "$logs/failed" ] \
    && grep -q 'latere.ai/x/ci-gate v0.50.1' "$TMP/m/go.mod" \
    && [ "$(cat "$TMP/calls")" = "$(printf 'go get latere.ai/x/ci-gate/cmd/lateregate@v0.50.1\ngo mod tidy')" ]; then
    pass "the tool directive moves to the release and go.mod is tidied"
else
    fail "status=$(status) out=$(cat "$TMP/out") calls=$(cat "$TMP/calls"); log: $(cat "$TMP/log")"
fi

rm -rf "$logs"; new_module "$TMP/m"
run_step "$MOVE_SCRIPT" "$TMP/m" LATEST=v0.50.1 GET_FAIL="latere.ai/x/ci-gate@v0.50.1: invalid version"
if [ "$(status)" = 0 ] && [ "$(output failed)" = true ] && [ -z "$(output moved)" ] \
    && [ "$(cat "$logs/failed")" = pin ] && grep -q 'invalid version' "$logs/pin.log"; then
    pass "a release go get cannot take is a finding with its output, not a moved pin"
else
    fail "status=$(status) out=$(cat "$TMP/out") failed=$(cat "$logs/failed" 2>/dev/null)"
fi

rm -rf "$logs"; new_module "$TMP/m"
run_step "$MOVE_SCRIPT" "$TMP/m" LATEST=v0.50.1 RAISE_GO=1.28.0
if [ "$(status)" = 0 ] && [ "$(output failed)" = true ] && [ -z "$(output moved)" ] \
    && [ "$(cat "$logs/failed")" = pin ] && grep -q 'from go 1.27.0, toolchain none to go 1.28.0, toolchain none' "$logs/pin.log"; then
    pass "a release that raises the go directive is reported, not pushed"
else
    fail "status=$(status) out=$(cat "$TMP/out") log=$(cat "$logs/pin.log" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
echo "read the plan"

plan_case() { # name plan plan_fail want_gates want_enum want_failed
    rm -rf "$logs"; mkdir -p "$logs"
    run_step "$PLAN_SCRIPT" "$TMP" LOGS="$logs" PLAN="$2" PLAN_FAIL="$3"
    got_failed=$(cat "$logs/failed" 2>/dev/null)
    if [ "$(status)" = 0 ] && [ "$(output gates)" = "$4" ] && [ "$(output enum_typescript)" = "$5" ] && [ "$got_failed" = "$6" ]; then
        pass "$1"
    else
        fail "$1: status=$(status) gates=$(output gates) enum=$(output enum_typescript) failed=$got_failed, want gates=$4 enum=$5 failed=$6"
    fi
}

plan_case "every running gate is in the bar, test included, and nothing skipped, waived or folded" \
    '[{"name":"fmt-check","status":"run"},{"name":"spec-lint","status":"skip","reason":"no specs"},{"name":"cover","status":"waived","reason":"r","until":"2026-12-01"},{"name":"test","status":"run"},{"name":"race","status":"folded","into":"suite"}]' \
    "" '["fmt-check","test"]' false ""
plan_case "a running TypeScript enum gate asks for its runtimes" \
    '[{"name":"enum-go","status":"run"},{"name":"enum-typescript","status":"run"}]' \
    "" '["enum-go","enum-typescript"]' true ""
plan_case "a waived TypeScript enum gate installs nothing" \
    '[{"name":"enum-typescript","status":"waived","reason":"r","until":"2026-12-01"}]' \
    "" '[]' false ""
plan_case "a release that cannot read the repository's configuration is a finding" \
    '[]' "unknown key waive.foo" "" "" plan

# ---------------------------------------------------------------------------
echo "run the bar"

bar_case() { # name gates fail want_calls want_passed want_failed
    rm -rf "$logs"; mkdir -p "$logs"
    run_step "$BAR_SCRIPT" "$TMP" LOGS="$logs" GATES="$2" FAIL="$3" LATEST=v0.50.1 TMPDIR=/tmp
    got_calls=$(tr '\n' ';' < "$TMP/calls")
    got_failed=$(cat "$logs/failed" 2>/dev/null | tr '\n' ' ')
    if [ "$(status)" = 0 ] && [ "$got_calls" = "$4" ] && [ "$(output passed)" = "$5" ] && [ "$got_failed" = "$6" ]; then
        pass "$1"
    else
        fail "$1: status=$(status) calls=$got_calls passed=$(output passed) failed=[$got_failed], want calls=$4 passed=$5 failed=[$6]"
    fi
}

bar_case "every gate runs, then the wiring check, and a clean bar passes" \
    '["fmt-check","suite"]' "" \
    "fmt-check TMPDIR=/tmp;suite TMPDIR=/tmp;contract TMPDIR=/tmp;" true ""
bar_case "lint alone runs under the runner process's own TMPDIR" \
    '["lint","vuln"]' "" \
    "lint TMPDIR=$TMP/runner;vuln TMPDIR=/tmp;contract TMPDIR=/tmp;" true ""
bar_case "a failing gate does not stop the rest, and every failure is listed" \
    '["fmt-check","lint","suite"]' "fmt-check suite" \
    "fmt-check TMPDIR=/tmp;lint TMPDIR=$TMP/runner;suite TMPDIR=/tmp;contract TMPDIR=/tmp;" "" "fmt-check suite "
bar_case "the wiring check fails the bar on its own" \
    '["fmt-check"]' "contract" \
    "fmt-check TMPDIR=/tmp;contract TMPDIR=/tmp;" "" "contract "

if grep -q 'output of contract' "$logs/contract.log" && grep -q '^FAIL contract: it failed$' "$logs/contract.log"; then
    pass "each gate's output is kept for the issue"
else
    fail "no log for the contract gate in $logs"
fi

# ---------------------------------------------------------------------------
echo "push the pin"

# A bare origin whose main holds a module at v0.45.0, and a shallow clone of
# it with the pin already moved, as the job leaves the tree after the bar.
new_origin() {
    rm -rf "$TMP/origin.git" "$TMP/seed" "$TMP/work" "$TMP/other"
    git init -q --bare -b main "$TMP/origin.git" 2>/dev/null || { git init -q --bare "$TMP/origin.git"; git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/main; }
    new_module "$TMP/seed"
    printf 'first\n' > "$TMP/seed/README"
    git -C "$TMP/seed" add README
    git -C "$TMP/seed" -c user.name=t -c user.email=t@t commit -q -m readme
    git -C "$TMP/seed" push -q "$TMP/origin.git" HEAD:refs/heads/main
    git clone -q --depth 1 --branch main "file://$TMP/origin.git" "$TMP/work" 2>/dev/null
    sed 's|ci-gate v0.45.0|ci-gate v0.50.1|' "$TMP/work/go.mod" > "$TMP/work/go.mod.new" && mv "$TMP/work/go.mod.new" "$TMP/work/go.mod"
    git clone -q "file://$TMP/origin.git" "$TMP/other" 2>/dev/null
}
# upstream file content message: a commit someone else pushes while the bar runs.
upstream() {
    printf '%s' "$2" > "$TMP/other/$1"
    git -C "$TMP/other" add "$1"
    git -C "$TMP/other" -c user.name=o -c user.email=o@o commit -q -m "$3"
    git -C "$TMP/other" push -q origin HEAD:main
}
remote_log() { git --git-dir="$TMP/origin.git" log --format='%s' main | tr '\n' ';'; }
remote_pin() { git --git-dir="$TMP/origin.git" show main:go.mod | sed -n 's/^require latere.ai\/x\/ci-gate \([^ ]*\).*/\1/p'; }

push_case() { # name want_status want_pushed want_log want_pin
    run_step "$PUSH_SCRIPT" "$TMP/work" LATEST=v0.50.1 CURRENT=v0.45.0 BRANCH=main
    if [ "$(status)" = "$2" ] && [ "$(output pushed)" = "$3" ] && [ "$(remote_log)" = "$4" ] && [ "$(remote_pin)" = "$5" ]; then
        pass "$1"
    else
        fail "$1: status=$(status) pushed=$(output pushed) log=$(remote_log) pin=$(remote_pin), want status=$2 pushed=$3 log=$4 pin=$5; output: $(cat "$TMP/log")"
    fi
}

new_origin
push_case "the pin commit lands on the branch with the existing message style" \
    0 true "gate: ci-gate v0.50.1;readme;init;" v0.50.1
if [ "$(git --git-dir="$TMP/origin.git" log -1 --format='%an <%ae>' main)" = "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>" ]; then
    pass "the commit is the Actions bot's"
else
    fail "the commit author is $(git --git-dir="$TMP/origin.git" log -1 --format='%an <%ae>' main)"
fi
if git -C "$TMP/work" config --get-regexp 'extraheader' >/dev/null; then
    fail "the token was written into the checkout's git config"
else
    pass "the token reaches git for the push only, not the checkout's config"
fi

new_origin
upstream README "moved\n" "docs: a push while the bar ran"
push_case "a branch that moved while the bar ran is rebased onto, and the pin lands on top" \
    0 true "gate: ci-gate v0.50.1;docs: a push while the bar ran;readme;init;" v0.50.1

new_origin
sed 's|ci-gate v0.45.0 // indirect|ci-gate v0.49.0 // indirect|' "$TMP/other/go.mod" > "$TMP/other/go.mod.new"
upstream go.mod "$(cat "$TMP/other/go.mod.new")
" "gate: ci-gate v0.49.0"
push_case "a conflict in go.mod takes the new tip and moves the pin again on it" \
    0 true "gate: ci-gate v0.50.1;gate: ci-gate v0.49.0;readme;init;" v0.50.1

new_origin
cp "$TMP/work/go.mod" "$TMP/other/go.mod"
upstream go.mod "$(cat "$TMP/work/go.mod")
" "gate: ci-gate v0.50.1 by hand"
push_case "a branch that already pins the release gets no second commit and no dispatch" \
    0 "" "gate: ci-gate v0.50.1 by hand;readme;init;" v0.50.1

new_origin
printf '#!/bin/sh\nexit 1\n' > "$TMP/origin.git/hooks/pre-receive" && chmod +x "$TMP/origin.git/hooks/pre-receive"
push_case "a push rejected every time fails the run after three attempts" \
    1 "" "readme;init;" v0.45.0
if [ "$(grep -c '^ ! \[remote rejected\]' "$TMP/log")" = 3 ]; then
    pass "the push is attempted three times"
else
    fail "the push was attempted $(grep -c '^ ! \[remote rejected\]' "$TMP/log") times, want 3"
fi

# ---------------------------------------------------------------------------
echo "dispatch the per-push gate"

new_workflows() { # dir: a repository with the per-push caller and this bump caller
    rm -rf "$1"; mkdir -p "$1/.github/workflows"
    cp "$EXAMPLE" "$1/.github/workflows/ci-gate-bump.yml"
}
caller() { # file dispatchable
    {
        printf 'name: ci\non:\n  push:\n    branches: [main]\n  pull_request:\n'
        [ "$2" = yes ] && printf '  workflow_dispatch:\n'
        printf 'jobs:\n  gate:\n    uses: latere-ai/ci/.github/workflows/lateregate.yml@v1\n'
    } > "$1"
}

new_workflows "$TMP/r"; caller "$TMP/r/.github/workflows/ci.yml" yes
run_step "$DISPATCH_SCRIPT" "$TMP/r" BRANCH=main
if [ "$(status)" = 0 ] && [ "$(cat "$TMP/calls")" = 'POST repos/latere-ai/example/actions/workflows/ci.yml/dispatches {"ref":"main"}' ]; then
    pass "the one per-push caller is dispatched on the branch, beside this workflow's own caller"
else
    fail "status=$(status) calls=$(cat "$TMP/calls"); log: $(cat "$TMP/log")"
fi

new_workflows "$TMP/r"; caller "$TMP/r/.github/workflows/ci.yaml" yes
run_step "$DISPATCH_SCRIPT" "$TMP/r" BRANCH=main
if [ "$(status)" = 0 ] && grep -q 'actions/workflows/ci.yaml/dispatches' "$TMP/calls"; then
    pass "a caller named .yaml is found"
else
    fail "status=$(status) calls=$(cat "$TMP/calls")"
fi

new_workflows "$TMP/r"; caller "$TMP/r/.github/workflows/verify.yml" no
run_step "$DISPATCH_SCRIPT" "$TMP/r" BRANCH=main
if [ "$(status)" = 1 ] && [ ! -s "$TMP/calls" ] && grep -q 'verify.yml has no workflow_dispatch trigger' "$TMP/log"; then
    pass "a caller without workflow_dispatch fails naming the file and the fix"
else
    fail "status=$(status) calls=$(cat "$TMP/calls"); log: $(cat "$TMP/log")"
fi

new_workflows "$TMP/r"; caller "$TMP/r/.github/workflows/ci.yml" yes; caller "$TMP/r/.github/workflows/other.yml" yes
run_step "$DISPATCH_SCRIPT" "$TMP/r" BRANCH=main
if [ "$(status)" = 1 ] && [ ! -s "$TMP/calls" ]; then
    pass "two per-push callers are refused rather than guessed between"
else
    fail "status=$(status) calls=$(cat "$TMP/calls")"
fi

# ---------------------------------------------------------------------------
echo "open or update the issue"

issue_setup() { # failed-names...
    rm -rf "$logs"; mkdir -p "$logs"
    for n in "$@"; do
        echo "$n" >> "$logs/failed"
        printf 'output of %s\nFAIL %s: it failed\n' "$n" "$n" > "$logs/$n.log"
    done
}
issue_body() { sed -n 's|^[A-Z]* repos/latere-ai/example/issues[/0-9]* ||p' "$TMP/calls" | tail -n 1 | jq -r .body; }

issue_setup lint suite
run_step "$ISSUE_SCRIPT" "$TMP" LOGS="$logs" LATEST=v0.50.1 CURRENT=v0.49.0 RUN_URL=https://github.test/run/1 ISSUES_JSON='[]'
if [ "$(status)" = 0 ] && grep -q '^POST repos/latere-ai/example/issues {"title":"ci-gate v0.50.1 does not pass the gate"' "$TMP/calls"; then
    pass "a new failing release opens one issue titled for its version"
else
    fail "status=$(status) calls=$(cat "$TMP/calls"); log: $(cat "$TMP/log")"
fi
body=$(issue_body)
if printf '%s' "$body" | grep -q '`lint`, `suite`' \
    && printf '%s' "$body" | grep -q 'The pin stays at v0.49.0' \
    && printf '%s' "$body" | grep -q 'https://github.test/run/1' \
    && printf '%s' "$body" | grep -q 'go get -tool latere.ai/x/ci-gate/cmd/lateregate@v0.50.1' \
    && printf '%s' "$body" | grep -q '<summary>go tool lateregate suite</summary>' \
    && printf '%s' "$body" | grep -q 'FAIL suite: it failed'; then
    pass "the body names the failing gates, the pin, the run, the reproduction and each gate's output"
else
    fail "the body is: $body"
fi
if grep -q '^::warning title=ci-gate v0.50.1 does not pass::`lint`, `suite`; opened https://github.test/latere-ai/example/issues/7$' "$TMP/log"; then
    pass "the run carries a warning linking the issue, and stays green"
else
    fail "no warning linking the issue in: $(cat "$TMP/log")"
fi

issue_setup pin
existing='[{"number": 5, "state": "closed", "title": "ci-gate v0.50.1 does not pass the gate"}, {"number": 6, "state": "open", "title": "ci-gate v0.50.0 does not pass the gate"}]'
run_step "$ISSUE_SCRIPT" "$TMP" LOGS="$logs" LATEST=v0.50.1 CURRENT=v0.49.0 RUN_URL=https://github.test/run/2 ISSUES_JSON="$existing"
if [ "$(status)" = 0 ] && ! grep -q '^POST repos/latere-ai/example/issues ' "$TMP/calls" \
    && grep -q '^PATCH repos/latere-ai/example/issues/5 ' "$TMP/calls" \
    && ! grep -q '"state"' "$TMP/calls" \
    && issue_body | grep -q '<summary>moving the pin (go get, go mod tidy)</summary>'; then
    pass "the version's existing issue is updated, not duplicated, and one closed by hand stays closed"
else
    fail "status=$(status) calls=$(cat "$TMP/calls")"
fi

issue_setup suite lint
awk 'BEGIN { s = "a long gate output line"; for (i = 0; i < 4; i++) s = s s; for (i = 0; i < 5000; i++) printf "%d %s\n", i, s }' > "$logs/suite.log"
cp "$logs/suite.log" "$logs/lint.log"
echo "FAIL suite: the verdict at the end" >> "$logs/suite.log"
run_step "$ISSUE_SCRIPT" "$TMP" LOGS="$logs" LATEST=v0.50.1 CURRENT=v0.49.0 RUN_URL=u ISSUES_JSON='[]'
size=$(issue_body | wc -c | tr -d ' ')
if [ "$(status)" = 0 ] && [ "$size" -lt 65536 ] && issue_body | grep -q 'FAIL suite: the verdict at the end'; then
    pass "long logs keep their tails and the body stays under GitHub's limit ($size bytes)"
else
    fail "status=$(status) body size $size"
fi

# ---------------------------------------------------------------------------
echo "workflow and caller"

for s in PIN_SCRIPT CLOSE_SCRIPT MOVE_SCRIPT PLAN_SCRIPT BAR_SCRIPT PUSH_SCRIPT DISPATCH_SCRIPT ISSUE_SCRIPT; do
    eval "v=\$$s"
    if [ -n "$v" ]; then
        pass "$s was found in the workflow"
    else
        fail "$s was not found in the workflow"
    fi
done

# lateregate contract holds a repository to exactly one workflow naming the
# per-push pipeline, so the bump caller a repository copies must not.
if grep -qF 'latere-ai/ci/.github/workflows/lateregate.yml@' "$EXAMPLE"; then
    fail "examples/ci-gate-bump.yml names the per-push pipeline, which fails lateregate contract"
else
    pass "the caller does not name the per-push pipeline, so lateregate contract still finds one"
fi

for want in 'contents: write' 'issues: write' 'actions: write' 'workflow_dispatch:' '  schedule:' 'uses: latere-ai/ci/.github/workflows/ci-gate-bump.yml@v1'; do
    if grep -qF -- "$want" "$EXAMPLE"; then
        pass "the caller carries: $want"
    else
        fail "the caller lost: $want"
    fi
done

# Each step runs only on the path it belongs to.
step_if() {
    awk -v name="$1" '
        index($0, "- name: " name) && substr($0, length($0) - length(name) + 1) == name { instep = 1; next }
        instep && /^ +if: / { sub(/^ +if: /, ""); print; exit }
        instep && /^ +run: / { exit }
    ' "$WORKFLOW"
}
check_if() {
    if [ "$(step_if "$1")" = "$2" ]; then
        pass "\"$1\" runs on: $2"
    else
        fail "\"$1\" runs on: $(step_if "$1"), want $2"
    fi
}
check_if "Read the plan" "\${{ steps.move.outputs.moved == 'true' }}"
check_if "Run the bar" "\${{ steps.plan.outputs.ok == 'true' }}"
check_if "Push the pin" "\${{ steps.bar.outputs.passed == 'true' }}"
check_if "Run the per-push gate on the new commit" "\${{ steps.push.outputs.pushed == 'true' }}"
check_if "Open or update the issue" "\${{ steps.move.outputs.failed == 'true' || steps.plan.outputs.failed == 'true' || steps.bar.outputs.failed == 'true' }}"

if grep -qF "if: \${{ needs.check.outputs.latest != '' }}" "$WORKFLOW"; then
    pass "the bump job runs only when there is a release to try"
else
    fail "the bump job is not gated on the check's answer"
fi

if [ "$(grep -c 'persist-credentials: false' "$WORKFLOW")" = "$(grep -c 'uses: actions/checkout' "$WORKFLOW")" ]; then
    pass "no checkout leaves the token in .git/config"
else
    fail "a checkout persists the token"
fi

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
