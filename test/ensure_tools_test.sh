#!/usr/bin/env bash
#
# Tests for actions/lib/arch.sh and for actions/ensure-gh, ensure-kubectl and
# ensure-kustomize against release trees served from file:// URLs, one tree
# per architecture: the pinned version is fetched, its
# checksum is verified and a bad one refuses, a tool already on PATH at the
# pinned version is left alone, and the version comes from versions.sh unless
# the environment names another.
#
# Kept bash 3.2 compatible.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL="$REPO_ROOT/actions/ensure-kubectl/run.sh"
KUSTOMIZE="$REPO_ROOT/actions/ensure-kustomize/run.sh"
VERSIONS="$REPO_ROOT/actions/lib/versions.sh"
ARCH="$REPO_ROOT/actions/lib/arch.sh"
GH="$REPO_ROOT/actions/ensure-gh/run.sh"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The PATH holds only the utilities the scripts use, linked from the host,
# so a kubectl or kustomize the host ships cannot answer for the fetch.
mkdir -p "$TMP/safe"
for t in bash sh curl tar gzip gunzip cat mkdir chmod grep cut head dirname basename rm sed awk tr sort uname; do
    p=$(command -v "$t") && ln -sf "$p" "$TMP/safe/$t"
done
SAFE_PATH="$TMP/safe"
# macOS's sha256sum cannot check (-c); shasum can, and the runners have the
# GNU one.
if ! sha256sum --version 2>&1 | grep -q GNU && command -v shasum > /dev/null 2>&1; then
    printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "$TMP/safe/sha256sum"
    chmod +x "$TMP/safe/sha256sum"
    ln -sf "$(command -v shasum)" "$TMP/safe/shasum"
else
    ln -sf "$(command -v sha256sum)" "$TMP/safe/sha256sum"
fi
sum() { sha256sum "$1" | cut -d' ' -f1; }

# shellcheck source=../actions/lib/versions.sh
. "$VERSIONS"
KV=$KUBECTL_VERSION
SV=$KUSTOMIZE_VERSION

# The kubectl tree: release/v<version>/bin/linux/<arch>/kubectl and its bare
# sha256 file. Each binary says which architecture it was built for.
for arch in amd64 arm64; do
    kdir="$TMP/k8s/release/v$KV/bin/linux/$arch"
    mkdir -p "$kdir"
    printf '#!/bin/sh\necho "Client Version: v%s %s"\n' "$KV" "$arch" > "$kdir/kubectl"
    sum "$kdir/kubectl" > "$kdir/kubectl.sha256"
done
kdir="$TMP/k8s/release/v$KV/bin/linux/amd64"

# The kustomize tree: <base>/kustomize%2Fv<version>/ is the directory
# kustomize/v<version> on disk.
sdir="$TMP/kz/kustomize/v$SV"
mkdir -p "$sdir"
: > "$sdir/checksums.txt"
for arch in amd64 arm64; do
    mkdir -p "$TMP/pack-$arch"
    printf '#!/bin/sh\necho "v%s %s"\n' "$SV" "$arch" > "$TMP/pack-$arch/kustomize"
    chmod +x "$TMP/pack-$arch/kustomize"
    tar -czf "$sdir/kustomize_v${SV}_linux_${arch}.tar.gz" -C "$TMP/pack-$arch" kustomize
    printf '%s  %s\n' "$(sum "$sdir/kustomize_v${SV}_linux_${arch}.tar.gz")" "kustomize_v${SV}_linux_${arch}.tar.gz" >> "$sdir/checksums.txt"
done
printf '%s  %s\n' "0000" "kustomize_v${SV}_darwin_arm64.tar.gz" >> "$sdir/checksums.txt"
archive="kustomize_v${SV}_linux_amd64.tar.gz"
cp "$sdir/checksums.txt" "$TMP/kz-checksums.txt"

# The gh tree: v<version>/gh_<version>_linux_<arch>.tar.gz holding
# gh_<version>_linux_<arch>/bin/gh, and the release's checksums file.
GV=$GH_VERSION
gdir="$TMP/gh/v$GV"
mkdir -p "$gdir"
: > "$gdir/gh_${GV}_checksums.txt"
for arch in amd64 arm64; do
    mkdir -p "$TMP/ghpack/gh_${GV}_linux_$arch/bin"
    printf '#!/bin/sh\necho "gh version %s %s"\n' "$GV" "$arch" > "$TMP/ghpack/gh_${GV}_linux_$arch/bin/gh"
    chmod +x "$TMP/ghpack/gh_${GV}_linux_$arch/bin/gh"
    tar -czf "$gdir/gh_${GV}_linux_$arch.tar.gz" -C "$TMP/ghpack" "gh_${GV}_linux_$arch"
    printf '%s  %s\n' "$(sum "$gdir/gh_${GV}_linux_$arch.tar.gz")" "gh_${GV}_linux_$arch.tar.gz" >> "$gdir/gh_${GV}_checksums.txt"
done

run() { # run SCRIPT NAME: runs with a fresh RUNNER_TEMP and GITHUB_PATH
    local script=$1 out
    rm -rf "$TMP/rt" && mkdir -p "$TMP/rt"
    : > "$TMP/path"
    # The machine is x86_64 unless a case says otherwise, so the host's own
    # architecture does not pick the archive.
    out=$(env -i PATH="$SAFE_PATH" HOME="$TMP" RUNNER_TEMP="$TMP/rt" GITHUB_PATH="$TMP/path" CI_UNAME_M=x86_64 \
        KUBECTL_BASE_URL="file://$TMP/k8s" KUSTOMIZE_BASE_URL="file://$TMP/kz" GH_BASE_URL="file://$TMP/gh" \
        "${@:2}" bash "$script" 2>&1)
    local rc=$?
    printf '%s\n' "$out"
    return $rc
}

out=$(run "$KUBECTL")
if [ $? -eq 0 ] && grep -qx "$TMP/rt/kubectl-bin" "$TMP/path" && [ -x "$TMP/rt/kubectl-bin/kubectl" ]; then
    pass "ensure-kubectl fetches the pinned release into RUNNER_TEMP and adds it to PATH"
else
    fail "ensure-kubectl did not fetch kubectl: $out"
fi

echo "0000" > "$kdir/kubectl.sha256"
out=$(run "$KUBECTL")
if [ $? -ne 0 ] && [ ! -s "$TMP/path" ]; then
    pass "ensure-kubectl refuses a binary whose checksum does not match"
else
    fail "ensure-kubectl accepted a bad checksum: $out"
fi
sum "$kdir/kubectl" > "$kdir/kubectl.sha256"

mkdir -p "$TMP/have"
printf '#!/bin/sh\necho have\n' > "$TMP/have/kubectl"
chmod +x "$TMP/have/kubectl"
out=$(run "$KUBECTL" PATH="$TMP/have:$SAFE_PATH")
if [ $? -eq 0 ] && [ ! -s "$TMP/path" ] && [ ! -e "$TMP/rt/kubectl-bin" ]; then
    pass "ensure-kubectl leaves a kubectl already on PATH alone"
else
    fail "ensure-kubectl fetched over an installed kubectl: $out"
fi

out=$(run "$KUBECTL" KUBECTL_VERSION=9.9.9)
if [ $? -ne 0 ]; then
    pass "ensure-kubectl takes the version from the environment (9.9.9 is not served)"
else
    fail "ensure-kubectl ignored KUBECTL_VERSION: $out"
fi

out=$(run "$KUSTOMIZE")
if [ $? -eq 0 ] && grep -qx "$TMP/rt/kustomize-bin" "$TMP/path" && [ -x "$TMP/rt/kustomize-bin/kustomize" ]; then
    pass "ensure-kustomize fetches the pinned release into RUNNER_TEMP and adds it to PATH"
else
    fail "ensure-kustomize did not fetch kustomize: $out"
fi

printf '%s  %s\n' "0000" "$archive" > "$sdir/checksums.txt"
out=$(run "$KUSTOMIZE")
if [ $? -ne 0 ] && [ ! -s "$TMP/path" ]; then
    pass "ensure-kustomize refuses an archive whose checksum does not match"
else
    fail "ensure-kustomize accepted a bad checksum: $out"
fi
cp "$TMP/kz-checksums.txt" "$sdir/checksums.txt"

printf '#!/bin/sh\necho "v%s"\n' "$SV" > "$TMP/have/kustomize"
chmod +x "$TMP/have/kustomize"
out=$(run "$KUSTOMIZE" PATH="$TMP/have:$SAFE_PATH")
if [ $? -eq 0 ] && [ ! -s "$TMP/path" ]; then
    pass "ensure-kustomize leaves a kustomize at the pinned version alone"
else
    fail "ensure-kustomize fetched over the pinned version: $out"
fi
printf '#!/bin/sh\necho "v1.0.0"\n' > "$TMP/have/kustomize"
out=$(run "$KUSTOMIZE" PATH="$TMP/have:$SAFE_PATH")
if [ $? -eq 0 ] && grep -qx "$TMP/rt/kustomize-bin" "$TMP/path"; then
    pass "ensure-kustomize fetches the pinned version over another one"
else
    fail "ensure-kustomize kept a kustomize at another version: $out"
fi

# The archive is the one for the machine: arm64 on aarch64 and arm64, amd64
# on x86_64 and amd64. Each fetched tool reports the architecture it was
# built for.
for m in aarch64:arm64 arm64:arm64 x86_64:amd64 amd64:amd64; do
    machine=${m%%:*}
    want=${m##*:}
    out=$(run "$KUBECTL" CI_UNAME_M="$machine") && "$TMP/rt/kubectl-bin/kubectl" | grep -qF " $want"
    if [ $? -eq 0 ]; then pass "ensure-kubectl fetches the $want build on $machine"; else fail "ensure-kubectl on $machine did not fetch $want: $out"; fi
    out=$(run "$KUSTOMIZE" CI_UNAME_M="$machine") && "$TMP/rt/kustomize-bin/kustomize" | grep -qF " $want"
    if [ $? -eq 0 ]; then pass "ensure-kustomize fetches the $want build on $machine"; else fail "ensure-kustomize on $machine did not fetch $want: $out"; fi
    out=$(run "$GH" CI_UNAME_M="$machine") && "$TMP/rt/gh-bin/gh" --version | grep -qF " $want"
    if [ $? -eq 0 ]; then pass "ensure-gh fetches the $want build on $machine"; else fail "ensure-gh on $machine did not fetch $want: $out"; fi
done
for script in "$GH" "$KUBECTL" "$KUSTOMIZE"; do
    out=$(run "$script" CI_UNAME_M=riscv64)
    if [ $? -ne 0 ] && printf '%s' "$out" | grep -qF "riscv64" && [ ! -s "$TMP/path" ]; then
        pass "$(basename "$(dirname "$script")") refuses an unknown architecture and names it"
    else
        fail "$(basename "$(dirname "$script")") did not refuse riscv64: $out"
    fi
done
# A tool already on PATH is used even on a machine the mapping does not know.
out=$(run "$KUBECTL" PATH="$TMP/have:$SAFE_PATH" CI_UNAME_M=riscv64)
if [ $? -eq 0 ] && [ ! -s "$TMP/path" ]; then
    pass "an installed kubectl needs no architecture"
else
    fail "an installed kubectl was refused on an unknown architecture: $out"
fi

# arch.sh itself, sourced: TOOL_ARCH for each spelling, a failure otherwise.
for m in x86_64:amd64 amd64:amd64 aarch64:arm64 arm64:arm64; do
    got=$(CI_UNAME_M=${m%%:*} bash -c '. "$1" && echo "$TOOL_ARCH"' _ "$ARCH" 2>&1)
    if [ "$got" = "${m##*:}" ]; then pass "arch.sh maps ${m%%:*} to ${m##*:}"; else fail "arch.sh mapped ${m%%:*} to '$got'"; fi
done
got=$(CI_UNAME_M=sparc64 bash -c '. "$1" && echo "$TOOL_ARCH"' _ "$ARCH" 2>&1)
if [ $? -ne 0 ] && printf '%s' "$got" | grep -qF sparc64; then
    pass "arch.sh fails on an unknown machine and names it"
else
    fail "arch.sh accepted sparc64: $got"
fi

# The pins are explicit versions, never latest.
if grep -qE '^KUBECTL_VERSION=\$\{KUBECTL_VERSION:-[0-9]+\.[0-9]+\.[0-9]+\}$' "$VERSIONS" \
    && grep -qE '^KUSTOMIZE_VERSION=\$\{KUSTOMIZE_VERSION:-[0-9]+\.[0-9]+\.[0-9]+\}$' "$VERSIONS" \
    && grep -qF 'echo "kubectl=$KUBECTL_VERSION"' "$VERSIONS" \
    && grep -qF 'echo "kustomize=$KUSTOMIZE_VERSION"' "$VERSIONS"; then
    pass "versions.sh pins kubectl and kustomize and writes them as outputs"
else
    fail "versions.sh does not pin kubectl and kustomize"
fi

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
