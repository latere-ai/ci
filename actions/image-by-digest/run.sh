#!/usr/bin/env bash
#
# Builds one image from the caller's checkout and pushes it by digest under
# no tag, so a release that stops before its publish step leaves an
# unreferenced digest and nothing anyone could pull by name. Then the
# candidate must report the version the tag pins, so the binary inside is
# the one compiled from the tag.
#
# The Dockerfile receives VERSION, COMMIT and DATE as build arguments, the
# build identity release-preflight read, beside any BUILD_ARGS. A
# Dockerfile that declares none of them ignores them.
#
# Inputs, from the environment: REGISTRY, OWNER, NAME, DOCKERFILE, CONTEXT,
# PLATFORMS, BUILD_ARGS (KEY=VALUE per line), VERSION_ARGS (the arguments
# that make the image print its version; empty skips the check),
# VERSION_EXPECT (the start of that output, with {name} and {tag} replaced;
# default "{name} {tag}"), GITHUB_REF_NAME, COMMIT, DATE. Writes ref and
# digest to $GITHUB_OUTPUT.
set -euo pipefail

TAG=${GITHUB_REF_NAME:?}
ref="${REGISTRY:-ghcr.io}/${OWNER:?}/${NAME:?}"

die() {
    echo "::error::$*" >&2
    exit 1
}

args=(--platform "${PLATFORMS:-linux/amd64,linux/arm64}" -f "${DOCKERFILE:-Dockerfile}"
    --build-arg "VERSION=$TAG" --build-arg "COMMIT=${COMMIT:-}" --build-arg "DATE=${DATE:-}")
while IFS= read -r arg; do
    [ -n "$arg" ] || continue
    args+=(--build-arg "$arg")
done <<< "${BUILD_ARGS:-}"

meta=$(mktemp)
trap 'rm -f "$meta"' EXIT
docker buildx build "${args[@]}" \
    --output "type=image,name=${ref},push-by-digest=true,name-canonical=true,push=true" \
    --metadata-file "$meta" "${CONTEXT:-.}" \
    || die "the build of $NAME failed, so nothing was pushed under a name"
digest=$(jq -r '."containerimage.digest" // empty' "$meta")
case "$digest" in
    sha256:*) ;;
    *) die "the build of $NAME reported no digest" ;;
esac
echo "the candidate is ${ref}@${digest}"

if [ -n "${VERSION_ARGS:-}" ]; then
    expect=${VERSION_EXPECT:-"{name} {tag}"}
    expect=${expect//\{name\}/$NAME}
    expect=${expect//\{tag\}/$TAG}
    # The arguments are words, as on a command line.
    # shellcheck disable=SC2086
    got=$(docker run --rm "${ref}@${digest}" $VERSION_ARGS 2>&1) \
        || die "${ref}@${digest} exited non-zero when asked for its version: $got"
    case "$got" in
        "$expect"*) echo "it reports: $got" ;;
        *) die "${ref}@${digest} reports '$got', and the tag pins '$expect'" ;;
    esac
fi

{
    echo "ref=$ref"
    echo "digest=$digest"
} >> "${GITHUB_OUTPUT:?}"
