#!/usr/bin/env bash
#
# A skipped job never expands its matrix, so a job name that reads the matrix
# shows the raw expression in the checks list. The matrix legs of the test
# job are named by GitHub, which appends the matrix value to a static name.
#
# Kept bash 3.2 compatible.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/lateregate.yml"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

name=$(sed -n '/^  test:$/,/^    needs:/p' "$WORKFLOW" | grep -E '^    name:')
if [ -n "$name" ] && ! printf '%s' "$name" | grep -qF 'matrix.'; then
    pass "the test job's name does not read the matrix, so skipping it shows no raw expression"
else
    fail "the test job's name reads the matrix (name line: '$name')"
fi

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
