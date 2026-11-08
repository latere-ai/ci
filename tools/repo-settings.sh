#!/usr/bin/env bash
#
# Applies and audits the org-wide repository settings policy.
#
# Repository settings are per-repo state that no release pipeline touches, so
# they drift the moment someone creates a repo: GitHub's own defaults enable
# merge commits, rebase merges, wikis and projects. This script holds one
# desired state (tools/repo-settings.json) and drives every repo to it, so a
# new repo is one command away from the policy and an existing one can be
# audited without opening 30 settings pages.
#
#   repo-settings.sh apply <repo>...    drive the named repos to the policy
#   repo-settings.sh apply --all        drive every non-archived org repo
#   repo-settings.sh check <repo>...    report drift, exit 1 if any
#   repo-settings.sh check --all        audit the whole org
#
# A repo argument is either a bare name (resolved against --org) or a full
# owner/repo slug. Archived repos are read-only on the GitHub API, so they are
# reported and skipped rather than failed.
#
# Needs the `gh` CLI authenticated with admin rights on the target repos
# (`repo` scope on a classic token, plus `read:org` for --all).
#
# Kept bash 3.2 compatible so it runs on macOS /bin/bash as well as the
# ubuntu-latest runners.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_FILE="${REPO_SETTINGS_POLICY:-$SCRIPT_DIR/repo-settings.json}"
ORG="${REPO_SETTINGS_ORG:-latere-ai}"

pass() { printf "  \033[32m%-7s\033[0m %s\n" "$1" "$2"; }
warn() { printf "  \033[33m%-7s\033[0m %s\n" "$1" "$2"; }
bad()  { printf "  \033[31m%-7s\033[0m %s\n" "$1" "$2"; }

usage() {
    sed -n '/^#   repo-settings.sh/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-2}"
}

# GitHub rejects a PATCH that disables Projects on a repo that still owns
# classic projects. That is per-repo state the caller cannot know in advance,
# so the retry drops has_projects and keeps every other field, rather than
# deleting someone's projects to force the write through.
policy_without_projects() { jq 'del(.has_projects)' "$POLICY_FILE"; }

# True when the PATCH error in $1 is GitHub refusing to disable Projects (an
# HTTP 422 that names projects). Any other failure is not worth a retry: it
# would only repeat, or hide a real error behind a half-applied policy.
is_projects_refusal() {
    printf '%s' "$1" | grep -q '422' && printf '%s' "$1" | grep -qi 'project'
}

# Prints one "key: want=X got=Y" line per field that differs. Empty output
# means the repo already matches the policy.
diff_settings() {
    local actual="$1" policy="$2"
    jq -nr --slurpfile want "$policy" --argjson got "$actual" '
        $want[0] | to_entries
        | map(select(.value != ($got[.key])))
        | .[] | "\(.key): want=\(.value|tostring) got=\($got[.key]|tostring)"'
}

resolve_targets() {
    local arg slug
    if [ "$1" = "--all" ]; then
        gh api --paginate "/orgs/$ORG/repos?per_page=100" \
            | jq -sr 'add // [] | .[] | select(.archived == false) | .full_name'
        return
    fi
    for arg in "$@"; do
        case "$arg" in
            */*) slug="$arg" ;;
            *)   slug="$ORG/$arg" ;;
        esac
        printf '%s\n' "$slug"
    done
}

# Reads the repository into $REPO_JSON. When gh fails, or answers with
# something that is not an object, it reports a FAIL with the error and
# returns 1: gh prints an HTTP error's body on stdout too, so the output alone
# proves nothing. It is not called in a command substitution, which would
# swallow the FAIL line.
read_repo() {
    local slug="$1" out
    if ! out=$(gh api "/repos/$slug" 2>&1); then
        bad FAIL "$slug :: cannot read repository: $(printf '%s' "$out" | tr '\n' ' ')"
        return 1
    fi
    if ! printf '%s' "$out" | jq -e 'type == "object"' > /dev/null 2>&1; then
        bad FAIL "$slug :: the answer for the repository is not JSON"
        return 1
    fi
    REPO_JSON="$out"
}

# Returns 0 for OK and SKIP, 2 for PARTIAL (every setting but has_projects
# landed, which is not a failure) and 1 for FAIL.
apply_one() {
    local slug="$1" actual err
    read_repo "$slug" || return 1
    actual="$REPO_JSON"
    if [ "$(printf '%s' "$actual" | jq -r '.archived')" = "true" ]; then
        warn SKIP "$slug (archived, settings are read-only)"
        return 0
    fi
    if err=$(gh api -X PATCH "/repos/$slug" --input "$POLICY_FILE" --silent 2>&1); then
        pass OK "$slug"
        return 0
    fi
    if is_projects_refusal "$err" \
       && policy_without_projects | gh api -X PATCH "/repos/$slug" --input - --silent 2>/dev/null; then
        warn PARTIAL "$slug (projects left enabled: close its classic projects first)"
        return 2
    fi
    bad FAIL "$slug :: $(printf '%s' "$err" | tr '\n' ' ')"
    return 1
}

check_one() {
    local slug="$1" actual drift
    read_repo "$slug" || return 1
    actual="$REPO_JSON"
    if [ "$(printf '%s' "$actual" | jq -r '.archived')" = "true" ]; then
        warn SKIP "$slug (archived, settings are read-only)"
        return 0
    fi
    if ! drift=$(diff_settings "$actual" "$POLICY_FILE"); then
        bad FAIL "$slug :: cannot compare with the policy"
        return 1
    fi
    if [ -z "$drift" ]; then
        pass OK "$slug"
        return 0
    fi
    bad DRIFT "$slug"
    printf '%s\n' "$drift" | sed 's/^/            /'
    return 1
}

main() {
    case "${1:-}" in
        -h|--help) usage 0 ;;
    esac
    [ $# -ge 1 ] || usage
    local cmd="$1"; shift
    [ $# -ge 1 ] || usage
    case "$cmd" in
        apply|check) ;;
        *)           usage ;;
    esac
    if [ ! -f "$POLICY_FILE" ]; then
        bad FAIL "policy file not found: $POLICY_FILE"
        exit 1
    fi

    # Every comparison reads the policy; a file that is not a JSON object would
    # otherwise make jq fail quietly and read as "no drift".
    if ! jq -e 'type == "object"' "$POLICY_FILE" > /dev/null 2>&1; then
        bad FAIL "policy file is not a JSON object: $POLICY_FILE"
        exit 1
    fi

    local targets failed=0 partial=0 total=0 slug rc
    # A failed page would leave the earlier pages audited and the run green.
    if ! targets=$(resolve_targets "$@"); then
        bad FAIL "cannot list the repositories"
        exit 1
    fi
    if [ -z "$targets" ]; then
        bad FAIL "no target repositories"
        exit 1
    fi

    printf "\033[1m%s\033[0m against %s\n" "$cmd" "$POLICY_FILE"
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        total=$((total + 1))
        if [ "$cmd" = "apply" ]; then
            apply_one "$slug"
            rc=$?
            case "$rc" in
                0) ;;
                2) partial=$((partial + 1)) ;;
                *) failed=$((failed + 1)) ;;
            esac
        else
            check_one "$slug" || failed=$((failed + 1))
        fi
    done <<EOF
$targets
EOF

    if [ "$failed" -gt 0 ]; then
        if [ "$cmd" = "check" ]; then
            printf "\n\033[31m%d of %d repo(s) drifted from the policy\033[0m\n" "$failed" "$total"
        else
            printf "\n\033[31m%d of %d repo(s) failed\033[0m\n" "$failed" "$total"
        fi
        exit 1
    fi
    if [ "$partial" -gt 0 ]; then
        printf "\n\033[33m%d repo(s) match the policy, %d partial (projects left enabled)\033[0m\n" \
            "$((total - partial))" "$partial"
        return
    fi
    printf "\n\033[32m%d repo(s) match the policy\033[0m\n" "$total"
}

main "$@"
