#!/usr/bin/env bash
#
# Tests for actions/verified-commit/run.sh, the check that a release is cut
# from a commit its verify workflow passed. A stub gh serves the runs, the
# commits and the comparisons, so every branch of the decision runs against
# the shipped script.
#
# Kept bash 3.2 compatible.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/actions/verified-commit/run.sh"
# shellcheck source=stub_gh.sh
. "$REPO_ROOT/test/stub_gh.sh"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

REPO=latere-ai/svc
TAG=v1.2.0
SHA=aaaa
PARENT=bbbb
GRANDPARENT=cccc

runs_url() { echo "repos/$REPO/actions/workflows/verify.yml/runs?head_sha=$1&event=push&per_page=20"; }
# runs JSON from "branch:conclusion" pairs; conclusion null for a running run.
runs() {
    local out="" pair branch c
    for pair in "$@"; do
        branch=${pair%%:*}
        c=${pair#*:}
        [ "$c" = null ] || c="\"$c\""
        out="${out:+$out,}{\"head_branch\":\"$branch\",\"conclusion\":$c}"
    done
    echo "{\"workflow_runs\":[${out}]}"
}

# run_case NAME EXPECT_EXIT EXPECT_TEXT, with fixtures already in $W; extra
# environment through the caller's assignments.
W=""
new_case() {
    W=$(mktemp -d)
    stub_gh_install "$W"
}
run_case() {
    local name=$1 want=$2 text=$3 out rc
    out=$(cd "${CHECKOUT:-$W}" && PATH="$W/bin:$PATH" STUB_GH_DIR="$W" GITHUB_REPOSITORY=$REPO GITHUB_SHA=$SHA \
        GITHUB_REF_NAME=$TAG GITHUB_RUN_ID=42 POLL_SECONDS=0 \
        VERIFY_WORKFLOW=${VERIFY-verify.yml} WAIT_MINUTES=${WAIT:-60} bash "$SCRIPT" 2>&1)
    rc=$?
    if [ "$rc" -eq "$want" ] && printf '%s' "$out" | grep -qF -- "$text"; then
        pass "$name"
    else
        fail "$name (exit $rc, want $want; output: $out)"
    fi
    rm -rf "$W"
}

new_case
stub_gh_fixture "$W" "$(runs_url $SHA)" "$(runs main:success)"
WAIT=60 run_case "a verify success on the commit's branch push releases" 0 "concluded success on $SHA"

new_case
stub_gh_fixture "$W" "$(runs_url $SHA)" "$(runs $TAG:success)"
stub_gh_fixture "$W" "repos/$REPO/commits/$SHA" "{\"parents\":[{\"sha\":\"$PARENT\"}]}"
stub_gh_fixture "$W" "repos/$REPO/compare/$PARENT...$SHA" '{"files":[{"filename":"main.go"}]}'
WAIT=0 run_case "the run of the tag's own push does not count" 1 "has no run on $SHA, which changes main.go"

new_case
stub_gh_fixture "$W" "$(runs_url $SHA)" "$(runs main:failure)"
WAIT=60 run_case "a failed verify refuses" 1 "concluded 'failure'"

new_case
stub_gh_fixture "$W" "$(runs_url $SHA)" "$(runs main:timed_out)"
WAIT=60 run_case "a timed-out verify refuses" 1 "concluded 'timed_out'"

new_case
stub_gh_fixture "$W" "$(runs_url $SHA)" "$(runs main:null)" 1
stub_gh_fixture "$W" "$(runs_url $SHA)" "$(runs main:null)" 2
stub_gh_fixture "$W" "$(runs_url $SHA)" "$(runs main:success)"
WAIT=60 run_case "a running verify is waited for" 0 "concluded success"

new_case
stub_gh_fixture "$W" "$(runs_url $SHA)" "$(runs main:null)"
WAIT=0 run_case "wait_minutes 0 refuses a running verify with the re-run command" 1 "gh run rerun 42 --failed --repo $REPO"

new_case
stub_gh_fixture "$W" "$(runs_url $SHA)" "$(runs main:cancelled)"
WAIT=60 run_case "a cancelled verify refuses: the commit was never verified" 1 "was cancelled on $SHA"

new_case
stub_gh_fixture "$W" "$(runs_url $SHA)" "$(runs main:cancelled main:success)"
WAIT=60 run_case "a re-run that succeeded after a cancel releases" 0 "concluded success"

new_case
stub_gh_fixture "$W" "$(runs_url $SHA)" "$(runs main:cancelled main:null)"
WAIT=0 run_case "a re-run still going after a cancel counts as running" 1 "has not concluded"

new_case
stub_gh_fixture "$W" "$(runs_url $SHA)" '{"workflow_runs":[]}'
stub_gh_fixture "$W" "repos/$REPO/commits/$SHA" "{\"parents\":[{\"sha\":\"$PARENT\"}]}"
stub_gh_fixture "$W" "repos/$REPO/compare/$PARENT...$SHA" '{"files":[{"filename":"specs/012-x.md"},{"filename":"README.md"}]}'
stub_gh_fixture "$W" "$(runs_url $PARENT)" "$(runs main:success)"
WAIT=0 run_case "a commit verify skipped is read through to its parent" 0 "concluded success on $PARENT"

new_case
stub_gh_fixture "$W" "$(runs_url $SHA)" '{"workflow_runs":[]}'
stub_gh_fixture "$W" "repos/$REPO/commits/$SHA" "{\"parents\":[{\"sha\":\"$PARENT\"}]}"
stub_gh_fixture "$W" "repos/$REPO/compare/$PARENT...$SHA" '{"files":[{"filename":"docs/install.md"}]}'
stub_gh_fixture "$W" "$(runs_url $PARENT)" '{"workflow_runs":[]}'
stub_gh_fixture "$W" "repos/$REPO/commits/$PARENT" "{\"parents\":[{\"sha\":\"$GRANDPARENT\"}]}"
stub_gh_fixture "$W" "repos/$REPO/compare/$GRANDPARENT...$PARENT" '{"files":[{"filename":"specs/a.md"}]}'
stub_gh_fixture "$W" "$(runs_url $GRANDPARENT)" "$(runs main:failure)"
WAIT=0 run_case "the walk stops at the first commit verify ran on" 1 "on $GRANDPARENT"

new_case
stub_gh_fixture "$W" "$(runs_url $SHA)" '{"workflow_runs":[]}'
stub_gh_fixture "$W" "repos/$REPO/commits/$SHA" '{"parents":[]}'
WAIT=0 run_case "the first commit with no run refuses" 1 "the first commit"

new_case
stub_gh_fixture "$W" "$(runs_url $SHA)" FAIL
WAIT=60 run_case "an API error refuses rather than reading as no run" 1 "cannot read the verify.yml runs of $SHA"

new_case
WAIT=soon run_case "a wait that is not a number of minutes refuses" 1 "takes a whole number of minutes"

# An empty verify_workflow takes the workflow that calls lateregate.yml.
gate_checkout() {
    CHECKOUT=$(mktemp -d)
    mkdir -p "$CHECKOUT/.github/workflows"
    printf 'on: push\n' > "$CHECKOUT/.github/workflows/release.yaml"
    local f
    for f in "$@"; do
        printf 'jobs:\n  verify:\n    uses: latere-ai/ci/.github/workflows/lateregate.yml@v1\n' > "$CHECKOUT/.github/workflows/$f"
    done
}
new_case
gate_checkout ci.yaml
stub_gh_fixture "$W" "repos/$REPO/actions/workflows/ci.yaml/runs?head_sha=$SHA&event=push&per_page=20" "$(runs main:success)"
VERIFY="" run_case "an empty verify_workflow takes the workflow that runs the gate" 0 "ci.yaml concluded success"
rm -rf "$CHECKOUT"

new_case
gate_checkout
VERIFY="" run_case "no workflow running the gate refuses" 1 "no workflow in .github/workflows calls"
rm -rf "$CHECKOUT"

new_case
gate_checkout ci.yml verify.yml
VERIFY="" run_case "two workflows running the gate refuse" 1 "more than one workflow"
rm -rf "$CHECKOUT"
unset CHECKOUT

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
