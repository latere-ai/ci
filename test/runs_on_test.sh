#!/usr/bin/env bash
#
# The runner contract, across every reusable workflow rather than one at a
# time. The organization's policy decides where a job runs: a private
# repository on the self-hosted runner, falling back to a hosted one while
# that runner is offline; a public repository on a hosted runner, falling
# back to the self-hosted one only for events the repository itself starts.
# Each reusable workflow carries that policy as its runs_on default, and
# every job follows runs_on, so a caller that passes nothing gets the policy
# and its fallback, and one line on the caller still overrides both.
#
# The policy is one expression over two organization variables:
# CI_RUNNER_PRIVATE, visible to private repositories only, and
# CI_RUNNER_PUBLIC, visible to all. A public repository reads the first as
# empty, so the visibility of the variable is what tells the two kinds of
# repository apart, on every event, including a schedule whose payload
# carries no repository. The README prints the same expression for a
# repository's own jobs, so this suite holds the README to it too.
#
# A matrix job is the exception. `test_os` names its runners; empty means
# the runner runs_on resolves to.
#
# The cost of following runs_on: actions/setup-go restores the module cache
# as a tarball, which is right on a hosted runner (it starts empty) and fails
# file by file on a self-hosted one (it keeps its own cache between jobs).
# So every setup-go under a runs_on label gates the restore on a hosted label
# or turns it off.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS="$REPO_ROOT/.github/workflows"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# The policy, byte for byte. Changing it means changing this line, every
# reusable workflow, and the README together.
POLICY="\${{ (github.event.repository.private || contains(fromJSON('[\"push\",\"schedule\",\"workflow_dispatch\",\"release\"]'), github.event_name)) && (vars.CI_RUNNER_PRIVATE || vars.CI_RUNNER_PUBLIC) || 'ubuntu-latest' }}"
TEST_OS_USE="inputs.test_os || format('[\"{0}\"]', inputs.runs_on)"

# A reusable workflow is one a consumer can call. The repo's own workflows
# (actionlint, test, major-tag, release, runner-health) run here and keep a
# fixed runner.
reusable() { grep -l '^  workflow_call:$' "$WORKFLOWS"/*.yml; }

# Job keys only: the `on:` block also has two-space keys.
count_jobs() { awk '/^jobs:$/ { injobs = 1; next } injobs && /^  [a-z0-9_-]+:$/ { n++ } END { print n + 0 }' "$1"; }

files=$(reusable)
if [ -z "$files" ]; then
    fail "no reusable workflow found; the detection is wrong"
    printf "\n1 failure(s)\n"
    exit 1
fi

for f in $files; do
    name=$(basename "$f")

    # The input exists, is a string, and defaults to the policy, so a caller
    # that says nothing runs where the policy says and falls back with it.
    decl=$(awk '/^      runs_on:$/ { inblk = 1 } inblk { print } inblk && /^        default:/ { exit }' "$f")
    if printf '%s\n' "$decl" | grep -q 'type: string' \
        && printf '%s\n' "$decl" | grep -qxF "        default: $POLICY"; then
        pass "$name declares runs_on (string, default the runner policy)"
    else
        fail "$name has no runs_on input defaulting to the runner policy"
    fi

    # Every job follows either the input or its own matrix. Nothing is nailed
    # to a literal label.
    jobs=$(count_jobs "$f")
    routed=$(grep -cF 'runs-on: ${{ inputs.runs_on }}' "$f")
    matrixed=$(grep -cE 'runs-on: \$\{\{ matrix\.[a-z_]+ \}\}' "$f")
    literal=$(grep -cE '^\s+runs-on: [a-z]' "$f")
    if [ "$literal" -eq 0 ] && [ $((routed + matrixed)) -eq "$jobs" ]; then
        pass "$name routes every job ($jobs total: $routed by runs_on, $matrixed by matrix)"
    else
        fail "$name leaves a job off runs_on (jobs=$jobs runs_on=$routed matrix=$matrixed literal=$literal)"
    fi

    # test_os, where there is one, defaults to empty and is read only through
    # the fallback to runs_on, so the matrix moves with the policy.
    if grep -q '^      test_os:$' "$f"; then
        tdecl=$(awk '/^      test_os:$/ { inblk = 1 } inblk { print } inblk && /^        default:/ { exit }' "$f")
        uses=$(grep -c 'inputs\.test_os' "$f")
        through=$(grep -cF "$TEST_OS_USE" "$f")
        if printf '%s\n' "$tdecl" | grep -qxF '        default: ""' && [ "$uses" -gt 0 ] && [ "$uses" -eq "$through" ]; then
            pass "$name reads test_os through the runs_on fallback ($uses use(s))"
        else
            fail "$name reads test_os without the runs_on fallback (uses=$uses through=$through)"
        fi
    fi

    # The module cache restore is a hosted-runner optimization and a
    # self-hosted-runner failure.
    setups=$(grep -c 'uses: actions/setup-go' "$f")
    gated=$(grep -cE "cache: (false|\\$\\{\\{ startsWith\\((inputs\\.runs_on|matrix\\.os), 'ubuntu-'\\))" "$f")
    if [ "$setups" -eq "$gated" ]; then
        pass "$name gates every setup-go cache on a hosted label ($setups)"
    else
        fail "$name restores a Go cache unconditionally (setup-go=$setups gated=$gated)"
    fi
done

# The README gives the same expression to a repository's own jobs.
if grep -qF "runs-on: $POLICY" "$REPO_ROOT/README.md"; then
    pass "README prints the runner policy byte for byte"
else
    fail "README's runner policy differs from the workflows'"
fi

# The events on which a public repository may reach the self-hosted runner.
# Each is one only the repository itself can start: a pull request, and any
# event a fork's pull request can set off, would run outside code there.
events=$(printf '%s' "$POLICY" | sed -n "s/.*fromJSON('\(\[[^]]*\]\)').*/\1/p" | tr -d '[]"' | tr ',' ' ')
if [ -z "$events" ]; then
    fail "cannot read the event list from the policy"
fi
unsafe=""
for e in $events; do
    case "$e" in
        push|schedule|workflow_dispatch|release) ;;
        *) unsafe="$unsafe $e" ;;
    esac
done
if [ -z "$unsafe" ]; then
    pass "a public repository reaches the self-hosted runner only on: $events"
else
    fail "the policy lets a public repository reach the self-hosted runner on:$unsafe"
fi

# A dry evaluation of the policy: the same rule in shell, over the event list
# read from the expression above. An empty variable is how a public
# repository sees CI_RUNNER_PRIVATE; "null" is a schedule's missing
# repository.
route() { # private event CI_RUNNER_PRIVATE CI_RUNNER_PUBLIC
    local private="$1" event="$2" priv="$3" pub="$4" trusted=false label="" e
    [ "$private" = true ] && trusted=true
    for e in $events; do [ "$e" = "$event" ] && trusted=true; done
    if [ "$trusted" = true ]; then
        label="${priv:-$pub}"
    fi
    printf '%s' "${label:-ubuntu-latest}"
}
check_route() { # want private event priv pub what
    local got
    got=$(route "$2" "$3" "$4" "$5")
    if [ "$got" = "$1" ]; then
        pass "$6: $got"
    else
        fail "$6: got $got, want $1"
    fi
}
echo "the policy, evaluated"
check_route linux-vm      true  push              linux-vm      ubuntu-latest "private push"
check_route linux-vm      true  pull_request      linux-vm      ubuntu-latest "private pull request"
check_route linux-vm      null  schedule          linux-vm      ubuntu-latest "private schedule, no repository in the payload"
check_route ubuntu-latest true  push              ubuntu-latest ubuntu-latest "private push, self-hosted runner offline"
check_route ubuntu-latest null  schedule          ubuntu-latest ubuntu-latest "private schedule, self-hosted runner offline"
check_route ubuntu-latest true  push              ""            ""            "private push, neither variable set"
check_route ubuntu-latest false push              ""            ubuntu-latest "public push"
check_route ubuntu-latest false pull_request      ""            ubuntu-latest "public pull request"
check_route linux-vm      false push              ""            linux-vm      "public push, hosted runners down"
check_route linux-vm      false workflow_dispatch ""            linux-vm      "public dispatch, hosted runners down"
check_route linux-vm      null  schedule          ""            linux-vm      "public schedule, hosted runners down"
check_route ubuntu-latest false pull_request      ""            linux-vm      "public pull request, hosted runners down"
check_route ubuntu-latest false pull_request_target ""          linux-vm      "public pull_request_target, hosted runners down"
check_route ubuntu-latest false workflow_run      ""            linux-vm      "public workflow_run, hosted runners down"
check_route ubuntu-latest false issue_comment     ""            linux-vm      "public issue comment, hosted runners down"
check_route ubuntu-latest false push              ""            ""            "public push, neither variable set"

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
