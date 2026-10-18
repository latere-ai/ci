#!/usr/bin/env bash
#
# Assertions over cli-release.yml's signing key.
#
# A consumer that signs its release (latere-ai/latere-cli signs
# checksums.txt) reads the private key from RELEASE_SIGNING_KEY in
# goreleaser's environment. The secret is optional, so a consumer that signs
# nothing is unaffected, and it reaches the goreleaser step alone, never the
# lint or test jobs that run the consumer's code.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/cli-release.yml"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

printf "\033[1mcli-release signing key\033[0m\n"

# The declaration: RELEASE_SIGNING_KEY under workflow_call's secrets, with
# required: false on the line after its description.
if awk '
    /^    secrets:$/ { in_secrets = 1; next }
    in_secrets && /^      RELEASE_SIGNING_KEY:$/ { in_key = 1; next }
    in_key && /^        required: false$/ { found = 1 }
    in_key && /^      [A-Z_]+:$/ { in_key = 0 }
    /^[a-z]/ { in_secrets = 0; in_key = 0 }
    END { exit found ? 0 : 1 }
' "$WORKFLOW"; then
    pass "RELEASE_SIGNING_KEY is declared and optional"
else
    fail "RELEASE_SIGNING_KEY is not declared as an optional workflow_call secret"
fi

# Every reference to the secret, by line number.
refs=$(grep -n 'secrets\.RELEASE_SIGNING_KEY' "$WORKFLOW" | cut -d: -f1)
count=$(printf '%s\n' "$refs" | grep -c .)
if [ "$count" -eq 1 ]; then
    pass "the secret is referenced exactly once"
else
    fail "the secret is referenced $count times; want once, in the goreleaser step"
fi

# The one reference sits in the env of the step that uses goreleaser-action,
# inside the goreleaser job.
if [ "$count" -ge 1 ]; then
    line=$(printf '%s\n' "$refs" | head -n 1)
    step=$(awk -v target="$line" '
        /^  [a-z_-]+:$/ { job = $1 }
        /^      - / { step_start = NR; step_uses = "" }
        /uses: goreleaser\/goreleaser-action@/ { step_uses = "goreleaser" }
        NR == target { print job " " step_uses; exit }
    ' "$WORKFLOW")
    if [ "$step" = "goreleaser: goreleaser" ]; then
        pass "only the goreleaser step receives the signing key"
    else
        fail "the signing key is passed outside the goreleaser step (job and step: '$step')"
    fi
    if sed -n "${line}p" "$WORKFLOW" | grep -qE '^          RELEASE_SIGNING_KEY: \$\{\{ secrets\.RELEASE_SIGNING_KEY \}\}$'; then
        pass "the step's environment names it RELEASE_SIGNING_KEY"
    else
        fail "the goreleaser step does not set RELEASE_SIGNING_KEY from the secret"
    fi
fi

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d check(s) failed\n" "$FAILURES"
    exit 1
fi
