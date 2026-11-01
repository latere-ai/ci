#!/usr/bin/env bash
#
# SemVer tag classification across the release workflows.
#
# SemVer §9: a hyphen introduces a prerelease only in the version core.
# SemVer §10: build metadata follows a '+' and belongs to a stable release,
# and its identifiers may legally contain hyphens. Testing the whole tag for
# a hyphen therefore misclassifies a stable tag such as
# v1.0.0+exp-sha.5114f85 as a prerelease, which publishes it as a GitHub
# prerelease and withholds the docker `latest` tag.
#
# The rule lives in two shipped scripts, each tested on its own:
# actions/release-preflight/run.sh refuses a '+' tag before anything touches
# a registry and gives the prerelease flag (release_preflight_test.sh), and
# actions/publish-release/run.sh strips build metadata before its hyphen test
# (publish_release_action_test.sh). The greps here hold every workflow to
# those scripts: no workflow re-derives the rule inline.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS="$REPO_ROOT/.github/workflows"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# Both scripts strip build metadata before the hyphen test.
for script in actions/release-preflight/run.sh actions/publish-release/run.sh; do
    if grep -qF 'core=${TAG%%+*}' "$REPO_ROOT/$script"; then
        pass "$script strips build metadata before the hyphen test"
    else
        fail "$script strips build metadata before the hyphen test"
    fi
done

# Every workflow that tags an image `latest` runs the preflight, and the
# gate reads its flag rather than github.ref_name.
gates=$(grep -ln 'value=latest,enable=' "$WORKFLOWS"/*.yml || true)
if [ -z "$gates" ]; then
    fail "no docker latest gate found at all"
fi
for wf in $gates; do
    name=$(basename "$wf")
    if grep -q 'uses: ./.latere-ci/actions/release-preflight' "$wf" \
        && ! grep 'value=latest,enable=' "$wf" | grep -vqF "steps.preflight.outputs.prerelease != 'true'"; then
        pass "$name gates latest on the preflight's prerelease flag"
    else
        fail "$name gates latest on the preflight's prerelease flag"
    fi
done

hits=$(grep -rn -e '\[\[ "\$TAG" == \*-\* \]\]' -e "contains(github.ref_name, '-')" "$WORKFLOWS" "$REPO_ROOT/actions" || true)
if [ -z "$hits" ]; then
    pass "nothing tests the whole tag for a hyphen"
else
    fail "nothing tests the whole tag for a hyphen"
    printf '%s\n' "$hits"
fi

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
