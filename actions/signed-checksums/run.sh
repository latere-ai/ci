#!/usr/bin/env bash
#
# checksums.txt over every file in DIR, and one Sigstore bundle carrying its
# signature and certificate, so a reader verifies every asset by verifying
# one file. A checksums.txt or bundle already in DIR is replaced, not summed.
#
# Inputs, from the environment: DIR.
set -euo pipefail

cd "${DIR:?}"
files=()
while IFS= read -r f; do
    files+=("$f")
done < <(find . -maxdepth 1 -type f ! -name checksums.txt ! -name checksums.txt.sigstore.json | sed 's|^\./||' | LC_ALL=C sort)
if [ "${#files[@]}" -eq 0 ]; then
    echo "::error::$DIR holds no file to sum" >&2
    exit 1
fi
sha256sum "${files[@]}" > checksums.txt
cat checksums.txt
rm -f checksums.txt.sigstore.json
cosign sign-blob --yes --bundle checksums.txt.sigstore.json checksums.txt
