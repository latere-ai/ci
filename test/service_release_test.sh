#!/usr/bin/env bash
#
# Grep assertions over service-release.yml for the runner contract: every
# job routes through inputs.runs_on, every setup-go caches only on a hosted
# runner, and the tools a hosted runner ships but the self-hosted VM does
# not (Node, kubectl, gh) are set up or fetched at a pinned version rather
# than assumed. A job left on a bare ubuntu-latest would keep one leg of a
# release on hosted minutes after a consumer moved to its own runner.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/service-release.yml"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# Every uses: is SHA-pinned, as in every other workflow here.
if grep -E '^\s*-?\s*uses:' "$WORKFLOW" | grep -vE '@[0-9a-f]{40}' >/dev/null; then
    fail "an action is not pinned to a commit SHA"
else
    pass "every action is pinned to a commit SHA"
fi

# Every job runs where runs_on says. A bare ubuntu-latest on a job would
# pin that job to hosted runners.
fixed=$(grep -cE '^\s+runs-on: ubuntu-latest$' "$WORKFLOW")
routed=$(grep -cF 'runs-on: ${{ inputs.runs_on }}' "$WORKFLOW")
jobs=$(grep -cE '^  [a-z-]+:$' "$WORKFLOW")
if [ "$fixed" -eq 0 ] && [ "$routed" -eq "$jobs" ]; then
    pass "all $jobs jobs run on inputs.runs_on"
else
    fail "runs_on does not route every job (jobs=$jobs fixed=$fixed routed=$routed)"
fi

# setup-go's cache restore is for hosted runners, which start empty. On the
# self-hosted machine the module cache is already there and the restore
# fails file by file, so every setup-go step either gates it on a hosted
# label or turns it off.
setups=$(grep -c 'uses: actions/setup-go' "$WORKFLOW")
gated=$(grep -cE "cache: (false|\\$\\{\\{ startsWith\\(inputs.runs_on, 'ubuntu-'\\))" "$WORKFLOW")
if [ "$setups" -eq "$gated" ]; then
    pass "every setup-go caches only on a hosted runner"
else
    fail "a setup-go step restores its cache unconditionally (setups=$setups gated=$gated)"
fi

# bun's node shim is not Node: vue-tsc under it checks zero .vue files and
# says nothing. Every setup-bun is preceded by a real setup-node.
buns=$(grep -c 'uses: oven-sh/setup-bun' "$WORKFLOW")
nodes=$(grep -c 'uses: actions/setup-node' "$WORKFLOW")
if [ "$buns" -eq "$nodes" ]; then
    pass "every setup-bun has a setup-node beside it"
else
    fail "a bun step runs without real Node (bun=$buns node=$nodes)"
fi

# kubectl and gh are fetched at the pinned input version, checksum-verified,
# only when the runner has none. A fetch at `latest` or without a checksum
# would break the supply-chain rule the README states.
for tool in kubectl gh; do
    if grep -qF "name: Ensure $tool" "$WORKFLOW" \
        && grep -qF "if command -v $tool >/dev/null 2>&1; then" "$WORKFLOW" \
        && grep -qF "inputs.${tool}_version" "$WORKFLOW"; then
        pass "$tool is fetched at inputs.${tool}_version only when missing"
    else
        fail "$tool bootstrap step is missing or unpinned"
    fi
done
if grep -A22 'name: Ensure kubectl' "$WORKFLOW" | grep -q 'sha256sum -c' \
    && grep -A22 'name: Ensure gh' "$WORKFLOW" | grep -q 'sha256sum -c'; then
    pass "both tool fetches verify a sha256"
else
    fail "a tool fetch skips checksum verification"
fi
if grep -E 'dl.k8s.io|cli/cli/releases' "$WORKFLOW" | grep -q 'latest'; then
    fail "a tool is fetched at latest"
else
    pass "no tool is fetched at latest"
fi

# Build products stay in one job. Artifact storage quota must not prevent a
# checked frontend from reaching the binary or its image.
build=$(sed -n '/^  build-image:/,/^  deploy:/p' "$WORKFLOW")
if grep -qE '^  build-(frontend|binary):' "$WORKFLOW" \
    || printf '%s' "$build" | grep -qE 'actions/(upload|download)-artifact@'; then
    fail "release build still transfers required artifacts between jobs"
else
    pass "release builds without artifact storage"
fi
for step in 'name: Typecheck + build' 'name: Capture frontend build evidence' 'name: Embed frontend' 'name: Vet' 'name: Build shippable binary' 'name: Build and push'; do
    if printf '%s' "$build" | grep -qF "$step"; then
        pass "image build retains $step"
    else
        fail "image build loses $step"
    fi
done
if grep -qF 'EXPECTED_ASSET: ${{ needs.build-image.outputs.asset }}' "$WORKFLOW"; then
    pass "live smoke verifies the image build's exact frontend asset"
else
    fail "live smoke is not wired to the image build's asset"
fi

# The deploy job authenticates as the consumer's rollout identity, a
# namespace-bound ServiceAccount, through DEPLOY_KUBECONFIG. The file goes
# under RUNNER_TEMP at mode 600: on the self-hosted runner a kubeconfig under
# $HOME would outlive the job and be readable from the other slot.
deploy=$(sed -n '/^  deploy:/,/^  smoke:/p' "$WORKFLOW")
if printf '%s' "$deploy" | grep -qF 'KUBECONFIG_CONTENT: ${{ secrets.DEPLOY_KUBECONFIG }}' \
    && printf '%s' "$deploy" | grep -qF 'install -m 700 -d "$RUNNER_TEMP/kube"' \
    && printf '%s' "$deploy" | grep -qF 'chmod 600 "$RUNNER_TEMP/kube/config"' \
    && printf '%s' "$deploy" | grep -qF 'echo "KUBECONFIG=$RUNNER_TEMP/kube/config" >> "$GITHUB_ENV"'; then
    pass "deploy writes DEPLOY_KUBECONFIG to a 600 file under RUNNER_TEMP"
else
    fail "deploy does not write DEPLOY_KUBECONFIG to a private file under RUNNER_TEMP"
fi
if grep -qE 'DO_TOKEN|action-doctl|doctl ' "$WORKFLOW"; then
    fail "the workflow still reaches for a DigitalOcean credential"
else
    pass "the workflow holds no DigitalOcean credential"
fi
if grep -A3 '^      DEPLOY_KUBECONFIG:' "$WORKFLOW" | grep -qE '^\s+description:'; then
    pass "DEPLOY_KUBECONFIG is a declared workflow_call secret"
else
    fail "DEPLOY_KUBECONFIG is not declared, so 'secrets: inherit' cannot deliver it"
fi

if [ "$FAILURES" -gt 0 ]; then
    exit 1
fi
