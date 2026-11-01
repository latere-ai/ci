#!/usr/bin/env bash
#
# The GitHub release for the tag. Its body is the tag's CHANGELOG.md
# section, read by lateregate's note reader at the version in
# actions/lib/versions.sh, followed by each EVIDENCE file after a blank line;
# a tag with no section fails before anything is created. The body is rebuilt
# on every run, so a re-run replaces it rather than stacking.
#
# A new release is created as a draft, its files attached, and only then
# published, so nobody sees it, and no release webhook fires, before every
# asset is there. A re-run of a release that exists, published or a draft a
# failed run left, edits the body, replaces the files and publishes it.
#
# Inputs, from the environment: GITHUB_REF_NAME, GITHUB_REPOSITORY, TITLE
# (a prefix: "Lux" titles the release "Lux v1.2.3"; empty titles it with the
# tag alone), FILES and EVIDENCE (one path or shell pattern per line,
# relative to the working directory; a pattern that matches nothing fails),
# LATEREGATE_VERSION.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"

TAG=${GITHUB_REF_NAME:?}
REPO=${GITHUB_REPOSITORY:?}

die() {
    echo "::error::$*" >&2
    exit 1
}

# Appends to the array named $1 every path the lines of $2 name.
expand() {
    local var=$1 line matches m
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # The line is a pattern, expanded here on purpose.
        # shellcheck disable=SC2206
        matches=($line)
        for m in "${matches[@]}"; do
            [ -f "$m" ] || die "'$line' names no file"
            eval "$var+=(\"\$m\")"
        done
    done <<< "$2"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

[ -f CHANGELOG.md ] || die "there is no CHANGELOG.md, so $TAG has no release notes"
mkdir "$work/notes"
cp CHANGELOG.md "$work/notes/CHANGELOG.md"
go run "latere.ai/x/ci-gate/cmd/lateregate@${LATEREGATE_VERSION}" release-notes -C "$work/notes" "$TAG" > "$work/body.md" \
    || die "CHANGELOG.md has no section for $TAG; a tag is a release, and a release has notes"

evidence=()
expand evidence "${EVIDENCE:-}"
for e in ${evidence[@]+"${evidence[@]}"}; do
    { printf '\n'; cat "$e"; } >> "$work/body.md"
done

files=()
expand files "${FILES:-}"

prerelease=()
core=${TAG%%+*}
case "$core" in
    *-*) prerelease=(--prerelease) ;;
esac
title="${TITLE:+$TITLE }$TAG"

if gh release view "$TAG" --repo "$REPO" > /dev/null 2>&1; then
    gh release edit "$TAG" --repo "$REPO" --notes-file "$work/body.md"
    if [ "${#files[@]}" -gt 0 ]; then
        gh release upload "$TAG" --repo "$REPO" --clobber "${files[@]}"
    fi
else
    # --verify-tag: the tag exists at the pushed commit, and gh must not
    # create one at HEAD if it somehow does not. No --target: passing
    # target_commitish makes gh attempt a ref create the job's token cannot
    # perform (cli/cli#9514).
    gh release create "$TAG" --repo "$REPO" --verify-tag --draft ${prerelease[@]+"${prerelease[@]}"} \
        --title "$title" --notes-file "$work/body.md" ${files[@]+"${files[@]}"}
fi
gh release edit "$TAG" --repo "$REPO" --draft=false
echo "published $title with ${#files[@]} file(s)"
