#!/usr/bin/env bash
#
# Puts kustomize on PATH for the steps after this one. The hosted runners'
# copy is whatever the image shipped, so the deploy uses the pinned release
# whenever PATH does not already hold that exact version: it is fetched and
# verified against the release's checksums file, into a directory that
# exists for this job alone.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"

# The version must end where the pin ends: v5.8.3 is not v5.8.30 or v5.8.3.1.
# The output is read into a variable first so grep -q cannot close a pipe early.
have=""
if command -v kustomize >/dev/null 2>&1; then
    have=$(kustomize version 2>/dev/null || true)
fi
if printf '%s\n' "$have" | grep -qE "v${KUSTOMIZE_VERSION//./\\.}([^0-9.]|\$)"; then
    kustomize version
    exit 0
fi

# Only a fetch needs the machine's architecture; a tool already on PATH is used as is.
# shellcheck source-path=SCRIPTDIR source=../lib/arch.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/arch.sh"

dir="${RUNNER_TEMP:?}/kustomize-bin"
mkdir -p "$dir"
# The release tag is kustomize/vX.Y.Z, its slash escaped in the path.
base="${KUSTOMIZE_BASE_URL:-https://github.com/kubernetes-sigs/kustomize/releases/download}/kustomize%2Fv${KUSTOMIZE_VERSION}"
archive="kustomize_v${KUSTOMIZE_VERSION}_linux_${TOOL_ARCH}.tar.gz"
curl -sSfL -o "$dir/$archive" "$base/$archive"
curl -sSfL -o "$dir/checksums.txt" "$base/checksums.txt"
(cd "$dir" && grep " $archive\$" checksums.txt | sha256sum -c)
tar -xzf "$dir/$archive" -C "$dir" kustomize
echo "$dir" >> "${GITHUB_PATH:?}"
"$dir/kustomize" version
