#!/usr/bin/env bash
#
# The tool versions the shared steps install, defined once. Each is explicit
# rather than "latest" so a run cannot pick up a build published after these
# steps were reviewed. A non-empty value already in the environment wins, for
# a caller that pins another version through a stage's input.
#
# Sourced, it sets the variables. Run, it also writes them to
# $GITHUB_OUTPUT as cosign, syft, gh, lateregate, kubectl and kustomize, for
# an action whose `with:` needs one. kubectl and gh are written without the
# leading v, as their download paths spell them.

COSIGN_VERSION=${COSIGN_VERSION:-v3.1.4}
SYFT_VERSION=${SYFT_VERSION:-v1.55.0}
GH_VERSION=${GH_VERSION:-2.103.3}
LATEREGATE_VERSION=${LATEREGATE_VERSION:-v0.61.0}
KUBECTL_VERSION=${KUBECTL_VERSION:-1.35.1}
KUSTOMIZE_VERSION=${KUSTOMIZE_VERSION:-5.8.3}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    {
        echo "cosign=$COSIGN_VERSION"
        echo "syft=$SYFT_VERSION"
        echo "gh=$GH_VERSION"
        echo "lateregate=$LATEREGATE_VERSION"
        echo "kubectl=$KUBECTL_VERSION"
        echo "kustomize=$KUSTOMIZE_VERSION"
    } >> "${GITHUB_OUTPUT:?}"
fi
