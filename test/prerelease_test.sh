#!/usr/bin/env bash
#
# Regression tests for SemVer tag classification in the release workflows.
#
# SemVer §9: a hyphen introduces a prerelease only in the *version core*.
# SemVer §10: build metadata follows a '+' and belongs to a stable release,
# and its identifiers may legally contain hyphens. Testing the whole tag for
# a hyphen therefore misclassifies a stable tag such as
# v1.0.0+exp-sha.5114f85 as a prerelease, which publishes it as a GitHub
# prerelease and withholds the docker `latest` tag.
#
# classify_tag below is a copy of the inline shell the workflows run. A
# reusable workflow invoked as latere-ai/ci/.github/workflows/x.yml@v1 does
# not ship sibling files to the consumer runner, so the logic cannot be
# extracted into a script the workflow sources; the copy can drift, and the
# assert_* greps below catch that.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS="$REPO_ROOT/.github/workflows"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# classify_tag is the verbatim rule both release workflows apply: strip
# build metadata, then test the remaining version core for a hyphen.
classify_tag() {
    local tag="$1"
    local core="${tag%%+*}"
    if [[ "$core" == *-* ]]; then
        printf 'prerelease\n'
    else
        printf 'stable\n'
    fi
}

# reject_tag is the verbatim guard both release workflows apply before any
# registry work. docker/metadata-action sanitizes an image tag to
# [a-zA-Z0-9._-], so a build-metadata tag would push as
# v1.0.0-exp-sha.5114f85 while `kubectl set image` and BASE_IMAGE still
# reference the raw ref. The pipeline keeps "image tag == git tag" and
# refuses the tag instead of letting the two diverge.
reject_tag() {
    local tag="$1"
    case "$tag" in
        *+*) printf 'reject\n' ;;
        *)   printf 'accept\n' ;;
    esac
}

expect_rejection() {
    local tag="$1" want="$2"
    local got
    got="$(reject_tag "$tag")"
    if [ "$got" = "$want" ]; then
        pass "$tag -> $want"
    else
        fail "$tag -> want $want, got $got"
    fi
}

test_rejection() {
    expect_rejection "v1.2.3" accept
    expect_rejection "v1.2.3-rc1" accept
    expect_rejection "v1.0.0+build.7" reject
    expect_rejection "v1.0.0+exp-sha.5114f85" reject
    expect_rejection "v1.2.3-rc.1+exp-sha.5114f85" reject
}

# The guard must run in the first job that touches a registry, so no image
# is pushed and nothing is deployed under a tag the rest of the pipeline
# cannot reference.
assert_workflows_reject_build_metadata() {
    local wf
    for wf in service-release.yml images-release.yml; do
        local name="$wf refuses a tag carrying build metadata"
        if grep -q 'Reject build-metadata tags' "$WORKFLOWS/$wf" \
            && grep -q '\*+\*)' "$WORKFLOWS/$wf"; then
            pass "$name"
        else
            fail "$name (no 'Reject build-metadata tags' guard found)"
        fi
    done
}

expect_classification() {
    local tag="$1" want="$2"
    local got
    got="$(classify_tag "$tag")"
    if [ "$got" = "$want" ]; then
        pass "$tag -> $want"
    else
        fail "$tag -> want $want, got $got"
    fi
}

test_classification() {
    # Common tags: unaffected by the fix, asserted so it cannot regress them.
    expect_classification "v1.2.3" stable
    expect_classification "v1.2.3-rc1" prerelease
    expect_classification "v1.2.3-alpha.1" prerelease

    # Build metadata without a hyphen: already correct before the fix.
    expect_classification "v1.0.0+build.7" stable

    # The bug: stable core, hyphen inside the build metadata. Both of these
    # classify as prerelease under the old whole-tag test.
    expect_classification "v1.0.0+exp-sha.5114f85" stable
    expect_classification "v1.0.0+21AF26D3---117B344092BD" stable

    # Prerelease core *and* hyphenated build metadata stays a prerelease.
    expect_classification "v1.2.3-rc.1+exp-sha.5114f85" prerelease
}

# The bash publish blocks must strip build metadata before the hyphen test.
assert_bash_strips_build_metadata() {
    local wf
    for wf in service-release.yml images-release.yml; do
        local name="$wf publish strips build metadata before the hyphen test"
        if grep -q 'core="\${TAG%%+\*}"' "$WORKFLOWS/$wf"; then
            pass "$name"
        else
            fail "$name (no 'core=\"\${TAG%%+*}\"' found)"
        fi
    done
}

assert_no_whole_tag_hyphen_test() {
    local name="no workflow tests the whole tag for a hyphen"
    local hits
    hits=$(grep -rn '\[\[ "\$TAG" == \*-\* \]\]' "$WORKFLOWS" || true)
    if [ -z "$hits" ]; then
        pass "$name"
    else
        fail "$name"
        printf '%s\n' "$hits"
    fi
}

# The GHA `enable=` gates cannot strip '+...' inline, so they must consume a
# precomputed boolean rather than re-deriving from github.ref_name.
assert_no_ref_name_hyphen_gate() {
    local name="no docker latest gate derives from contains(github.ref_name, '-')"
    local hits
    hits=$(grep -rn "contains(github.ref_name, '-')" "$WORKFLOWS" || true)
    if [ -z "$hits" ]; then
        pass "$name"
    else
        fail "$name"
        printf '%s\n' "$hits"
    fi
}

assert_latest_gates_use_computed_flag() {
    local name="every docker latest gate reads a computed stable flag"
    local gates bad
    gates=$(grep -rn 'value=latest,enable=' "$WORKFLOWS" || true)
    if [ -z "$gates" ]; then
        fail "$name (no latest gate found at all)"
        return
    fi
    bad=$(printf '%s\n' "$gates" | grep -v 'outputs.stable' || true)
    if [ -z "$bad" ]; then
        pass "$name ($(printf '%s\n' "$gates" | wc -l | tr -d ' ') gates)"
    else
        fail "$name"
        printf '%s\n' "$bad"
    fi
}

test_rejection
assert_workflows_reject_build_metadata
test_classification
assert_bash_strips_build_metadata
assert_no_whole_tag_hyphen_test
assert_no_ref_name_hyphen_gate
assert_latest_gates_use_computed_flag

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
