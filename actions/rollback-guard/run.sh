#!/usr/bin/env bash
#
# Refuses a release once a newer vX.Y.Z is tagged. A release that deploys is
# one job, so a re-run repeats the build and the deploy; re-running an older
# tag would push its image as latest and roll production back to it. The
# newer tag's release carries this one's changes. Prereleases among the
# tags are ignored, and build metadata on the tag is.
#
# Sourced, it defines newer_than alone, for the tests. Run, it lists
# origin's tags and fails when one is newer than GITHUB_REF_NAME.
set -euo pipefail

# Prints the newest vX.Y.Z tag read on stdin that is newer than the version
# core of $1, or nothing.
newer_than() {
    local core=${1#v} newest="" t
    core=${core%%+*}
    core=${core%%-*}
    while read -r t; do
        t=${t#v}
        [[ $t =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        [ "$t" = "$core" ] && continue
        if [ "$(printf '%s\n%s\n' "$core" "$t" | sort -V | tail -n 1)" = "$t" ]; then
            if [ -z "$newest" ] || [ "$(printf '%s\n%s\n' "$newest" "$t" | sort -V | tail -n 1)" = "$t" ]; then
                newest=$t
            fi
        fi
    done
    if [ -n "$newest" ]; then
        echo "v$newest"
    fi
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

TAG=${GITHUB_REF_NAME:?}
if ! tags=$(git ls-remote --tags --refs origin 'refs/tags/v*'); then
    echo "::error::cannot list this repository's tags to check whether a newer release exists" >&2
    exit 1
fi
newer=$(printf '%s\n' "$tags" | sed 's|.*refs/tags/||' | newer_than "$TAG")
if [ -n "$newer" ]; then
    echo "::error::$newer is tagged and newer than $TAG. Releasing $TAG now would push it as latest and roll production back to it, so nothing was built or deployed. If $TAG still needs its GitHub release, publish its CHANGELOG.md section by hand with gh release create." >&2
    exit 1
fi
echo "no tag newer than $TAG"
