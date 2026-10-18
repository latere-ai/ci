#!/usr/bin/env bash
#
# runner-health.yml moves CI_RUNNER_PRIVATE between linux-vm and
# ubuntu-latest by whether a linux-vm runner is online. This runs the
# workflow's own script, cut out of the YAML, against a stub gh that serves
# canned runner counts and records every variable write, so the decision is
# tested as shipped: a runner online keeps or restores linux-vm, none online
# for every look moves to the hosted label, a brief gap moves nothing, and an
# API failure fails the run and writes nothing.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as on the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/runner-health.yml"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The step's script: everything under its `run: |`, which is the last key of
# the last step, with the YAML indentation removed.
awk '/^        run: \|$/ { on = 1; next } on { sub(/^          /, ""); print }' "$WORKFLOW" > "$WORK/script.sh"
if ! grep -q 'gh api -X PATCH' "$WORK/script.sh"; then
    fail "cannot cut the script out of runner-health.yml"
    printf "\n1 failure(s)\n"
    exit 1
fi

# A stub gh. Each runners listing prints the next line of $WORK/online
# (several numbers on a line are pages); the variable read prints
# $STUB_HAVE; a PATCH appends its value to $WORK/writes.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
case "$*" in
    *"/actions/runners"*)
        [ "${STUB_LIST_FAIL:-}" = 1 ] && { echo "HTTP 403" >&2; exit 1; }
        n=$(cat "$WORK/calls" 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" > "$WORK/calls"
        line=$(sed -n "${n}p" "$WORK/online")
        [ -n "$line" ] || line=$(tail -n 1 "$WORK/online")
        for page in $line; do echo "$page"; done
        ;;
    *"-X PATCH"*)
        [ "${STUB_PATCH_FAIL:-}" = 1 ] && { echo "HTTP 403" >&2; exit 1; }
        for a in "$@"; do case "$a" in value=*) echo "${a#value=}" >> "$WORK/writes" ;; esac; done
        ;;
    *"/actions/variables/"*)
        [ "${STUB_READ_FAIL:-}" = 1 ] && { echo "HTTP 404" >&2; exit 1; }
        echo "$STUB_HAVE"
        ;;
    *) echo "stub gh: unexpected call: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

# run_case name token have online-lines want-exit want-writes want-calls [env...]
run_case() {
    local name="$1" token="$2" have="$3" online="$4" want_exit="$5" want_writes="$6" want_calls="$7"
    shift 7
    rm -f "$WORK/calls"
    : > "$WORK/writes"
    printf '%b\n' "$online" > "$WORK/online"
    : > "$WORK/summary"
    local code
    env WORK="$WORK" PATH="$WORK/bin:$PATH" GH_TOKEN="$token" ORG=latere-ai LABEL=linux-vm \
        FALLBACK=ubuntu-latest VARIABLE=CI_RUNNER_PRIVATE SAMPLES=6 INTERVAL=0 \
        STUB_HAVE="$have" GITHUB_STEP_SUMMARY="$WORK/summary" "$@" \
        bash "$WORK/script.sh" > "$WORK/out" 2>&1
    code=$?
    local writes calls
    writes=$(tr '\n' ' ' < "$WORK/writes" 2>/dev/null | sed 's/ $//')
    calls=$(cat "$WORK/calls" 2>/dev/null || echo 0)
    if [ "$code" = "$want_exit" ] && [ "$writes" = "$want_writes" ] && [ "$calls" = "$want_calls" ]; then
        pass "$name"
    else
        fail "$name: exit=$code writes='$writes' looks=$calls, want exit=$want_exit writes='$want_writes' looks=$want_calls"
        sed 's/^/      /' "$WORK/out"
    fi
}

run_case "no token: warns, looks at nothing, writes nothing" \
    "" linux-vm "1" 0 "" 0
run_case "a runner online on the first look keeps linux-vm" \
    t linux-vm "1" 0 "" 1
run_case "two runners online, one per page, count as online" \
    t linux-vm "0 1" 0 "" 1
run_case "no runner online on any of six looks moves to ubuntu-latest" \
    t linux-vm "0" 0 "ubuntu-latest" 6
run_case "a gap of two looks moves nothing" \
    t linux-vm "0\n0\n2" 0 "" 3
run_case "a runner back online restores linux-vm" \
    t ubuntu-latest "1" 0 "linux-vm" 1
run_case "still offline leaves ubuntu-latest alone" \
    t ubuntu-latest "0" 0 "" 6
run_case "a failed runners listing fails the run and writes nothing" \
    t linux-vm "0" 1 "" 0 STUB_LIST_FAIL=1
run_case "a failed variable read fails the run and writes nothing" \
    t linux-vm "0" 1 "" 6 STUB_READ_FAIL=1
run_case "a failed write fails the run" \
    t linux-vm "0" 1 "" 6 STUB_PATCH_FAIL=1

# The workflow must not run for a pull request, where a fork's change would
# run with the token, and must hold no permission of GITHUB_TOKEN's.
if awk '/^on:$/ { on = 1; next } on && /^[a-z]/ { exit } on' "$WORKFLOW" | grep -q 'pull_request'; then
    fail "runner-health.yml runs on a pull request"
else
    pass "runner-health.yml never runs on a pull request"
fi
if grep -qx 'permissions: {}' "$WORKFLOW"; then
    pass "runner-health.yml grants GITHUB_TOKEN nothing"
else
    fail "runner-health.yml grants GITHUB_TOKEN permissions it does not use"
fi

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
