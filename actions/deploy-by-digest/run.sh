#!/usr/bin/env bash
#
# The steps of a core's deploy that image-deploy.yml runs, one per call:
#
#   pin      each image set to <ref>@<digest> in the overlay's
#            kustomization.yaml with `kustomize edit set image`, then the
#            overlay rendered and every pinned reference required in it
#   apply    kubectl apply -k of the overlay, in the namespace the render
#            names unless NAMESPACE says another
#   rollout  kubectl rollout status of each Deployment
#   smoke    the caller's smoke script, run again until it passes or the
#            timeout ends, for a Deployment whose old Pod stops before the
#            new one is ready (the Recreate strategy)
#
# Inputs, from the environment: DEPLOY_DIR (default deploy/prod), IMAGES
# (one per line: <ref>@<digest>, or <kustomize name>=<ref>@<digest> where
# the overlay names the image otherwise), NAMESPACE (empty: the namespace of
# the rendered objects, which must be one), DEPLOYMENTS (one per line, with
# or without a deployment/ prefix), ROLLOUT_TIMEOUT (default 600s),
# SMOKE_SCRIPT, SMOKE_TIMEOUT and SMOKE_INTERVAL (seconds), and what the
# smoke script reads: BASE_URL, TAG, COMMIT, DEPLOY_URL, OUTPUT_MD.
#
# Sourced, it defines the functions alone, for the tests.
set -euo pipefail

die() {
    echo "::error::$*" >&2
    exit 1
}

# Prints "<name> <ref> <digest>" for each image line on stdin.
parse_images() {
    local line name ref digest
    while IFS= read -r line; do
        line=$(printf '%s' "$line" | tr -d '[:space:]')
        [ -n "$line" ] || continue
        case "$line" in
            *=*) name=${line%%=*}; line=${line#*=} ;;
            *) name="" ;;
        esac
        ref=${line%%@*}
        digest=${line#*@}
        [ "$ref" != "$line" ] || die "image '$line' has no digest; give it as <ref>@<digest>"
        printf '%s' "$digest" | grep -qE '^sha256:[0-9a-f]{64}$' \
            || die "image '$line' has no sha256 digest to pin"
        [ -n "$ref" ] || die "image '$line' has no reference"
        printf '%s %s %s\n' "${name:-$ref}" "$ref" "$digest"
    done
}

render() {
    kubectl kustomize "${DEPLOY_DIR:-deploy/prod}"
}

pin() {
    local dir=${DEPLOY_DIR:-deploy/prod} n=0 name ref digest rendered
    [ -f "$dir/kustomization.yaml" ] || die "$dir/kustomization.yaml does not exist; the overlay to deploy must be a kustomization"
    local parsed
    parsed=$(printf '%s\n' "${IMAGES:-}" | parse_images)
    [ -n "$parsed" ] || die "no images to deploy"
    while read -r name ref digest; do
        (cd "$dir" && kustomize edit set image "${name}=${ref}@${digest}")
        n=$((n + 1))
    done <<< "$parsed"
    rendered=$(render)
    while read -r name ref digest; do
        printf '%s\n' "$rendered" | grep -qF "${ref}@${digest}" \
            || die "the rendered $dir does not run ${ref}@${digest}; the overlay names no image '${name}'"
        echo "pinned ${ref}@${digest} as ${name}"
    done <<< "$parsed"
    echo "$n image(s) pinned by digest"
}

# The namespace to act in: NAMESPACE, else the one the render names.
namespace() {
    local ns found count
    if [ -n "${NAMESPACE:-}" ]; then
        printf '%s\n' "$NAMESPACE"
        return 0
    fi
    # Only an object's own metadata counts: a RoleBinding's subject names a
    # namespace too, at the same indent.
    found=$(render | awk '/^[a-z]/ { meta = ($1 == "metadata:") } meta && /^  namespace:/ { print $2 }' | tr -d '"' | sort -u)
    count=$(printf '%s\n' "$found" | grep -c . || true)
    [ "$count" -eq 1 ] || die "the rendered ${DEPLOY_DIR:-deploy/prod} names $count namespaces, not one; pass namespace"
    ns=$found
    printf '%s\n' "$ns"
}

apply() {
    local ns
    ns=$(namespace)
    echo "DEPLOY_NAMESPACE=$ns" >> "${GITHUB_ENV:-/dev/null}"
    kubectl apply -k "${DEPLOY_DIR:-deploy/prod}"
}

rollout() {
    local ns d
    ns=$(namespace)
    [ -n "$(printf '%s' "${DEPLOYMENTS:-}" | tr -d '[:space:]')" ] || die "no Deployments to wait for"
    while IFS= read -r d; do
        d=$(printf '%s' "$d" | tr -d '[:space:]')
        [ -n "$d" ] || continue
        d=${d#deployment/}
        kubectl -n "$ns" rollout status "deployment/$d" --timeout="${ROLLOUT_TIMEOUT:-600s}"
    done <<< "${DEPLOYMENTS}"
}

smoke() {
    local script=${SMOKE_SCRIPT:?} timeout=${SMOKE_TIMEOUT:-120} interval=${SMOKE_INTERVAL:-5}
    local start=$SECONDS attempt=0 summary=${GITHUB_STEP_SUMMARY:-/dev/null}
    : "${OUTPUT_MD:?}"
    mkdir -p "$(dirname "$OUTPUT_MD")"
    while :; do
        attempt=$((attempt + 1))
        if "$script"; then
            if [ "$attempt" -gt 1 ]; then
                echo "The smoke passed on attempt $attempt, $((SECONDS - start)) seconds after the first." >> "$summary"
            fi
            cat "$OUTPUT_MD" >> "$summary"
            return 0
        fi
        if [ $((SECONDS - start + interval)) -ge "$timeout" ]; then
            die "the smoke did not pass in $((SECONDS - start)) seconds over $attempt attempt(s)"
        fi
        echo "smoke attempt $attempt failed; trying again in ${interval}s"
        sleep "$interval"
    done
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

case "${1:-}" in
    pin | apply | rollout | smoke) "$1" ;;
    *) die "unknown step '${1:-}': pin, apply, rollout or smoke" ;;
esac
