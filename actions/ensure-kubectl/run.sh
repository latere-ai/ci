#!/usr/bin/env bash
#
# Puts kubectl on PATH for the steps after this one. Hosted runners ship
# kubectl; the self-hosted runner does not, so there the pinned release is
# fetched with its published sha256, into a directory that exists for this
# job alone.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"

if command -v kubectl >/dev/null 2>&1; then
    kubectl version --client
    exit 0
fi

# Only a fetch needs the machine's architecture; a tool already on PATH is used as is.
# shellcheck source-path=SCRIPTDIR source=../lib/arch.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/arch.sh"

dir="${RUNNER_TEMP:?}/kubectl-bin"
mkdir -p "$dir"
base="${KUBECTL_BASE_URL:-https://dl.k8s.io}/release/v${KUBECTL_VERSION}/bin/linux/${TOOL_ARCH}"
curl -sSfL -o "$dir/kubectl" "$base/kubectl"
curl -sSfL -o "$dir/kubectl.sha256" "$base/kubectl.sha256"
echo "$(cat "$dir/kubectl.sha256")  $dir/kubectl" | sha256sum -c
chmod +x "$dir/kubectl"
echo "$dir" >> "${GITHUB_PATH:?}"
"$dir/kubectl" version --client
