#!/usr/bin/env bash
#
# Puts the GitHub CLI on PATH for the steps after this one. Hosted runners
# ship gh; the self-hosted runner ships docker, git, jq and curl and nothing
# else, so there the pinned release is fetched and verified against its
# checksums file, into a directory that exists for this job alone.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../lib/versions.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/versions.sh"

if command -v gh >/dev/null 2>&1; then
    gh --version | head -n1
    exit 0
fi

dir="${RUNNER_TEMP:?}/gh-bin"
mkdir -p "$dir"
base="https://github.com/cli/cli/releases/download/v${GH_VERSION}"
archive="gh_${GH_VERSION}_linux_amd64.tar.gz"
curl -sSfL -o "$dir/$archive" "$base/$archive"
curl -sSfL -o "$dir/checksums.txt" "$base/gh_${GH_VERSION}_checksums.txt"
(cd "$dir" && grep " $archive\$" checksums.txt | sha256sum -c)
tar -xzf "$dir/$archive" -C "$dir" --strip-components=2 "gh_${GH_VERSION}_linux_amd64/bin/gh"
echo "$dir" >> "${GITHUB_PATH:?}"
"$dir/gh" --version | head -n1
