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

# bun's node shim is not Node: a frontend tool under it can check nothing
# and say nothing. Every setup-bun is preceded by a real setup-node.
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

# A release is one job. On a busy self-hosted runner each job waits for a
# slot of its own, so stages split into jobs wait once per stage; one job
# waits once. Build products stay on the runner, so artifact storage quota
# cannot stop a checked frontend from reaching the binary or its image.
if [ "$jobs" -eq 1 ]; then
    pass "the release is one job"
else
    fail "the release is split into $jobs jobs, each waiting for a runner"
fi
if grep -qF 'actions/download-artifact@' "$WORKFLOW" \
    || [ "$(grep -c 'actions/upload-artifact@' "$WORKFLOW")" -ne 1 ]; then
    fail "release moves build products through artifact storage"
else
    pass "release builds without artifact storage"
fi
for step in 'name: Typecheck + build' 'name: Capture frontend build evidence' 'name: Embed frontend' 'name: Vet' 'name: Build shippable binary' 'name: Build and push'; do
    if grep -qF "$step" "$WORKFLOW"; then
        pass "image build retains $step"
    else
        fail "image build loses $step"
    fi
done
if grep -qF 'EXPECTED_ASSET: ${{ steps.evidence.outputs.asset }}' "$WORKFLOW"; then
    pass "live smoke verifies the image build's exact frontend asset"
else
    fail "live smoke is not wired to the image build's asset"
fi

# The steps run in the order the stages need: nothing deploys before the
# image is pushed, nothing is smoked before the roll, and the release is
# published last, after the smoke and any CLI build.
prev=0
order_ok=1
for step in 'name: SBOM of the source' 'name: Install' 'name: Build and push' 'name: Sign the image' 'name: SBOM of the image' 'name: Write the kubeconfig' 'name: Apply manifests' 'name: Roll new image' 'name: After the roll' 'name: Drop the kubeconfig' 'name: Smoke production release' 'name: Build CLI binaries' 'name: Publish release with evidence'; do
    line=$(grep -nF "$step" "$WORKFLOW" | head -1 | cut -d: -f1)
    if [ -z "$line" ] || [ "$line" -le "$prev" ]; then
        fail "$step is missing or out of order"
        order_ok=0
    fi
    prev=${line:-$prev}
done
[ "$order_ok" -eq 1 ] && pass "source SBOM, build, signing, deploy, smoke, CLI build and publish run in order"

# The image is signed by the digest the push produced, with the pinned
# cosign, and the job's token can mint the OIDC identity keyless signing
# trades for a certificate. The workflow-level block is the job's, since
# the job sets none of its own.
if grep -A4 'name: Sign the image' "$WORKFLOW" | grep -qF 'DIGEST: ${{ steps.build.outputs.digest }}' \
    && grep -A4 'name: Sign the image' "$WORKFLOW" | grep -qF 'cosign sign --yes "${IMAGE}@${DIGEST}"' \
    && grep -A2 'sigstore/cosign-installer@' "$WORKFLOW" | grep -qF 'cosign-release: ${{ inputs.cosign_version }}'; then
    pass "the image is signed by its pushed digest with the pinned cosign"
else
    fail "the signing step does not sign the pushed digest with inputs.cosign_version"
fi
perms=$(sed -n '/^permissions:/,/^jobs:/p' "$WORKFLOW")
if printf '%s\n' "$perms" | grep -qx '  id-token: write' && printf '%s\n' "$perms" | grep -qx '  attestations: write'; then
    pass "the job may mint an OIDC token and write attestations"
else
    fail "id-token or attestations write is missing from the workflow permissions"
fi

# Every SBOM step runs the pinned syft and keeps its file on the runner for
# the release, rather than uploading a run artifact of its own.
sboms=$(grep -cF 'uses: anchore/sbom-action@' "$WORKFLOW")
pinned=$(grep -A8 'uses: anchore/sbom-action@' "$WORKFLOW" | grep -cF 'syft-version: ${{ inputs.syft_version }}')
quiet=$(grep -A8 'uses: anchore/sbom-action@' "$WORKFLOW" | grep -cF 'upload-artifact: false')
if [ "$sboms" -eq 2 ] && [ "$pinned" -eq 2 ] && [ "$quiet" -eq 2 ]; then
    pass "both SBOM steps run inputs.syft_version and upload no artifact"
else
    fail "an SBOM step is missing, unpinned or uploads an artifact (steps=$sboms pinned=$pinned quiet=$quiet)"
fi

# GitHub's attestations need Enterprise Cloud in a private repository, and
# an attestation's body goes into the public Sigstore log, so both attest
# steps run for a public caller only.
attests=$(grep -cE 'uses: actions/attest-(sbom|build-provenance)@' "$WORKFLOW")
gated=$(grep -B1 -E 'uses: actions/attest-(sbom|build-provenance)@' "$WORKFLOW" | grep -cF 'if: ${{ !github.event.repository.private }}')
if [ "$attests" -eq 2 ] && [ "$gated" -eq 2 ]; then
    pass "attestations run only for a public caller"
else
    fail "an attest step runs for a private caller (attests=$attests gated=$gated)"
fi

# A caller copying an example must grant what the pipeline asks for, or
# the run fails before the job starts.
for example in "$REPO_ROOT"/examples/service-release*.yml; do
    if grep -qx '  id-token: write' "$example" && grep -qx '  attestations: write' "$example"; then
        pass "$(basename "$example") grants id-token and attestations write"
    else
        fail "$(basename "$example") does not grant id-token and attestations write"
    fi
done

# The production environment holds the whole job, so an approval it
# requires comes before anything is built or deployed.
if sed -n '/^  release:/,/steps:/p' "$WORKFLOW" | grep -qE '^      name: production$'; then
    pass "the job runs in the production environment"
else
    fail "the job is not in the production environment"
fi

# The deploy authenticates as the consumer's rollout identity, a
# namespace-bound ServiceAccount, through DEPLOY_KUBECONFIG. The file goes
# under RUNNER_TEMP at mode 600: on the self-hosted runner a kubeconfig under
# $HOME would outlive the job and be readable from the other slot. Once the
# deploy steps are done it is removed, even when one of them failed, so the
# smoke script, the CLI build and the note reader never hold it.
deploy=$(sed -n '/name: Write the kubeconfig/,/name: Mint smoke token/p' "$WORKFLOW")
if printf '%s' "$deploy" | grep -qF 'KUBECONFIG_CONTENT: ${{ secrets.DEPLOY_KUBECONFIG }}' \
    && printf '%s' "$deploy" | grep -qF 'install -m 700 -d "$RUNNER_TEMP/kube"' \
    && printf '%s' "$deploy" | grep -qF 'chmod 600 "$RUNNER_TEMP/kube/config"' \
    && printf '%s' "$deploy" | grep -qF 'echo "KUBECONFIG=$RUNNER_TEMP/kube/config" >> "$GITHUB_ENV"'; then
    pass "deploy writes DEPLOY_KUBECONFIG to a 600 file under RUNNER_TEMP"
else
    fail "deploy does not write DEPLOY_KUBECONFIG to a private file under RUNNER_TEMP"
fi
drop=$(sed -n '/name: Drop the kubeconfig/,/name: Mint smoke token/p' "$WORKFLOW")
if printf '%s' "$drop" | grep -qF 'if: ${{ always() }}' \
    && printf '%s' "$drop" | grep -qF 'rm -rf "$RUNNER_TEMP/kube"' \
    && printf '%s' "$drop" | grep -qF 'echo "KUBECONFIG=/dev/null" >> "$GITHUB_ENV"'; then
    pass "the kubeconfig is removed after the deploy, whatever its outcome"
else
    fail "the kubeconfig outlives the deploy steps"
fi
if grep -qE 'DO_TOKEN|action-doctl|doctl ' "$WORKFLOW"; then
    fail "the workflow still reaches for a DigitalOcean credential"
else
    pass "the workflow holds no DigitalOcean credential"
fi
# after_roll runs a caller's command once its Deployment has rolled, among
# the deploy steps, so it holds the same kubeconfig and runs before the smoke. A
# caller that sets nothing changes nothing: the input defaults to empty and
# the step is skipped when it is.
if grep -A4 '^      after_roll:' "$WORKFLOW" | grep -qF 'default: ""'; then
    pass "after_roll is an input that defaults to empty"
else
    fail "after_roll is not declared, or has a default that changes every caller"
fi
roll_line=$(printf '%s\n' "$deploy" | grep -nF 'name: Roll new image' | cut -d: -f1)
after_line=$(printf '%s\n' "$deploy" | grep -nF 'name: After the roll' | cut -d: -f1)
after_step=$(printf '%s\n' "$deploy" | sed -n '/name: After the roll/,$p')
if [ -n "$roll_line" ] && [ -n "$after_line" ] && [ "$after_line" -gt "$roll_line" ]; then
    pass "the after_roll step is among the deploy steps, after the roll"
else
    fail "the after_roll step is missing from the deploy steps or runs before the roll (roll=$roll_line after=$after_line)"
fi
if printf '%s\n' "$after_step" | grep -qF "if: \${{ inputs.after_roll != '' }}" \
    && printf '%s\n' "$after_step" | grep -qF 'set -euo pipefail' \
    && printf '%s\n' "$after_step" | grep -qF '${{ inputs.after_roll }}'; then
    pass "the after_roll step is skipped when empty and stops at the first failing command"
else
    fail "the after_roll step runs unconditionally or without set -euo pipefail"
fi

if grep -A3 '^      DEPLOY_KUBECONFIG:' "$WORKFLOW" | grep -qE '^\s+description:'; then
    pass "DEPLOY_KUBECONFIG is a declared workflow_call secret"
else
    fail "DEPLOY_KUBECONFIG is not declared, so 'secrets: inherit' cannot deliver it"
fi

if [ "$FAILURES" -gt 0 ]; then
    exit 1
fi
