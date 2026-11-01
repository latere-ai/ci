#!/usr/bin/env bash
#
# The tool versions the shared steps install, defined once. Each is explicit
# rather than "latest" so a run cannot pick up a build published after these
# steps were reviewed. A non-empty value already in the environment wins, for
# a caller that pins another version through a stage's input.
#
# Sourced, it sets the four variables. Run, it also writes them to
# $GITHUB_OUTPUT as cosign, syft, gh and lateregate, for an action whose
# `with:` needs one.

COSIGN_VERSION=${COSIGN_VERSION:-v3.0.6}
SYFT_VERSION=${SYFT_VERSION:-v1.51.1}
GH_VERSION=${GH_VERSION:-2.100.0}
LATEREGATE_VERSION=${LATEREGATE_VERSION:-v0.29.0}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    {
        echo "cosign=$COSIGN_VERSION"
        echo "syft=$SYFT_VERSION"
        echo "gh=$GH_VERSION"
        echo "lateregate=$LATEREGATE_VERSION"
    } >> "${GITHUB_OUTPUT:?}"
fi
