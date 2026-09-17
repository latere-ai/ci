#!/usr/bin/env bash
#
# The runner contract, across every reusable workflow rather than one at a
# time. The family shares two self-hosted Linux runners, and a repository
# opts in with a single `runs_on:` line on the caller. That only holds if
# every reusable workflow declares the input and every job of it follows the
# label: one job left on a literal `ubuntu-latest` keeps that leg of a release
# on hosted minutes, away from the cluster credentials the rest of the run has.
#
# A matrix job is the exception. `test_os` already names its runners, so it
# follows `matrix.os` and the consumer sets both lines.
#
# The second half is the cost of the first. actions/setup-go restores the
# module cache as a tarball, which is right on a hosted runner (it starts
# empty) and fails file by file on a self-hosted one (it keeps its own cache
# between jobs). So every setup-go under a runs_on label gates the restore on
# a hosted label or turns it off.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS="$REPO_ROOT/.github/workflows"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# A reusable workflow is one a consumer can call. The repo's own workflows
# (actionlint, test, major-tag, release) run here and keep a fixed runner.
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

    # The input exists, is a string, and defaults to the hosted runner so a
    # caller that says nothing keeps today's behavior.
    decl=$(awk '/^      runs_on:$/ { inblk = 1 } inblk { print } inblk && /^        default:/ { exit }' "$f")
    if printf '%s\n' "$decl" | grep -q 'type: string' \
        && printf '%s\n' "$decl" | grep -q 'default: "ubuntu-latest"'; then
        pass "$name declares runs_on (string, default ubuntu-latest)"
    else
        fail "$name has no runs_on input defaulting to ubuntu-latest"
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

    # The module cache restore is a hosted-runner optimisation and a
    # self-hosted-runner failure.
    setups=$(grep -c 'uses: actions/setup-go' "$f")
    gated=$(grep -cE "cache: (false|\\$\\{\\{ startsWith\\((inputs\\.runs_on|matrix\\.os), 'ubuntu-'\\))" "$f")
    if [ "$setups" -eq "$gated" ]; then
        pass "$name gates every setup-go cache on a hosted label ($setups)"
    else
        fail "$name restores a Go cache unconditionally (setup-go=$setups gated=$gated)"
    fi
done

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
