#!/usr/bin/env bash
#
# Tests for actions/verify-release/run.sh against stubs: `gh` serves the
# release's assets, body and CHANGELOG and answers attestation checks,
# `cosign` accepts a signature only for the repository STUB_SIGNED_FOR names
# (and only when the identity is the expected stage file), `docker` resolves
# a tag to a digest, and `go` reads the CHANGELOG section.
#
# Kept bash 3.2 compatible.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/actions/verify-release/run.sh"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_DIR/calls"
case "$1 $2" in
    "release download") while [ $# -gt 0 ]; do [ "$1" = --dir ] && cp "$STUB_DIR"/assets/* "$2"/; shift; done ;;
    "release view") cat "$STUB_DIR/body" ;;
    "attestation verify") [ -z "${STUB_NO_ATTESTATION:-}" ] ;;
    api*) cat "$STUB_DIR/CHANGELOG.md" ;;
    *) exit 64 ;;
esac
STUB
cat > "$TMP/bin/cosign" <<'STUB'
#!/usr/bin/env bash
echo "cosign $*" >> "$STUB_DIR/calls"
cmd=$1 repo="" id=""
while [ $# -gt 0 ]; do
    case "$1" in
        --certificate-github-workflow-repository) repo=$2 ;;
        --certificate-identity-regexp) id=$2 ;;
    esac
    shift
done
case "$id" in *image-build*|*image-publish*) ;; *) exit 1 ;; esac
[ -n "${STUB_FOREIGN_TOO:-}" ] && exit 0
[ "$cmd" != verify ] || [ -z "${STUB_IMAGE_UNSIGNED:-}" ] || exit 1
[ "$repo" = "${STUB_SIGNED_FOR:-latere-ai/pons}" ]
STUB
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo '{"digest":"sha256:feed"}'
STUB
cat > "$TMP/bin/go" <<'STUB'
#!/usr/bin/env bash
awk -v h="## $6" '$0 == h {on = 1; next} on && /^## / {exit} on' "$5/CHANGELOG.md" | grep . || exit 1
STUB
chmod +x "$TMP/bin"/*

new_release() {
    rm -rf "$TMP/assets"
    mkdir -p "$TMP/assets"
    : > "$TMP/calls"
    echo sbom > "$TMP/assets/sbom-ponsd.spdx.json"
    (cd "$TMP/assets" && sha256sum sbom-ponsd.spdx.json > checksums.txt && echo bundle > checksums.txt.sigstore.json)
    printf '# Changelog\n\n## v1.2.0\n\nThe notes.\n\n## v1.1.0\n\nOlder.\n' > "$TMP/CHANGELOG.md"
    printf 'The notes.\r\n' > "$TMP/body"
}
verify() {
    PATH="$TMP/bin:$PATH" STUB_DIR=$TMP GITHUB_REPOSITORY=latere-ai/pons GITHUB_REF_NAME=v1.2.0 \
        OWNER=latere-ai IMAGES=ponsd SIGNER_REPOSITORY=latere-ai/ci "$@" bash "$SCRIPT" 2>&1
}
check() {
    local name=$1 want=$2 text=$3 out rc
    shift 3
    out=$(verify "$@")
    rc=$?
    if [ "$rc" -eq "$want" ] && printf '%s' "$out" | grep -qF -- "$text"; then
        pass "$name"
    else
        fail "$name (exit $rc, want $want; output: $out)"
    fi
}

new_release
check "a release signed for its repository verifies" 0 "opens with the CHANGELOG section" env PUBLIC=true
if grep -qF "gh attestation verify oci://ghcr.io/latere-ai/ponsd@sha256:feed --repo latere-ai/pons --signer-workflow latere-ai/ci/.github/workflows/image-build.yml" "$TMP/calls"; then
    pass "a public repository's attestations are checked against the build stage"
else
    fail "a public repository's attestations are checked ($(cat "$TMP/calls"))"
fi
if grep -qF -- "--certificate-identity-regexp ^https://github\\.com/latere-ai/ci/\\.github/workflows/image-publish\\.yml@" "$TMP/calls"; then
    pass "checksums.txt is checked against the publish stage's file"
else
    fail "checksums.txt is checked against the publish stage's file ($(grep verify-blob "$TMP/calls" | head -1))"
fi

new_release
check "a private repository skips the attestations" 0 "signed for latere-ai/pons" env PUBLIC=false
if grep -q "attestation verify" "$TMP/calls"; then
    fail "a private repository asks for no attestation"
else
    pass "a private repository asks for no attestation"
fi

new_release
check "a signature that also verifies for another repository is refused" 1 "binds nothing" env STUB_FOREIGN_TOO=1

new_release
check "checksums.txt signed for another repository is refused" 1 "does not name image-publish.yml run for latere-ai/pons" env STUB_SIGNED_FOR=someone/pons

new_release
echo tampered > "$TMP/assets/sbom-ponsd.spdx.json"
check "an asset that does not match checksums.txt is refused" 1 "does not match checksums.txt"

new_release
echo extra > "$TMP/assets/extra.tar.gz"
check "an asset missing from checksums.txt is refused" 1 "extra.tar.gz is attached but not in checksums.txt"

new_release
check "an unsigned image is refused" 1 "carries no signature naming image-build.yml" env STUB_IMAGE_UNSIGNED=1

new_release
check "a missing attestation is refused" 1 "carries no attestation" env PUBLIC=true STUB_NO_ATTESTATION=1

new_release
printf 'The notes.\n\n## Smoke\n\npassed\n' > "$TMP/body"
check "evidence after the section verifies" 0 "opens with the CHANGELOG section"

new_release
printf 'Something else.\n' > "$TMP/body"
check "a body that does not open with the section is refused" 1 "does not open with its CHANGELOG section"

new_release
rm "$TMP/assets/checksums.txt.sigstore.json"
check "a release without the checksums signature is refused" 1 "no checksums.txt.sigstore.json"

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
