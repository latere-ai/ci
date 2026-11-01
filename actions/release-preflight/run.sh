#!/usr/bin/env bash
#
# What a release checks before it builds or pushes anything, and the values
# the build stamps. In order:
#
#   1. The tag carries no SemVer build metadata. An image tag cannot hold
#      '+', and the image is tagged with the git tag.
#   2. The tag's commit is on the default branch, so a release ships what
#      the branch holds: not a tag whose branch push was rejected, nor one
#      pushed from a side branch.
#   3. CHANGELOG.md has a section for the tag, read by lateregate's note
#      reader at the version in actions/lib/versions.sh.
#   4. The image namespace: NAMESPACE_OVERRIDE when set, else the repository
#      owner, lowered, so a fork's tag publishes under the fork. It must be a
#      valid reference prefix, because an image reference is lowercase.
#
# Writes owner, commit (short), date (the commit's, UTC) and prerelease
# (true when the version core carries a hyphen) to $GITHUB_OUTPUT.
#
# Inputs, from the environment: GITHUB_REF_NAME, GITHUB_REPOSITORY_OWNER,
# DEFAULT_BRANCH, NAMESPACE_OVERRIDE, LATEREGATE_VERSION. Runs in the
# caller's checkout.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"

TAG=${GITHUB_REF_NAME:?}
BRANCH=${DEFAULT_BRANCH:-main}

die() {
    echo "::error::$*" >&2
    exit 1
}

case "$TAG" in
    *+*) die "$TAG carries SemVer build metadata, which an image tag cannot hold; cut a tag without it" ;;
esac

# Fails unless HEAD is reachable from origin's branch $1. A one-commit
# checkout usually needs no deepening: a fetch into a shallow clone brings
# the branch down to the tag's commit when the tag is on it, and the whole
# branch when it is not. A runner that reuses its workspace can already hold
# the branch's tip as a shallow commit from an earlier run, so that fetch
# brings nothing and the history below the tip stays cut, which reads as a
# tag off the branch. A refusal is therefore decided on the whole branch.
on_branch() {
    local branch=$1 rc=0
    if ! git fetch --no-tags --quiet origin "+refs/heads/$branch:refs/remotes/origin/$branch"; then
        die "cannot fetch $branch to check that $TAG is on it, so nothing was built"
    fi
    git merge-base --is-ancestor HEAD "refs/remotes/origin/$branch" || rc=$?
    if [ "$rc" -eq 1 ] && [ "$(git rev-parse --is-shallow-repository)" = true ]; then
        if ! git fetch --no-tags --quiet --unshallow origin "+refs/heads/$branch:refs/remotes/origin/$branch"; then
            die "cannot fetch all of $branch to check that $TAG is on it, so nothing was built"
        fi
        rc=0
        git merge-base --is-ancestor HEAD "refs/remotes/origin/$branch" || rc=$?
    fi
    if [ "$rc" -eq 1 ]; then
        die "$TAG is not on $branch: its commit $(git rev-parse --short HEAD) is not reachable from origin/$branch, so nothing was built. Delete the tag with git push origin :refs/tags/$TAG, land the change on $branch, and tag a commit there."
    fi
    if [ "$rc" -ne 0 ]; then
        die "cannot tell whether $TAG is on $branch: git merge-base exited $rc, so nothing was built"
    fi
}
on_branch "$BRANCH"
echo "$TAG is on $BRANCH"

[ -f CHANGELOG.md ] || die "there is no CHANGELOG.md, so $TAG has no release notes"
notes_root=$(mktemp -d)
trap 'rm -rf "$notes_root"' EXIT
cp CHANGELOG.md "$notes_root/CHANGELOG.md"
# The reader's own words say which failed: no section, or a reader that
# could not be fetched or built.
if ! reader=$(go run "latere.ai/x/ci-gate/cmd/lateregate@${LATEREGATE_VERSION}" release-notes -C "$notes_root" "$TAG" 2>&1 > /dev/null); then
    die "CHANGELOG.md has no section for $TAG, or the note reader at ${LATEREGATE_VERSION} did not run: ${reader:-no output}. A tag is a release, and a release has notes"
fi
echo "CHANGELOG.md has a section for $TAG"

owner=${NAMESPACE_OVERRIDE:-${GITHUB_REPOSITORY_OWNER:?}}
owner=$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')
if ! printf '%s' "$owner" | grep -Eq '^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$'; then
    die "'$owner' is not a valid image namespace; set the repository variable RELEASE_IMAGE_NAMESPACE to one"
fi

core=${TAG%%+*}
prerelease=false
case "$core" in
    *-*) prerelease=true ;;
esac

{
    echo "owner=$owner"
    echo "commit=$(git rev-parse --short HEAD)"
    echo "date=$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ)"
    echo "prerelease=$prerelease"
} >> "${GITHUB_OUTPUT:?}"
echo "images publish under $owner"
