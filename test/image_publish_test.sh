#!/usr/bin/env bash
#
# image-publish.yml appends Markdown evidence to the release body. The
# evidence line of publish-release is a file pattern, so it is passed only
# when a .md file was actually downloaded. The step that decides runs here
# as the workflow ships it, against a runner temp directory.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/image-publish.yml"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# The run block of the step named $1, without its indentation.
step_script() {
    awk -v name="$1" '
        $0 == "      - name: " name { instep = 1; next }
        instep && /^        run: \|$/ { inrun = 1; next }
        inrun && /^          / { sub(/^          /, ""); print; next }
        inrun { exit }
    ' "$WORKFLOW"
}

script=$(step_script "Find the Markdown evidence")
if [ -z "$script" ]; then
    fail "image-publish.yml has no 'Find the Markdown evidence' step"
    printf "\n1 failure(s)\n"
    exit 1
fi

# run_case NAME FILES... : the script over an evidence directory holding
# FILES; prints the output file's content.
evidence_output() {
    local tmp f out
    tmp=$(mktemp -d)
    mkdir -p "$tmp/evidence"
    for f in "$@"; do : > "$tmp/evidence/$f"; done
    : > "$tmp/output"
    RUNNER_TEMP=$tmp GITHUB_OUTPUT=$tmp/output bash -c "$script" > /dev/null 2>&1
    out=$(cat "$tmp/output")
    rm -rf "$tmp"
    printf '%s' "$out"
}

got=$(evidence_output smoke.md notes.md)
if printf '%s' "$got" | grep -q '^files=.*/evidence/\*\.md$'; then
    pass "a downloaded .md file is passed as the evidence pattern"
else
    fail "a downloaded .md file is passed as the evidence pattern (output: '$got')"
fi

got=$(evidence_output)
if [ -z "$got" ]; then
    pass "an empty evidence download passes no evidence"
else
    fail "an empty evidence download passes no evidence (output: '$got')"
fi

got=$(evidence_output smoke.json trace.txt)
if [ -z "$got" ]; then
    pass "artifacts holding no .md file pass no evidence"
else
    fail "artifacts holding no .md file pass no evidence (output: '$got')"
fi

# The publish step reads the step's output, not the bare input.
if grep -qF 'evidence: ${{ steps.evidence.outputs.files }}' "$WORKFLOW" \
    && ! grep -qE "evidence: .*inputs\.evidence" "$WORKFLOW"; then
    pass "publish-release takes the evidence the step found"
else
    fail "publish-release takes the evidence from the input, found or not"
fi

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
