#!/usr/bin/env bash
#
# The smoke retry in service-release.yml. The smoke starts the moment the
# rollout reports done, while an old pod may still answer, so a failed smoke
# runs again until it passes or its window closes. The smoke_until_live
# function is read out of the workflow itself and run against stub smoke
# scripts, so the cases test what ships.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/service-release.yml"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

fn=$(awk '/^          smoke_until_live\(\) \{$/ {on = 1} on {print} on && /^          \}$/ {exit}' "$WORKFLOW")
if [ -z "$fn" ]; then
    fail "the workflow defines no smoke_until_live function"
    exit 1
fi
eval "$fn"

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

# A stub smoke that fails until it has been called $1 times, counting calls
# in a file, and writes OUTPUT_MD the way a real smoke does.
cat > "$dir/smoke.sh" <<'EOF'
#!/usr/bin/env bash
n=$(($(cat "$COUNT" 2>/dev/null || echo 0) + 1))
echo "$n" > "$COUNT"
[ "$n" -ge "$PASS_ON" ] || { echo "asset mismatch on call $n" >&2; exit 1; }
echo "live on call $n" > "$OUTPUT_MD"
EOF
chmod +x "$dir/smoke.sh"
export OUTPUT_MD="$dir/smoke.md"

# run PASS_ON WINDOW: runs the function in a bash -e process, as a run: step
# does, and prints its status and how many times the smoke ran.
run() {
    export PASS_ON=$1 COUNT="$dir/count" SMOKE_WINDOW=$2 SMOKE_INTERVAL=0
    rm -f "$COUNT" "$OUTPUT_MD"
    local status=0
    FN="$fn" bash -e -c 'eval "$FN"; smoke_until_live "$1"' _ "$dir/smoke.sh" >/dev/null 2>&1 || status=$?
    echo "$status $(cat "$COUNT")"
}

got=$(run 1 5)
[ "$got" = "0 1" ] && pass "a smoke that passes at once runs once" || fail "a passing smoke: status and calls '$got', want '0 1'"

got=$(run 3 5)
if [ "$got" = "0 3" ] && grep -q "live on call 3" "$OUTPUT_MD"; then
    pass "a smoke that passes on its third try passes, and its evidence is the passing run's"
else
    fail "a smoke passing on the third try: status and calls '$got', want '0 3'"
fi

got=$(run 1000000 1)
status=${got%% *}
calls=${got##* }
if [ "$status" -ne 0 ] && [ "$calls" -gt 1 ]; then
    pass "a smoke that never passes fails once its window closes, after more than one try"
else
    fail "a smoke that never passes: status and calls '$got', want a failure after more than one call"
fi

# The step sets the window and the interval it retries on.
if grep -qE '^          SMOKE_WINDOW: "[0-9]+"$' "$WORKFLOW" && grep -qE '^          SMOKE_INTERVAL: "[0-9]+"$' "$WORKFLOW" \
    && grep -qF 'smoke_until_live "${{ inputs.smoke_script }}"' "$WORKFLOW"; then
    pass "the smoke step runs the caller's script through smoke_until_live with a window and an interval"
else
    fail "the smoke step does not run the caller's script through smoke_until_live"
fi

if [ "$FAILURES" -gt 0 ]; then
    exit 1
fi
