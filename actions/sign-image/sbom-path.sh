#!/usr/bin/env bash
#
# Names the bill of materials of an image and makes its directory: <dir>/
# sbom-<image name>.spdx.json, or .cdx.json for a CycloneDX format.
#
# Inputs, from the environment: REF (<registry>/<owner>/<name>), SBOM_DIR,
# SBOM_FORMAT. Writes path to $GITHUB_OUTPUT.
set -euo pipefail

name=${REF:?}
name=${name##*/}
case "${SBOM_FORMAT:?}" in
    spdx-json*) ext=spdx.json ;;
    cyclonedx-json*) ext=cdx.json ;;
    *) echo "::error::sbom_format '$SBOM_FORMAT' is neither spdx-json nor cyclonedx-json" >&2; exit 1 ;;
esac
mkdir -p "${SBOM_DIR:?}"
echo "path=${SBOM_DIR}/sbom-${name}.${ext}" >> "${GITHUB_OUTPUT:?}"
