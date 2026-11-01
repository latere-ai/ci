#!/usr/bin/env bash
#
# The rollback guard, actions/rollback-guard, which service-release.yml runs.
# A release is one job, so a re-run repeats the build and the deploy; once a
# newer vX.Y.Z tag exists, a re-run of an older tag would push it as latest
# and roll production back. The shipped script is sourced for its newer_than
# function and run on a table of tags, then run whole against a real origin.
# The grep assertions pin the step ahead of everything that touches a
# registry or the cluster.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/service-release.yml"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# shellcheck source=../actions/rollback-guard/run.sh
. "$REPO_ROOT/actions/rollback-guard/run.sh"
set +e

# check NAME TAG WANT TAGS...: newer_than TAG over TAGS prints WANT.
check() {
    local name=$1 tag=$2 want=$3 got
    shift 3
    got=$(printf '%s\n' "$@" | newer_than "$tag")
    if [ "$got" = "$want" ]; then
        pass "$name"
    else
        fail "$name: newer_than $tag printed '$got', want '$want'"
    fi
}

check "the newest tag releases" v0.2.0 "" v0.1.0 v0.2.0
check "an older tag names the newer one" v0.1.0 v0.2.0 v0.1.0 v0.2.0
check "versions compare as numbers, not text" v0.9.0 v0.10.0 v0.9.0 v0.10.0 v0.8.0
check "the newest of several newer tags is named" v0.1.0 v0.3.0 v0.2.0 v0.3.0 v0.1.0
check "a tag with no newer one releases" v0.3.0 "" v0.1.0 v0.2.0
check "a newer prerelease does not stop a release" v0.2.0 "" v0.2.0 v0.3.0-rc1
check "a prerelease of the newest version releases" v0.3.0-rc1 "" v0.2.0 v0.3.0
check "a prerelease behind a newer version is stopped" v0.3.0-rc2 v0.4.0 v0.3.0 v0.4.0
check "build metadata is ignored" v0.2.0+exp v0.3.0 v0.2.0 v0.3.0
check "tags that are not vX.Y.Z are ignored" v0.2.0 "" v1 v2-beta vfoo v0.2.0
check "no tags at all releases" v0.1.0 ""

# The guard runs before any step that pushes an image or touches the
# cluster, so a refused re-run changes nothing.
guard=$(grep -nF 'uses: ./.latere-ci/actions/rollback-guard' "$WORKFLOW" | head -1 | cut -d: -f1)
order_ok=1
for step in 'name: Isolate Docker credentials' 'name: Build and push' 'name: Write the kubeconfig' 'name: Roll new image'; do
    line=$(grep -nF "$step" "$WORKFLOW" | head -1 | cut -d: -f1)
    if [ -z "$guard" ] || [ -z "$line" ] || [ "$guard" -ge "$line" ]; then
        order_ok=0
        fail "the rollback guard does not run before $step (guard=$guard step=$line)"
    fi
done
[ "$order_ok" -eq 1 ] && pass "the rollback guard runs before the image is pushed and the cluster is touched"

# The whole script against a real origin: a newer tag refuses, none passes.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git init -q --bare "$TMP/origin.git"
git -C "$TMP" init -q seed
git -C "$TMP/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
git -C "$TMP/seed" tag v0.1.0
git -C "$TMP/seed" tag v0.2.0
git -C "$TMP/seed" push -q "$TMP/origin.git" HEAD:refs/heads/main --tags
git clone -q "$TMP/origin.git" "$TMP/work" 2> /dev/null
SCRIPT="$REPO_ROOT/actions/rollback-guard/run.sh"
if out=$(cd "$TMP/work" && GITHUB_REF_NAME=v0.1.0 bash "$SCRIPT" 2>&1); then
    fail "a re-run of an older tag is refused ($out)"
elif printf '%s' "$out" | grep -qF "v0.2.0 is tagged and newer than v0.1.0"; then
    pass "a re-run of an older tag is refused, naming the newer one"
else
    fail "a re-run of an older tag is refused, naming the newer one ($out)"
fi
if out=$(cd "$TMP/work" && GITHUB_REF_NAME=v0.2.0 bash "$SCRIPT" 2>&1) && printf '%s' "$out" | grep -qF "no tag newer than v0.2.0"; then
    pass "the newest tag passes"
else
    fail "the newest tag passes ($out)"
fi
git init -q "$TMP/lone"
if out=$(cd "$TMP/lone" && GITHUB_REF_NAME=v0.2.0 bash "$SCRIPT" 2>&1); then
    fail "a checkout with no origin refuses ($out)"
else
    pass "a checkout with no origin refuses rather than passing"
fi

if [ "$FAILURES" -gt 0 ]; then
    exit 1
fi
