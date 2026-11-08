#!/usr/bin/env bash
#
# Gives each pushed digest the release tag, only once whatever runs between
# the build and the publish has passed.
#
# Inputs, from the environment: IMAGES (one <registry>/<owner>/<name>@<digest>
# per line), GITHUB_REF_NAME.
set -euo pipefail

TAG=${GITHUB_REF_NAME:?}
IMAGE_RE='^[^@:]+(:[0-9]+)?(/[^@:]+)+@sha256:[0-9a-f]{64}$'
count=0
while IFS= read -r image; do
    [ -n "$image" ] || continue
    # No tag before the @, so the tag added below cannot land on one, and the
    # whole 64-character digest, so a truncated one is refused here, not by docker.
    if ! [[ $image =~ $IMAGE_RE ]]; then
        echo "::error::'$image' is not <registry>/<owner>/<name>@sha256:<digest>" >&2
        exit 1
    fi
    ref=${image%@*}
    docker buildx imagetools create -t "${ref}:${TAG}" "$image"
    echo "published ${ref}:${TAG} at ${image#*@}"
    count=$((count + 1))
done <<< "${IMAGES:-}"
if [ "$count" -eq 0 ]; then
    echo "::error::no image to tag" >&2
    exit 1
fi
