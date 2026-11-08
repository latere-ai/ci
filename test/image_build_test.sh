#!/usr/bin/env bash
#
# image-build.yml verifies the tagged commit like every other pipeline: its
# verify_workflow input is empty by default, which verified-commit reads as
# the one workflow in the checkout that calls lateregate.yml.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

for name in image-build.yml notes-release.yml cli-release.yml; do
    wf="$REPO_ROOT/.github/workflows/$name"
    if sed -n '/^      verify_workflow:$/,/^        default:/p' "$wf" | grep -qxF '        default: ""'; then
        pass "$name leaves verify_workflow empty by default, so the gate is detected"
    else
        fail "$name does not default verify_workflow to empty"
    fi
done

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
