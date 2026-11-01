#!/usr/bin/env bash
#
# Tests for the scripts of actions/tag-images, actions/signed-checksums and
# actions/sign-image (the bill-of-materials path), run against stub
# `docker` and `cosign` that record their arguments.
#
# Kept bash 3.2 compatible.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
for tool in docker cosign; do
    cat > "$TMP/bin/$tool" <<STUB
#!/usr/bin/env bash
echo "$tool \$*" >> "\$STUB_DIR/calls"
if [ "$tool" = cosign ]; then
    while [ \$# -gt 0 ]; do
        [ "\$1" = --bundle ] && echo bundle > "\$2"
        shift
    done
fi
STUB
    chmod +x "$TMP/bin/$tool"
done
export STUB_DIR=$TMP PATH="$TMP/bin:$PATH"

# tag-images
: > "$TMP/calls"
if IMAGES=$'ghcr.io/latere-ai/lux@sha256:aaa\nghcr.io/latere-ai/lux-stubs@sha256:bbb\n' GITHUB_REF_NAME=v1.2.0 \
    bash "$REPO_ROOT/actions/tag-images/run.sh" > /dev/null 2>&1 \
    && grep -qxF "docker buildx imagetools create -t ghcr.io/latere-ai/lux:v1.2.0 ghcr.io/latere-ai/lux@sha256:aaa" "$TMP/calls" \
    && grep -qxF "docker buildx imagetools create -t ghcr.io/latere-ai/lux-stubs:v1.2.0 ghcr.io/latere-ai/lux-stubs@sha256:bbb" "$TMP/calls"; then
    pass "tag-images tags every digest with the release tag"
else
    fail "tag-images tags every digest with the release tag ($(cat "$TMP/calls"))"
fi
if out=$(IMAGES="ghcr.io/latere-ai/lux:latest" GITHUB_REF_NAME=v1.2.0 bash "$REPO_ROOT/actions/tag-images/run.sh" 2>&1); then
    fail "tag-images refuses a reference that is not by digest"
elif printf '%s' "$out" | grep -qF "is not <registry>/<owner>/<name>@sha256:<digest>"; then
    pass "tag-images refuses a reference that is not by digest"
else
    fail "tag-images refuses a reference that is not by digest ($out)"
fi
if IMAGES="" GITHUB_REF_NAME=v1.2.0 bash "$REPO_ROOT/actions/tag-images/run.sh" > /dev/null 2>&1; then
    fail "tag-images refuses an empty list"
else
    pass "tag-images refuses an empty list"
fi

# signed-checksums
: > "$TMP/calls"
mkdir -p "$TMP/dist"
echo a > "$TMP/dist/b-archive.tar.gz"
echo b > "$TMP/dist/a-sbom.spdx.json"
echo stale > "$TMP/dist/checksums.txt"
echo stale > "$TMP/dist/checksums.txt.sigstore.json"
if DIR="$TMP/dist" bash "$REPO_ROOT/actions/signed-checksums/run.sh" > /dev/null 2>&1; then
    names=$(awk '{print $2}' "$TMP/dist/checksums.txt" | tr '\n' ' ')
    if [ "$names" = "a-sbom.spdx.json b-archive.tar.gz " ]; then
        pass "signed-checksums sums every file, sorted, and not its own outputs"
    else
        fail "signed-checksums sums every file, sorted, and not its own outputs (got: $names)"
    fi
    if (cd "$TMP/dist" && sha256sum -c checksums.txt > /dev/null 2>&1); then
        pass "checksums.txt verifies"
    else
        fail "checksums.txt verifies"
    fi
    if grep -qxF "cosign sign-blob --yes --bundle checksums.txt.sigstore.json checksums.txt" "$TMP/calls" \
        && [ "$(cat "$TMP/dist/checksums.txt.sigstore.json")" = bundle ]; then
        pass "signed-checksums signs checksums.txt into one bundle, replacing a stale one"
    else
        fail "signed-checksums signs checksums.txt into one bundle ($(cat "$TMP/calls"))"
    fi
else
    fail "signed-checksums runs"
fi
mkdir -p "$TMP/empty"
if DIR="$TMP/empty" bash "$REPO_ROOT/actions/signed-checksums/run.sh" > /dev/null 2>&1; then
    fail "signed-checksums refuses an empty directory"
else
    pass "signed-checksums refuses an empty directory"
fi

# sign-image's bill-of-materials path
sbom_path() {
    : > "$TMP/out"
    REF=$1 SBOM_DIR="$TMP/sboms" SBOM_FORMAT=$2 GITHUB_OUTPUT="$TMP/out" \
        bash "$REPO_ROOT/actions/sign-image/sbom-path.sh" > /dev/null 2>&1 || return 1
    sed -n 's/^path=//p' "$TMP/out"
}
if [ "$(sbom_path ghcr.io/latere-ai/ponsd spdx-json)" = "$TMP/sboms/sbom-ponsd.spdx.json" ] && [ -d "$TMP/sboms" ]; then
    pass "an SPDX bill is named sbom-<image>.spdx.json in a directory that exists"
else
    fail "an SPDX bill is named sbom-<image>.spdx.json"
fi
if [ "$(sbom_path ghcr.io/latere-ai/platformd cyclonedx-json@1.6)" = "$TMP/sboms/sbom-platformd.cdx.json" ]; then
    pass "a CycloneDX bill is named .cdx.json"
else
    fail "a CycloneDX bill is named .cdx.json"
fi
if sbom_path ghcr.io/latere-ai/ponsd table > /dev/null; then
    fail "an unknown bill format is refused"
else
    pass "an unknown bill format is refused"
fi

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
