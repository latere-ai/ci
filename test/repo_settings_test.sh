#!/usr/bin/env bash
#
# Tests for tools/repo-settings.sh.
#
# The script's whole job is to talk to the GitHub API, so the suite puts a
# stub `gh` on PATH that serves repository JSON from a fixture directory and
# records every PATCH body it receives. That exercises the real code paths
# (target resolution, the drift comparison, the has_projects retry, archived
# skips) without touching a live repository, and lets the failure cases that
# matter be provoked on demand.
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as the
# ubuntu-latest runners.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/tools/repo-settings.sh"
POLICY="$REPO_ROOT/tools/repo-settings.json"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FIXTURES="$WORK/fixtures"
BIN="$WORK/bin"
mkdir -p "$FIXTURES" "$BIN"

# Stub `gh`. Serves GET /repos/<owner>/<name> from
# fixtures/<owner>__<name>.json, serves the org listing from
# fixtures/_org.json, and appends every PATCH body to fixtures/_patches.log
# as "<slug> <compact json>". A fixture flagged projects_fail rejects any
# body carrying has_projects, which is how GitHub behaves for a repo that
# still owns classic projects.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
FIXTURES="$GH_STUB_FIXTURES"
[ "${1:-}" = "api" ] || { echo "stub gh: unsupported command ${1:-}" >&2; exit 64; }
shift
method=GET
path=""
input=""
# `--input <file>` carries an absolute path of its own, so the flag values are
# consumed rather than rescanned; otherwise a policy file at /Users/... would
# be mistaken for the API path.
while [ $# -gt 0 ]; do
    case "$1" in
        -X)       method="$2"; shift 2 ;;
        --input)  input="$2"; shift 2 ;;
        /*)       path="$1"; shift ;;
        *)        shift ;;
    esac
done
case "$path" in
    /orgs/*/repos*)
        cat "$FIXTURES/_org.json"
        exit 0
        ;;
esac

slug="${path#/repos/}"
file="$FIXTURES/${slug%%/*}__${slug#*/}.json"
[ -f "$file" ] || { echo "stub gh: HTTP 404 Not Found" >&2; exit 1; }

if [ "$method" = "PATCH" ]; then
    if [ "$input" = "-" ]; then body="$(cat)"; else body="$(cat "$input")"; fi
    if [ -f "${file%.json}.projects_fail" ] && printf '%s' "$body" | grep -q has_projects; then
        echo "stub gh: HTTP 422 Projects are still open on this repository" >&2
        exit 1
    fi
    printf '%s %s\n' "$slug" "$(printf '%s' "$body" | jq -c .)" >> "$FIXTURES/_patches.log"
    exit 0
fi
cat "$file"
STUB
chmod +x "$BIN/gh"
export GH_STUB_FIXTURES="$FIXTURES"
export PATH="$BIN:$PATH"
export REPO_SETTINGS_ORG=testorg

# Writes fixtures/<name>.json for a repo that already matches the policy,
# with the given jq expression applied on top to introduce differences.
make_repo() {
    local name="$1" overlay="${2:-.}"
    jq ". + $overlay + {archived: false}" "$POLICY" > "$FIXTURES/testorg__$name.json"
}

reset_patches() { : > "$FIXTURES/_patches.log"; }

run() { "$SCRIPT" "$@" > "$WORK/out" 2>&1; printf '%s' $?; }

assert_out() {
    local name="$1" pattern="$2"
    if grep -qE "$pattern" "$WORK/out"; then pass "$name"; else
        fail "$name (output did not match /$pattern/)"
        sed 's/^/        /' "$WORK/out"
    fi
}

# --- fixtures ---------------------------------------------------------------
make_repo compliant
make_repo drifted '{allow_merge_commit: true, has_wiki: true}'
make_repo archived '{archived: true}'
jq '. + {archived: true}' "$POLICY" > "$FIXTURES/testorg__archived.json"
make_repo projecty
touch "$FIXTURES/testorg__projecty.projects_fail"
jq -n '[{full_name: "testorg/compliant", archived: false},
        {full_name: "testorg/drifted",   archived: false},
        {full_name: "testorg/archived",  archived: true}]' > "$FIXTURES/_org.json"
reset_patches

# --- the checked-in policy --------------------------------------------------
if jq -e '
    .allow_squash_merge == true and .allow_merge_commit == false
    and .allow_rebase_merge == false and .allow_auto_merge == true
    and .squash_merge_commit_title == "PR_TITLE"
    and .squash_merge_commit_message == "PR_BODY"
    and .delete_branch_on_merge == true
    and .has_wiki == false and .has_projects == false' "$POLICY" > /dev/null; then
    pass "policy file states squash-only, auto-merge, PR title/body, no wiki or projects"
else
    fail "policy file does not state the intended settings"
fi

# --- check ------------------------------------------------------------------
rc=$(run check compliant)
[ "$rc" = 0 ] && pass "check exits 0 on a compliant repo" || fail "check exits 0 on a compliant repo (got $rc)"

rc=$(run check drifted)
[ "$rc" = 1 ] && pass "check exits 1 on a drifted repo" || fail "check exits 1 on a drifted repo (got $rc)"
assert_out "check names the drifted field and both values" 'allow_merge_commit: want=false got=true'
assert_out "check reports every drifted field" 'has_wiki: want=false got=true'

rc=$(run check archived)
[ "$rc" = 0 ] && pass "check skips an archived repo instead of failing" || fail "check skips an archived repo (got $rc)"
assert_out "check labels the archived skip" 'SKIP.*archived'

rc=$(run check --all)
[ "$rc" = 1 ] && pass "check --all fails when any org repo drifted" || fail "check --all fails on drift (got $rc)"
assert_out "check --all reports the drifted repo" 'DRIFT.*testorg/drifted'
assert_out "check --all counts the audit" '1 of 2 repo\(s\) drifted'

rc=$(run check missing)
[ "$rc" = 1 ] && pass "check exits 1 on an unreadable repo" || fail "check exits 1 on an unreadable repo (got $rc)"

# --- apply ------------------------------------------------------------------
reset_patches
rc=$(run apply drifted)
[ "$rc" = 0 ] && pass "apply exits 0 after writing the policy" || fail "apply exits 0 (got $rc)"
sent=$(awk '$1 == "testorg/drifted" {print $2}' "$FIXTURES/_patches.log" | tail -1)
if [ -n "$sent" ] && printf '%s' "$sent" | jq -e --slurpfile want "$POLICY" '. == $want[0]' > /dev/null; then
    pass "apply sends the policy verbatim, every field in one PATCH"
else
    fail "apply sends the policy verbatim (sent: ${sent:-nothing})"
fi

reset_patches
rc=$(run apply archived)
[ "$rc" = 0 ] && pass "apply skips an archived repo" || fail "apply skips an archived repo (got $rc)"
[ ! -s "$FIXTURES/_patches.log" ] && pass "apply writes nothing to an archived repo" || fail "apply wrote to an archived repo"

reset_patches
rc=$(run apply projecty)
[ "$rc" = 0 ] && pass "apply survives a repo that refuses has_projects" || fail "apply survives a projects refusal (got $rc)"
assert_out "apply flags the repo whose projects stayed on" 'PARTIAL.*projecty'
sent=$(awk '$1 == "testorg/projecty" {print $2}' "$FIXTURES/_patches.log" | tail -1)
if printf '%s' "$sent" | jq -e 'has("has_projects") | not' > /dev/null \
   && printf '%s' "$sent" | jq -e '.allow_merge_commit == false and .has_wiki == false and .delete_branch_on_merge == true' > /dev/null; then
    pass "the retry drops only has_projects and keeps every other field"
else
    fail "the retry drops only has_projects (sent: ${sent:-nothing})"
fi

reset_patches
rc=$(run apply testorg/compliant)
[ "$rc" = 0 ] && pass "an owner/repo slug is accepted as-is" || fail "an owner/repo slug is accepted (got $rc)"
grep -q '^testorg/compliant ' "$FIXTURES/_patches.log" && pass "a bare name resolves against the org" || fail "target resolution wrote the wrong slug"

reset_patches
rc=$(run apply --all)
[ "$rc" = 0 ] && pass "apply --all exits 0" || fail "apply --all exits 0 (got $rc)"
if [ "$(cut -d' ' -f1 "$FIXTURES/_patches.log" | sort -u | tr '\n' ' ')" = "testorg/compliant testorg/drifted " ]; then
    pass "apply --all writes to every non-archived org repo and no others"
else
    fail "apply --all wrote to: $(cut -d' ' -f1 "$FIXTURES/_patches.log" | sort -u | tr '\n' ' ')"
fi

# --- usage ------------------------------------------------------------------
rc=$(run)
[ "$rc" = 2 ] && pass "no arguments prints usage and exits 2" || fail "no arguments exits 2 (got $rc)"
rc=$(run apply)
[ "$rc" = 2 ] && pass "apply with no target prints usage and exits 2" || fail "apply with no target exits 2 (got $rc)"
rc=$(run frobnicate --all)
[ "$rc" = 2 ] && pass "an unknown subcommand prints usage and exits 2" || fail "unknown subcommand exits 2 (got $rc)"

REPO_SETTINGS_POLICY="$WORK/absent.json" "$SCRIPT" check compliant > "$WORK/out" 2>&1
rc=$?
[ "$rc" = 1 ] && pass "a missing policy file fails loudly" || fail "a missing policy file fails loudly (got $rc)"

[ "$FAILURES" -eq 0 ] || exit 1
