#!/usr/bin/env bash
#
# Tests for actions/deploy-by-digest/run.sh against stub `kubectl` and
# `kustomize` binaries that record their arguments. kubectl's `kustomize`
# prints the file the test names in STUB_RENDER; `edit set image` records
# the image it was given.
#
# Kept bash 3.2 compatible.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/actions/deploy-by-digest/run.sh"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/work/deploy/prod"
touch "$TMP/work/deploy/prod/kustomization.yaml"
cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "kubectl $*" >> "$STUB_DIR/calls"
case "$1" in
    kustomize) cat "$STUB_RENDER" ;;
    -n) case "$*" in *"deployment/${STUB_ROLLOUT_FAIL:-none} "*) exit 1 ;; esac ;;
esac
exit 0
STUB
cat > "$TMP/bin/kustomize" <<'STUB'
#!/usr/bin/env bash
echo "kustomize $* (in $(basename "$PWD"))" >> "$STUB_DIR/calls"
STUB
chmod +x "$TMP/bin/kubectl" "$TMP/bin/kustomize"
export STUB_DIR="$TMP"
export PATH="$TMP/bin:$PATH"

D1=sha256:1111111111111111111111111111111111111111111111111111111111111111
D2=sha256:2222222222222222222222222222222222222222222222222222222222222222

# run_step STEP: the script run in the work directory with the environment
# the caller set; prints its output, and returns its status.
run_step() {
    : > "$TMP/calls"
    (cd "$TMP/work" && env "$@" bash "$SCRIPT" "$STEP_NAME" 2>&1)
}
step() { STEP_NAME=$1; shift; run_step "$@"; }

render_one() {
    cat > "$TMP/render" <<E2
apiVersion: apps/v1
kind: Deployment
metadata:
  name: arcad
  namespace: latere
spec:
  template:
    spec:
      containers:
      - image: ghcr.io/latere-ai/arcad@$D1
E2
}
render_one

# pin: one image, name equal to ref.
out=$(step pin STUB_RENDER="$TMP/render" IMAGES="ghcr.io/latere-ai/arcad@$D1")
if [ $? -eq 0 ] && grep -qF "kustomize edit set image ghcr.io/latere-ai/arcad=ghcr.io/latere-ai/arcad@$D1 (in prod)" "$TMP/calls"; then
    pass "pin sets the image by digest in the overlay's directory"
else
    fail "pin did not call kustomize edit set image in deploy/prod: $out"
fi

# pin: a fork's ref under the overlay's committed name.
out=$(step pin STUB_RENDER="$TMP/render" IMAGES="ghcr.io/latere-ai/arcad=ghcr.io/latere-ai/arcad@$D1")
if [ $? -eq 0 ] && grep -qF "set image ghcr.io/latere-ai/arcad=ghcr.io/latere-ai/arcad@$D1" "$TMP/calls"; then
    pass "pin takes <name>=<ref>@<digest>"
else
    fail "pin ignored the name mapping: $out"
fi

# pin: several images, blank lines and indentation tolerated.
cat >> "$TMP/render" <<E2
      - image: ghcr.io/latere-ai/arca-stubs@$D2
E2
out=$(step pin STUB_RENDER="$TMP/render" IMAGES="
  ghcr.io/latere-ai/arcad@$D1

  ghcr.io/latere-ai/arca-stubs@$D2
")
n=$(grep -c 'set image' "$TMP/calls")
if [ $? -eq 0 ] && [ "$n" -eq 2 ]; then
    pass "pin sets each of several images"
else
    fail "pin set $n images, want 2: $out"
fi
render_one

# pin refuses what it cannot pin exactly.
step pin STUB_RENDER="$TMP/render" IMAGES="ghcr.io/latere-ai/arcad:v1.0.0" > /dev/null
a=$?
step pin STUB_RENDER="$TMP/render" IMAGES="ghcr.io/latere-ai/arcad@sha256:abc" > /dev/null
b=$?
step pin STUB_RENDER="$TMP/render" IMAGES="" > /dev/null
c=$?
if [ $a -ne 0 ] && [ $b -ne 0 ] && [ $c -ne 0 ]; then
    pass "pin refuses a tag, a short digest and no images"
else
    fail "pin accepted a tag ($a), a short digest ($b) or no images ($c)"
fi

# pin: the render must run the digest; an overlay that names another image
# is not silently left on its old one.
out=$(step pin STUB_RENDER="$TMP/render" IMAGES="ghcr.io/latere-ai/other@$D2")
if [ $? -ne 0 ] && printf '%s' "$out" | grep -qF "does not run ghcr.io/latere-ai/other@$D2"; then
    pass "pin fails when the render does not run the pinned digest"
else
    fail "pin passed an overlay that does not run the digest: $out"
fi
out=$(step pin STUB_RENDER="$TMP/render" DEPLOY_DIR=nope IMAGES="ghcr.io/latere-ai/arcad@$D1")
if [ $? -ne 0 ]; then
    pass "pin fails when the overlay has no kustomization.yaml"
else
    fail "pin passed a missing overlay"
fi

# apply: the namespace comes from the render, and -k applies the overlay.
out=$(step apply STUB_RENDER="$TMP/render")
if [ $? -eq 0 ] && grep -qxF "kubectl apply -k deploy/prod" "$TMP/calls"; then
    pass "apply runs kubectl apply -k of the overlay"
else
    fail "apply did not run kubectl apply -k deploy/prod: $out"
fi

# namespace: a RoleBinding subject's namespace is not an object's own, two
# namespaces are refused, and the input wins.
cat > "$TMP/render2" <<'E2'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: r
  namespace: latere
subjects:
- kind: ServiceAccount
  name: r
  namespace: elsewhere
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: d
  namespace: latere
E2
out=$(cd "$TMP/work" && STUB_RENDER="$TMP/render2" bash -c ". '$SCRIPT'; namespace" 2>&1)
if [ "$out" = latere ]; then
    pass "the namespace is the objects' own, not a subject's"
else
    fail "namespace read '$out' from a RoleBinding subject"
fi
cat >> "$TMP/render2" <<'E2'
---
apiVersion: v1
kind: Service
metadata:
  name: s
  namespace: other
E2
out=$(cd "$TMP/work" && STUB_RENDER="$TMP/render2" bash -c ". '$SCRIPT'; namespace" 2>&1)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -qF "names 2 namespaces"; then
    pass "two namespaces in the render are refused unless namespace is given"
else
    fail "an ambiguous namespace was accepted: $out"
fi
out=$(cd "$TMP/work" && STUB_RENDER="$TMP/render2" NAMESPACE=chosen bash -c ". '$SCRIPT'; namespace" 2>&1)
if [ "$out" = chosen ]; then
    pass "the namespace input wins"
else
    fail "the namespace input was ignored: $out"
fi

# rollout: each Deployment in order, with the timeout; the first failure
# stops the rest.
out=$(step rollout STUB_RENDER="$TMP/render" DEPLOYMENTS="
arcad
deployment/arcad-reaper
" ROLLOUT_TIMEOUT=30s)
if [ $? -eq 0 ] \
    && [ "$(grep -c 'rollout status' "$TMP/calls")" -eq 2 ] \
    && grep -qxF "kubectl -n latere rollout status deployment/arcad --timeout=30s" "$TMP/calls" \
    && grep -qxF "kubectl -n latere rollout status deployment/arcad-reaper --timeout=30s" "$TMP/calls"; then
    pass "rollout waits for each Deployment in the namespace, with the timeout"
else
    fail "rollout calls were wrong: $out"
fi
out=$(step rollout STUB_RENDER="$TMP/render" DEPLOYMENTS="arcad
arcad-reaper" STUB_ROLLOUT_FAIL=arcad)
if [ $? -ne 0 ] && [ "$(grep -c 'rollout status' "$TMP/calls")" -eq 1 ]; then
    pass "a Deployment that does not roll fails the step and stops the rest"
else
    fail "rollout went on after a failure: $out"
fi
step rollout STUB_RENDER="$TMP/render" DEPLOYMENTS="" > /dev/null
if [ $? -ne 0 ]; then
    pass "rollout with no Deployments fails rather than waiting for nothing"
else
    fail "rollout with no Deployments passed"
fi

# smoke: the script is run again until it passes. This one fails twice, as a
# Recreate Deployment does while its old Pod is gone, then passes.
cat > "$TMP/smoke.sh" <<'E2'
#!/usr/bin/env bash
n=$(cat "$STUB_DIR/attempts" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$STUB_DIR/attempts"
echo "env: $BASE_URL $TAG $COMMIT $DEPLOY_URL" > "$STUB_DIR/smoke-env"
[ "$n" -ge "${PASS_AT:-3}" ] || exit 1
echo "evidence for $TAG" > "$OUTPUT_MD"
E2
chmod +x "$TMP/smoke.sh"
smoke_env="SMOKE_SCRIPT=$TMP/smoke.sh BASE_URL=https://x.test TAG=v1.2.3 COMMIT=abc DEPLOY_URL=https://run OUTPUT_MD=$TMP/out/smoke.md GITHUB_STEP_SUMMARY=$TMP/summary"
rm -f "$TMP/attempts" "$TMP/summary"
# shellcheck disable=SC2086
out=$(step smoke $smoke_env SMOKE_TIMEOUT=30 SMOKE_INTERVAL=0)
if [ $? -eq 0 ] && [ "$(cat "$TMP/attempts")" -eq 3 ] \
    && grep -qF "evidence for v1.2.3" "$TMP/out/smoke.md" \
    && grep -qF "env: https://x.test v1.2.3 abc https://run" "$TMP/smoke-env" \
    && grep -qF "passed on attempt 3" "$TMP/summary" \
    && grep -qF "evidence for v1.2.3" "$TMP/summary"; then
    pass "smoke is retried until it passes, with the caller's environment, and its evidence kept"
else
    fail "smoke retry did not behave: $out"
fi

# smoke: a script that never passes fails the step after the timeout.
rm -f "$TMP/attempts" "$TMP/summary" "$TMP/out/smoke.md"
# shellcheck disable=SC2086
out=$(step smoke $smoke_env PASS_AT=99 SMOKE_TIMEOUT=1 SMOKE_INTERVAL=1)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -qF "did not pass" && [ "$(cat "$TMP/attempts")" -ge 1 ]; then
    pass "a smoke that never passes fails the step"
else
    fail "a smoke that never passes did not fail: $out"
fi

# smoke: a timeout of 0 runs the script once.
rm -f "$TMP/attempts"
# shellcheck disable=SC2086
step smoke $smoke_env PASS_AT=99 SMOKE_TIMEOUT=0 SMOKE_INTERVAL=0 > /dev/null
if [ $? -ne 0 ] && [ "$(cat "$TMP/attempts")" -eq 1 ]; then
    pass "smoke_timeout 0 runs the script once"
else
    fail "smoke_timeout 0 ran the script $(cat "$TMP/attempts") times"
fi

step bogus > /dev/null
if [ $? -ne 0 ]; then
    pass "an unknown step fails"
else
    fail "an unknown step passed"
fi

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
