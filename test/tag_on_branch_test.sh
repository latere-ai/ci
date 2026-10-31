#!/usr/bin/env bash
#
# The default-branch guard in service-release.yml. A tag releases what the
# default branch holds; a tag on a commit off it, such as one a release cut
# pushed while its branch push was rejected, would build and deploy code the
# branch never had. The guard's on_branch function is read out of the
# workflow itself and run in real clones of a bare origin, shallow and full,
# so the cases test what ships, a one-commit checkout included. The grep
# assertions pin the step ahead of everything that touches a registry or
# the cluster.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/service-release.yml"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

fn=$(awk '/^          on_branch\(\) \{$/ {on = 1} on {print} on && /^          \}$/ {exit}' "$WORKFLOW")
if [ -z "$fn" ]; then
    fail "the workflow defines no on_branch function"
    exit 1
fi
eval "$fn"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The machine's own git config, an insteadOf rewrite or a hook, stays out.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# origin's main is c1 to c6, with v0.1.0 on c2 and v0.3.0 on c6. v0.2.0 is
# on a child of c2 that never reached main: the tag a release cut pushes
# when its branch push is rejected because main moved on first. Several
# commits sit between each tag and main's tip, so a one-commit checkout
# holds none of the history the check walks until the guard fetches it.
ORIGIN="$TMP/origin.git"
git init -q --bare -b main "$ORIGIN" 2>/dev/null || { git init -q --bare "$ORIGIN"; git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main; }
git clone -q "file://$ORIGIN" "$TMP/seed" 2>/dev/null
seed() { git -C "$TMP/seed" "$@"; }
seed checkout -q -b main
seed commit -q --allow-empty -m c1
seed commit -q --allow-empty -m c2
seed tag -a v0.1.0 -m v0.1.0
for c in c3 c4 c5 c6; do
    seed commit -q --allow-empty -m "$c"
done
seed tag -a v0.3.0 -m v0.3.0
seed checkout -q --detach v0.1.0
seed commit -q --allow-empty -m "the release commit that lost the race"
seed tag -a v0.2.0 -m v0.2.0
seed push -q origin main v0.1.0 v0.2.0 v0.3.0

# check NAME TAG DEPTH BRANCH WANT_RC WANT_OUTPUT: on_branch BRANCH, in a
# clone checked out at TAG (one commit deep when DEPTH is 1, full when it
# is 0), returns WANT_RC and prints a line holding WANT_OUTPUT.
n=0
check() {
    local name=$1 tag=$2 depth=$3 branch=$4 want_rc=$5 want=$6 dir rc=0 out
    n=$((n + 1))
    dir="$TMP/clone$n"
    if [ "$depth" -eq 1 ]; then
        git clone -q --depth 1 --branch "$tag" "file://$ORIGIN" "$dir" 2>/dev/null
    else
        git clone -q --branch "$tag" "file://$ORIGIN" "$dir" 2>/dev/null
    fi
    out=$(cd "$dir" && TAG=$tag on_branch "$branch" 2>&1) || rc=$?
    if [ "$rc" -eq "$want_rc" ] && printf '%s\n' "$out" | grep -qF -- "$want"; then
        pass "$name"
    else
        fail "$name: on_branch $branch at $tag returned $rc, want $want_rc; output: $out"
    fi
}

check "a tag on main releases" v0.1.0 0 main 0 ""
check "a tag on main releases from a one-commit checkout" v0.1.0 1 main 0 ""
check "the tag on main's tip releases from a one-commit checkout" v0.3.0 1 main 0 ""
check "a tag off main is refused" v0.2.0 0 main 1 "::error::v0.2.0 is not on main"
check "a tag off main is refused from a one-commit checkout" v0.2.0 1 main 1 "::error::v0.2.0 is not on main"
check "the refusal says nothing was built or deployed" v0.2.0 1 main 1 "so nothing was built or deployed"
check "a branch origin does not have is refused" v0.1.0 1 trunk 1 "::error::cannot fetch trunk to check that v0.1.0 is on it"

# The branch is the caller's default branch, not a fixed main.
if grep -qF "BRANCH: \${{ github.event.repository.default_branch || 'main' }}" "$WORKFLOW" &&
    grep -qF 'on_branch "$BRANCH"' "$WORKFLOW"; then
    pass "the guard checks the repository's default branch"
else
    fail "the guard does not read the default branch from the event"
fi

# The guard runs before any step that pushes an image or touches the
# cluster, so a refused tag changes nothing.
guard=$(grep -nF 'name: Refuse a tag that is not on the default branch' "$WORKFLOW" | head -1 | cut -d: -f1)
order_ok=1
for step in 'name: Reject build-metadata tags' 'name: Build and push' 'name: Write the kubeconfig' 'name: Roll new image'; do
    line=$(grep -nF "$step" "$WORKFLOW" | head -1 | cut -d: -f1)
    if [ -z "$guard" ] || [ -z "$line" ] || [ "$guard" -ge "$line" ]; then
        order_ok=0
        fail "the default-branch guard does not run before $step (guard=$guard step=$line)"
    fi
done
[ "$order_ok" -eq 1 ] && pass "the default-branch guard runs before the image is pushed and the cluster is touched"

if [ "$FAILURES" -gt 0 ]; then
    exit 1
fi
