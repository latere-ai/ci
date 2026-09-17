#!/usr/bin/env bash
#
# Run artifacts must expire. A repository's artifact store is a fixed quota
# shared by every run, and GitHub's default retention is 90 days: lectio's
# store hit its quota holding 284 artifacts, which fails the upload step of
# whatever release runs next. So every uploader in these workflows carries a
# short retention, short enough to bound the store and long enough to cover a
# re-run or a download while the release still matters.
#
# Two uploaders exist, and both are checked. actions/upload-artifact takes
# `retention-days` under `with:`. docker/build-push-action uploads a
# *.dockerbuild build record of its own and takes the duration from the
# DOCKER_BUILD_RECORD_RETENTION_DAYS environment variable, documented at the
# pinned v7.3.0; unset, that record falls back to the 90-day default.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS="$REPO_ROOT/.github/workflows"
MAX_DAYS=30
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# Each uploading step is read as its own block, so a second retention on one
# step cannot stand in for a missing one on another.
steps_missing() {
    awk -v marker="$1" -v key="$2" '
        function close_block() {
            if (inblk && !found) print FILENAME ":" start
            inblk = 0
        }
        {
            if (index($0, marker) > 0) { close_block(); inblk = 1; found = 0; start = FNR; next }
            if (inblk) {
                # A step ends at the next step marker or at any line that
                # dedents out of the step body.
                if ($0 ~ /^      - / || ($0 !~ /^[ \t]*$/ && $0 !~ /^ {8,}/)) { close_block(); next }
                if (index($0, key) > 0) found = 1
            }
        }
        END { close_block() }
    ' "$3"
}

assert_every_uploader_expires() {
    local marker="$1" key="$2" label="$3"
    local total=0 missing="" f n
    for f in "$WORKFLOWS"/*.yml; do
        n=$(grep -cF "$marker" "$f")
        total=$((total + n))
        [ "$n" -eq 0 ] && continue
        missing="${missing}$(steps_missing "$marker" "$key" "$f")"
    done
    if [ "$total" -eq 0 ]; then
        fail "$label (no such step found at all; did the uploader move?)"
        return
    fi
    if [ -z "$missing" ]; then
        pass "$label ($total steps)"
    else
        fail "$label"
        printf '    unbounded: %s\n' $missing
    fi
}

# A retention long enough to be the default again is not a bound.
assert_retention_is_short() {
    local name="every retention is at most $MAX_DAYS days"
    local values v bad=""
    values=$(grep -rhoE '(retention-days|DOCKER_BUILD_RECORD_RETENTION_DAYS): *[0-9]+' "$WORKFLOWS" \
        | sed -E 's/.*: *//')
    if [ -z "$values" ]; then
        fail "$name (no retention value found)"
        return
    fi
    for v in $values; do
        if [ "$v" -lt 1 ] || [ "$v" -gt "$MAX_DAYS" ]; then
            bad="$bad $v"
        fi
    done
    if [ -z "$bad" ]; then
        pass "$name ($(printf '%s\n' "$values" | wc -l | tr -d ' ') values)"
    else
        fail "$name (out of range:$bad)"
    fi
}

assert_every_uploader_expires \
    'uses: actions/upload-artifact@' 'retention-days:' \
    'every upload-artifact step expires'
assert_every_uploader_expires \
    'uses: docker/build-push-action@' 'DOCKER_BUILD_RECORD_RETENTION_DAYS:' \
    'every docker build record expires'
assert_retention_is_short

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
