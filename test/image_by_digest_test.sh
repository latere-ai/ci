#!/usr/bin/env bash
#
# Tests for actions/image-by-digest/run.sh against a stub `docker` that
# records its arguments, writes the build metadata a push by digest
# reports, and answers `docker run` with STUB_VERSION. Like the real one,
# `docker run` of an image not pulled first prints its pull progress on
# stderr before the binary's output.
#
# Kept bash 3.2 compatible.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/actions/image-by-digest/run.sh"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/docker.calls"
case "$1" in
    buildx)
        [ -n "${STUB_BUILD_FAIL:-}" ] && exit 1
        while [ $# -gt 0 ]; do
            if [ "$1" = --metadata-file ]; then
                printf '{"containerimage.digest":"%s"}\n' "${STUB_DIGEST-sha256:abc123}" > "$2"
            fi
            shift
        done
        ;;
    pull)
        [ -n "${STUB_PULL_FAIL:-}" ] && exit 1
        touch "$STUB_DIR/pulled"
        ;;
    run)
        [ -f "$STUB_DIR/pulled" ] || echo "Unable to find image '$3' locally" >&2
        echo "${STUB_VERSION:-}"
        ;;
esac
STUB
chmod +x "$TMP/bin/docker"

# run_case NAME WANT_RC WANT_TEXT, with environment from the caller.
run_case() {
    local name=$1 want=$2 text=$3 out rc
    : > "$TMP/docker.calls"
    rm -f "$TMP/pulled"
    : > "$TMP/out"
    out=$(PATH="$TMP/bin:$PATH" STUB_DIR=$TMP GITHUB_OUTPUT="$TMP/out" GITHUB_REF_NAME=v1.2.0 \
        OWNER=latere-ai NAME=ponsd COMMIT=abc1234 DATE=2026-11-01T00:00:00Z bash "$SCRIPT" 2>&1)
    rc=$?
    if [ "$rc" -eq "$want" ] && printf '%s' "$out" | grep -qF -- "$text"; then
        pass "$name"
    else
        fail "$name (exit $rc, want $want; output: $out)"
    fi
}

VERSION_ARGS=version STUB_VERSION="ponsd v1.2.0 (abc1234)" run_case "a candidate reporting the tag passes" 0 "it reports: ponsd v1.2.0"
if grep -qxF "digest=sha256:abc123" "$TMP/out" && grep -qxF "ref=ghcr.io/latere-ai/ponsd" "$TMP/out"; then
    pass "the ref and digest are outputs"
else
    fail "the ref and digest are outputs ($(tr '\n' ' ' < "$TMP/out"))"
fi
if grep -qF "push-by-digest=true" "$TMP/docker.calls" && grep -qF "name=ghcr.io/latere-ai/ponsd," "$TMP/docker.calls"; then
    pass "the image is pushed by digest under no tag"
else
    fail "the image is pushed by digest under no tag ($(cat "$TMP/docker.calls"))"
fi
if grep -qF -- "--build-arg VERSION=v1.2.0 --build-arg COMMIT=abc1234 --build-arg DATE=2026-11-01T00:00:00Z" "$TMP/docker.calls"; then
    pass "the build identity reaches the Dockerfile"
else
    fail "the build identity reaches the Dockerfile ($(cat "$TMP/docker.calls"))"
fi
if grep -qF -- "--platform linux/amd64,linux/arm64" "$TMP/docker.calls"; then
    pass "both platforms build by default"
else
    fail "both platforms build by default"
fi
if grep -qxF "pull --quiet ghcr.io/latere-ai/ponsd@sha256:abc123" "$TMP/docker.calls"; then
    pass "the version check pulls the pushed digest quietly first"
else
    fail "the version check pulls the pushed digest quietly first ($(cat "$TMP/docker.calls"))"
fi
if grep -qF "run --rm ghcr.io/latere-ai/ponsd@sha256:abc123 version" "$TMP/docker.calls"; then
    pass "the version check runs the pushed digest"
else
    fail "the version check runs the pushed digest ($(cat "$TMP/docker.calls"))"
fi

VERSION_ARGS=version STUB_VERSION="ponsd v1.1.9 (old)" run_case "a candidate reporting another version is refused" 1 "reports 'ponsd v1.1.9 (old)', and the tag pins 'ponsd v1.2.0'"

VERSION_ARGS=-version VERSION_EXPECT="luxd {tag}" STUB_VERSION="luxd v1.2.0" run_case "version_expect names a binary other than the image" 0 "it reports: luxd v1.2.0"

VERSION_ARGS="" run_case "an empty version_args skips the check" 0 "the candidate is ghcr.io/latere-ai/ponsd@sha256:abc123"
if grep -q "^run " "$TMP/docker.calls"; then
    fail "an empty version_args runs nothing"
else
    pass "an empty version_args runs nothing"
fi

BUILD_ARGS=$'GOFLAGS=-mod=mod\nEXTRA=1' PLATFORMS=linux/amd64 run_case "extra build args and one platform pass through" 0 "the candidate"
if grep -qF -- "--platform linux/amd64 " "$TMP/docker.calls" && grep -qF -- "--build-arg GOFLAGS=-mod=mod --build-arg EXTRA=1" "$TMP/docker.calls"; then
    pass "extra build args and one platform reach buildx"
else
    fail "extra build args and one platform reach buildx ($(cat "$TMP/docker.calls"))"
fi

VERSION_ARGS=version STUB_VERSION="ponsd v1.2.0 (abc1234)" STUB_PULL_FAIL=1 run_case "a candidate that cannot be pulled is refused" 1 "could not pull ghcr.io/latere-ai/ponsd@sha256:abc123"

STUB_BUILD_FAIL=1 run_case "a failed build is refused" 1 "the build of ponsd failed"
STUB_DIGEST="" run_case "a build that reports no digest is refused" 1 "reported no digest"

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
