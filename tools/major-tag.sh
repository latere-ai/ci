#!/usr/bin/env bash
#
# Moves the major tag (v1) to a release tag, forward only.
#
# Consumers pin the moving major tag, so it must never point at an older
# release than one already published. The move happens only when TAG is a
# plain vMAJOR.MINOR.PATCH release (a prerelease is not something a pin
# should pick up) and is the highest such tag on origin. A backport tag
# pushed after a newer minor leaves the major tag where it is.
#
# Run from a checkout that has TAG. Inputs, from the environment: TAG (the
# pushed tag), MAJOR (the tag to move; default v1).
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as the
# ubuntu-latest runners.
set -euo pipefail

TAG=${TAG:?}
MAJOR=${MAJOR:-v1}
release_re="^${MAJOR}\\.[0-9]+\\.[0-9]+\$"

if ! printf '%s' "$TAG" | grep -Eq "$release_re"; then
    echo "$TAG is a prerelease or non-standard tag; leaving $MAJOR alone."
    exit 0
fi

# origin is the authority on which tags exist, not this checkout's copy.
if ! tags=$(git ls-remote --tags --refs origin "refs/tags/${MAJOR}.*"); then
    echo "::error::cannot list origin's tags to find the highest ${MAJOR} release, so $MAJOR was not moved" >&2
    exit 1
fi
highest=$(printf '%s\n' "$tags" | sed 's|.*refs/tags/||' | grep -E "$release_re" | sort -V | tail -n 1)
if [ "$highest" != "$TAG" ]; then
    echo "$TAG is not the highest $MAJOR release (${highest:-none}); leaving $MAJOR where it is."
    exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git tag -f "$MAJOR" "$TAG"^{}
git push -f origin "refs/tags/$MAJOR"
echo "$MAJOR -> $TAG ($(git rev-parse "$MAJOR"^{}))"
