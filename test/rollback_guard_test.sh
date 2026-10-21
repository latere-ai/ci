#!/usr/bin/env bash
#
# The rollback guard in service-release.yml. A release is one job, so a
# re-run repeats the build and the deploy; once a newer vX.Y.Z tag exists, a
# re-run of an older tag would push it as latest and roll production back.
# The guard's newer_than function is read out of the workflow itself and run
# on a table of tags, so the table tests what ships. The grep assertions pin
# the step ahead of everything that touches a registry or the cluster.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/service-release.yml"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

fn=$(awk '/^          newer_than\(\) \{$/ {on = 1} on {print} on && /^          \}$/ {exit}' "$WORKFLOW")
if [ -z "$fn" ]; then
    fail "the workflow defines no newer_than function"
    exit 1
fi
eval "$fn"

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
guard=$(grep -nF 'name: Refuse to roll production back' "$WORKFLOW" | head -1 | cut -d: -f1)
order_ok=1
for step in 'name: Reject build-metadata tags' 'name: Build and push' 'name: Write the kubeconfig' 'name: Roll new image'; do
    line=$(grep -nF "$step" "$WORKFLOW" | head -1 | cut -d: -f1)
    if [ -z "$guard" ] || [ -z "$line" ] || [ "$guard" -ge "$line" ]; then
        order_ok=0
        fail "the rollback guard does not run before $step (guard=$guard step=$line)"
    fi
done
[ "$order_ok" -eq 1 ] && pass "the rollback guard runs before the image is pushed and the cluster is touched"

if [ "$FAILURES" -gt 0 ]; then
    exit 1
fi
