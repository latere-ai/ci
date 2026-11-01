#!/usr/bin/env bash
#
# Verifies a published release the way someone installing it would, from
# what the release and the registry hold and nothing from a checkout:
#
#   1. checksums.txt is signed by image-publish.yml run for this repository,
#      and the same check naming another repository is refused;
#   2. every asset is in checksums.txt and matches it;
#   3. each image's tag resolves to a digest signed by image-build.yml run
#      for this repository, with GitHub's attestations where the repository
#      is public;
#   4. the release body opens with the tag's CHANGELOG section.
#
# Inputs, from the environment: GITHUB_REPOSITORY, GITHUB_REF_NAME, OWNER
# (the image namespace), IMAGES (image names, one per line), REGISTRY,
# SIGNER_REPOSITORY (the repository the stages' files live in), PUBLIC
# (true where attestations are expected), LATEREGATE_VERSION.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"

REPO=${GITHUB_REPOSITORY:?}
TAG=${GITHUB_REF_NAME:?}
REGISTRY=${REGISTRY:-ghcr.io}
SIGNER=${SIGNER_REPOSITORY:?}
ISSUER=https://token.actions.githubusercontent.com

die() {
    echo "::error::$*" >&2
    exit 1
}

signer_re=$(printf '%s' "$SIGNER" | sed 's/\./\\./g')
build_id="^https://github\\.com/${signer_re}/\\.github/workflows/image-build\\.yml@"
publish_id="^https://github\\.com/${signer_re}/\\.github/workflows/image-publish\\.yml@"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/assets" "$work/notes"
gh release download "$TAG" --repo "$REPO" --dir "$work/assets" \
    || die "cannot download the assets of $TAG"
cd "$work/assets"

[ -f checksums.txt ] || die "$TAG carries no checksums.txt"
[ -f checksums.txt.sigstore.json ] || die "$TAG carries no checksums.txt.sigstore.json"
cosign verify-blob --bundle checksums.txt.sigstore.json --certificate-oidc-issuer "$ISSUER" \
    --certificate-identity-regexp "$publish_id" --certificate-github-workflow-repository "$REPO" checksums.txt \
    || die "the signature over checksums.txt does not name image-publish.yml run for $REPO"
if cosign verify-blob --bundle checksums.txt.sigstore.json --certificate-oidc-issuer "$ISSUER" \
    --certificate-identity-regexp "$publish_id" --certificate-github-workflow-repository "${REPO}-elsewhere" checksums.txt \
    > /dev/null 2>&1; then
    die "the signature over checksums.txt also verifies for another repository, so the check binds nothing"
fi
echo "checksums.txt is signed for $REPO, and the same check for another repository is refused"

sha256sum -c checksums.txt || die "an asset does not match checksums.txt"
for f in *; do
    case "$f" in checksums.txt | checksums.txt.sigstore.json) continue ;; esac
    awk -v f="$f" '{sub(/^\*/, "", $2)} $2 == f {found = 1} END {exit !found}' checksums.txt \
        || die "$f is attached but not in checksums.txt"
done
echo "every asset is in checksums.txt and matches it"

count=0
while IFS= read -r name; do
    [ -n "$name" ] || continue
    ref="${REGISTRY}/${OWNER:?}/${name}"
    digest=$(docker buildx imagetools inspect "${ref}:${TAG}" --format '{{json .Manifest}}' | jq -r '.digest // empty') \
        || die "cannot resolve ${ref}:${TAG}"
    [ -n "$digest" ] || die "${ref}:${TAG} resolves to no digest"
    cosign verify "${ref}@${digest}" --certificate-oidc-issuer "$ISSUER" \
        --certificate-identity-regexp "$build_id" --certificate-github-workflow-repository "$REPO" > /dev/null \
        || die "${ref}@${digest} carries no signature naming image-build.yml run for $REPO"
    if [ "${PUBLIC:-false}" = true ]; then
        gh attestation verify "oci://${ref}@${digest}" --repo "$REPO" \
            --signer-workflow "${SIGNER}/.github/workflows/image-build.yml" > /dev/null \
            || die "${ref}@${digest} carries no attestation from image-build.yml run for $REPO"
    fi
    echo "${ref}:${TAG} is ${digest}, signed$([ "${PUBLIC:-false}" = true ] && echo " and attested") for $REPO"
    count=$((count + 1))
done <<< "${IMAGES:-}"
[ "$count" -gt 0 ] || die "no image to verify"

gh api "repos/${REPO}/contents/CHANGELOG.md?ref=${TAG}" -H 'Accept: application/vnd.github.raw' > "$work/notes/CHANGELOG.md" \
    || die "cannot read CHANGELOG.md at $TAG"
go run "latere.ai/x/ci-gate/cmd/lateregate@${LATEREGATE_VERSION}" release-notes -C "$work/notes" "$TAG" > "$work/notes.md" \
    || die "CHANGELOG.md at $TAG has no section for it"
gh release view "$TAG" --repo "$REPO" --json body --jq .body > "$work/body.md" \
    || die "cannot read the body of $TAG"
# One reading for both sides: carriage returns out, trailing blank lines off.
normalize() { tr -d '\r' < "$1" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'; }
notes=$(normalize "$work/notes.md")
body=$(normalize "$work/body.md")
case "$body" in
    "$notes" | "$notes"$'\n'*) echo "the body opens with the CHANGELOG section for $TAG" ;;
    *) die "the body of $TAG does not open with its CHANGELOG section" ;;
esac
