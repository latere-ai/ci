#!/usr/bin/env bash
#
# Runs every *_test.sh in this directory and fails if any of them fails.
#
# The reusable workflows here cannot be executed locally, so the suite is
# two kinds of check: unit tests over copies of the inline workflow shell,
# and grep assertions that the copies still match what the workflows ship.
#
# Uses a counter rather than an array so the runner itself works on bash
# 3.2 (macOS /bin/bash); individual suites re-exec into bash 4+ if they
# need it.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0
FAILED_NAMES=""

for t in "$TEST_DIR"/*_test.sh; do
    printf "\n\033[1m%s\033[0m\n" "$(basename "$t")"
    if ! bash "$t"; then
        FAILED=$((FAILED + 1))
        FAILED_NAMES="${FAILED_NAMES} $(basename "$t")"
    fi
done

if [ "$FAILED" -gt 0 ]; then
    printf "\n\033[31m%d suite(s) failed:\033[0m%s\n" "$FAILED" "$FAILED_NAMES"
    exit 1
fi
printf "\n\033[32mall suites passed\033[0m\n"
