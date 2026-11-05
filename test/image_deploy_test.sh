#!/usr/bin/env bash
#
# Grep assertions over image-deploy.yml and its example caller: every action
# is pinned, the one job follows runs_on, the tools are pinned and verified,
# the images are pinned by digest with kustomize and never with sed, the
# kubeconfig is written under RUNNER_TEMP and removed whatever happens, and
# the steps run in the order a deploy needs: the rollback guard before the
# cluster is touched, the smoke after the rollout and after the kubeconfig is
# gone, the evidence last. The shell behind the steps is tested in
# deploy_by_digest_test.sh and ensure_tools_test.sh.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/image-deploy.yml"
EXAMPLE="$REPO_ROOT/examples/image-release.yml"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# Code only: the header comment documents the caller and names things the
# job does not do.
CODE=$(grep -vE '^\s*#' "$WORKFLOW")
line_of() { grep -nF "$1" "$WORKFLOW" | head -1 | cut -d: -f1; }

if grep -E '^\s*-?\s*uses:' "$WORKFLOW" | grep -vE '@[0-9a-f]{40}|uses: \./\.latere-ci/actions/[a-z-]+$' >/dev/null; then
    fail "an action is not pinned to a commit SHA"
else
    pass "every action is pinned to a commit SHA, except the shared steps"
fi

jobs=$(grep -cE '^  [a-z-]+:$' "$WORKFLOW")
if [ "$jobs" -eq 1 ] && [ "$(grep -cF 'runs-on: ${{ inputs.runs_on }}' "$WORKFLOW")" -eq 1 ] \
    && ! grep -qE '^\s+runs-on: ubuntu-latest$' "$WORKFLOW"; then
    pass "the one job runs on inputs.runs_on"
else
    fail "the job does not follow inputs.runs_on (jobs=$jobs)"
fi

# The caller decides whether to deploy: the stage reads no repository
# variable of its own, besides the runner policy's default.
if printf '%s\n' "$CODE" | grep -v 'default: ' | grep -q 'vars\.'; then
    fail "the stage reads a repository variable"
else
    pass "the stage reads no repository variable"
fi

if sed -n '/^    environment:/,/^    outputs:/p' "$WORKFLOW" | grep -qE '^      name: production$' \
    && sed -n '/^    environment:/,/^    outputs:/p' "$WORKFLOW" | grep -qF 'url: ${{ inputs.url }}'; then
    pass "the job runs in the production environment with the URL input"
else
    fail "the job is not in the production environment with url: inputs.url"
fi

# The secret is the name service-release uses, required, so a caller maps its
# own onto it.
if sed -n '/^    secrets:/,/^    outputs:/p' "$WORKFLOW" | grep -A4 '^      DEPLOY_KUBECONFIG:' | grep -qE '^        required: true$'; then
    pass "DEPLOY_KUBECONFIG is a required workflow_call secret"
else
    fail "DEPLOY_KUBECONFIG is not a required secret"
fi

for input in images deployments url; do
    if sed -n '/^    inputs:/,/^    secrets:/p' "$WORKFLOW" | grep -A4 "^      $input:\$" | grep -qE '^        required: true$'; then
        pass "$input is a required input"
    else
        fail "$input is not a required input"
    fi
done
for pair in deploy_dir:deploy/prod smoke_script:tools/smoke/release.sh rollout_timeout:600s; do
    key=${pair%%:*}
    val=${pair#*:}
    if sed -n "/^      $key:\$/,/^        default:/p" "$WORKFLOW" | grep -qxF "        default: $val"; then
        pass "$key defaults to $val"
    else
        fail "$key does not default to $val"
    fi
done
for key in after_roll namespace kubectl_version kustomize_version; do
    if sed -n "/^      $key:\$/,/^        default:/p" "$WORKFLOW" | grep -qxF '        default: ""'; then
        pass "$key defaults to empty"
    else
        fail "$key does not default to empty"
    fi
done

# Tools: pinned through versions.sh, fetched with a checksum, only the pinned
# versions.
if printf '%s\n' "$CODE" | grep -qF 'KUBECTL_VERSION: ${{ inputs.kubectl_version }}' \
    && printf '%s\n' "$CODE" | grep -qF 'KUSTOMIZE_VERSION: ${{ inputs.kustomize_version }}' \
    && printf '%s\n' "$CODE" | grep -qF 'run: bash .latere-ci/actions/lib/versions.sh' \
    && printf '%s\n' "$CODE" | grep -qF 'uses: ./.latere-ci/actions/ensure-kubectl' \
    && printf '%s\n' "$CODE" | grep -qF 'uses: ./.latere-ci/actions/ensure-kustomize' \
    && printf '%s\n' "$CODE" | grep -qF 'version: ${{ steps.versions.outputs.kubectl }}' \
    && printf '%s\n' "$CODE" | grep -qF 'version: ${{ steps.versions.outputs.kustomize }}'; then
    pass "kubectl and kustomize come from versions.sh or the version inputs"
else
    fail "kubectl or kustomize is not set up at a pinned version"
fi
for tool in kubectl kustomize; do
    if grep -qF 'sha256sum -c' "$REPO_ROOT/actions/ensure-$tool/run.sh"; then
        pass "ensure-$tool verifies what it fetches"
    else
        fail "ensure-$tool does not verify what it fetches"
    fi
done
if grep -rE 'releases/latest|/latest/|version: *latest' "$WORKFLOW" "$REPO_ROOT"/actions/ensure-kubectl "$REPO_ROOT"/actions/ensure-kustomize "$REPO_ROOT"/actions/deploy-by-digest > /dev/null; then
    fail "a tool is fetched at latest"
else
    pass "no tool is fetched at latest"
fi

# The images are pinned by digest with kustomize, exactly, and the file is
# never edited with sed.
if grep -qF 'kustomize edit set image' "$REPO_ROOT/actions/deploy-by-digest/run.sh" \
    && printf '%s\n' "$CODE" | grep -A3 'name: Pin the images by digest' | grep -qF 'uses: ./.latere-ci/actions/deploy-by-digest' \
    && printf '%s\n' "$CODE" | grep -qF 'IMAGES: ${{ inputs.images }}'; then
    pass "the images are pinned with kustomize edit set image"
else
    fail "the images are not pinned with kustomize edit set image"
fi
if grep -vE '^\s*#' "$WORKFLOW" "$REPO_ROOT"/actions/deploy-by-digest/run.sh | grep -E '\bsed\b.*(kustomization|DEPLOY_DIR|deploy_dir)|\bsed -i' > /dev/null; then
    fail "the kustomization is edited with sed"
else
    pass "no sed over the kustomization"
fi
if grep -qF 'kubectl apply -k "${DEPLOY_DIR:-deploy/prod}"' "$REPO_ROOT/actions/deploy-by-digest/run.sh" \
    && grep -qF 'kubectl -n "$ns" rollout status' "$REPO_ROOT/actions/deploy-by-digest/run.sh"; then
    pass "the overlay is applied with -k and each Deployment is waited for"
else
    fail "the apply or the rollout wait is missing from deploy-by-digest"
fi

# The order a deploy needs.
prev=0
order_ok=1
for step in 'uses: ./.latere-ci/actions/rollback-guard' 'name: Ensure kubectl' 'name: Ensure kustomize' 'name: Write the kubeconfig' 'name: Pin the images by digest' 'name: Apply the overlay' 'name: Wait for the rollout' 'name: After the roll' 'name: Drop the kubeconfig' 'name: Smoke the live service' 'name: Upload the smoke evidence'; do
    n=$(line_of "$step")
    if [ -z "$n" ] || [ "$n" -le "$prev" ]; then
        fail "$step is missing or out of order"
        order_ok=0
    fi
    prev=${n:-$prev}
done
[ "$order_ok" -eq 1 ] && pass "rollback guard, tools, kubeconfig, pin, apply, rollout, after_roll, drop, smoke and evidence run in order"

# A re-run after a newer tag stops before anything reaches the cluster.
if [ "$(line_of 'actions/rollback-guard')" -lt "$(line_of 'name: Write the kubeconfig')" ]; then
    pass "the rollback guard runs before the kubeconfig is written"
else
    fail "the rollback guard runs after the kubeconfig is written"
fi

# The kubeconfig: a 600 file under RUNNER_TEMP, removed whatever happened.
write=$(sed -n '/name: Write the kubeconfig/,/name: Pin the images/p' "$WORKFLOW")
if printf '%s' "$write" | grep -qF 'KUBECONFIG_CONTENT: ${{ secrets.DEPLOY_KUBECONFIG }}' \
    && printf '%s' "$write" | grep -qF 'install -m 700 -d "$RUNNER_TEMP/kube"' \
    && printf '%s' "$write" | grep -qF 'chmod 600 "$RUNNER_TEMP/kube/config"' \
    && printf '%s' "$write" | grep -qF 'echo "KUBECONFIG=$RUNNER_TEMP/kube/config" >> "$GITHUB_ENV"'; then
    pass "DEPLOY_KUBECONFIG is written to a 600 file under RUNNER_TEMP"
else
    fail "DEPLOY_KUBECONFIG is not written to a private file under RUNNER_TEMP"
fi
drop=$(sed -n '/name: Drop the kubeconfig/,/name: Smoke the live service/p' "$WORKFLOW")
if printf '%s' "$drop" | grep -qF 'if: ${{ always() }}' \
    && printf '%s' "$drop" | grep -qF 'rm -rf "$RUNNER_TEMP/kube"' \
    && printf '%s' "$drop" | grep -qF 'echo "KUBECONFIG=/dev/null" >> "$GITHUB_ENV"'; then
    pass "the kubeconfig is removed in an always() step"
else
    fail "the kubeconfig outlives the deploy steps"
fi

# after_roll: skipped when empty, stops at the first failing command.
after=$(sed -n '/name: After the roll/,/name: Drop the kubeconfig/p' "$WORKFLOW")
if printf '%s\n' "$after" | grep -qF "if: \${{ inputs.after_roll != '' }}" \
    && printf '%s\n' "$after" | grep -qF 'set -euo pipefail' \
    && printf '%s\n' "$after" | grep -qF '${{ inputs.after_roll }}'; then
    pass "after_roll is skipped when empty and stops at the first failing command"
else
    fail "after_roll runs unconditionally or without set -euo pipefail"
fi

# The smoke reads what the contract names, tries again through the Recreate
# gap, and its evidence is the only path to the release.
smoke=$(sed -n '/name: Smoke the live service/,/name: The evidence/p' "$WORKFLOW")
for var in 'BASE_URL: ${{ inputs.url }}' 'TAG: ${{ github.ref_name }}' 'COMMIT: ${{ github.sha }}' 'DEPLOY_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}' 'OUTPUT_MD: release-evidence/smoke.md' 'SMOKE_SCRIPT: ${{ inputs.smoke_script }}' 'SMOKE_TIMEOUT: ${{ inputs.smoke_timeout }}'; do
    if ! printf '%s\n' "$smoke" | grep -qF "$var"; then
        fail "the smoke step does not set $var"
        smoke_missing=1
    fi
done
[ -z "${smoke_missing:-}" ] && pass "the smoke step sets the variables of the smoke contract"
up=$(sed -n '/name: Upload the smoke evidence/,$p' "$WORKFLOW")
if printf '%s\n' "$up" | grep -qF 'name: ${{ inputs.evidence_name }}' \
    && printf '%s\n' "$up" | grep -qF 'path: release-evidence/smoke.md' \
    && printf '%s\n' "$up" | grep -qF 'if-no-files-found: error' \
    && ! printf '%s\n' "$up" | grep -q 'continue-on-error'; then
    pass "the evidence is uploaded, and a failure to upload it fails the job"
else
    fail "the evidence upload is missing, tolerant of failure, or misnamed"
fi
if sed -n '/^      evidence_name:$/,/^        default:/p' "$WORKFLOW" | grep -qxF '        default: smoke-evidence'; then
    pass "the evidence artifact is named smoke-evidence by default"
else
    fail "the evidence artifact default is not smoke-evidence"
fi

# The stage needs to read the repository and nothing else.
if sed -n '/^permissions:/,/^jobs:/p' "$WORKFLOW" | grep -qx '  contents: read' \
    && ! sed -n '/^permissions:/,/^jobs:/p' "$WORKFLOW" | grep -qE ': write'; then
    pass "the stage asks for contents: read and no write"
else
    fail "the stage asks for more than contents: read"
fi

# The example wires it as the README says: gated by a variable, the secret
# mapped, publish not blocked by a skipped deploy and blocked by a failed one.
if grep -qF 'uses: latere-ai/ci/.github/workflows/image-deploy.yml@v1' "$EXAMPLE" \
    && grep -qF "if: \${{ vars.EXAMPLE_RELEASE_DEPLOY != '' }}" "$EXAMPLE" \
    && grep -qF 'DEPLOY_KUBECONFIG: ${{ secrets.EXAMPLE_KUBECONFIG }}' "$EXAMPLE" \
    && sed -n '/^  deploy:/,/^  publish:/p' "$EXAMPLE" | grep -qx '      contents: read'; then
    pass "the example gates the deploy by a variable, maps the secret and grants contents: read"
else
    fail "the example's deploy job is not gated, mapped or granted as documented"
fi
if grep -qF "needs.deploy.result != 'failure' && needs.deploy.result != 'cancelled'" "$EXAMPLE" \
    && grep -qF "evidence: '*-evidence'" "$EXAMPLE" \
    && grep -qF "needs.publish.result == 'success'" "$EXAMPLE"; then
    pass "the example publishes unless the deploy failed, with its evidence, and verifies after"
else
    fail "the example's publish or verify condition does not account for a skipped deploy"
fi

if [ "$FAILURES" -gt 0 ]; then
    exit 1
fi
