#!/usr/bin/env bash
#
# A stub `gh` for the tests of the action scripts, sourced by a test.
# stub_gh_install DIR puts it at DIR/bin/gh and serves `gh api URL --jq EXPR`
# from DIR/fixtures, applying EXPR with jq as gh would. The fixture for a URL
# is named by the URL with every character outside [A-Za-z0-9] made `_`;
# NAME.1, NAME.2 and so on answer the first, second and later calls, and
# NAME answers every call that has no numbered file. A fixture holding
# FAIL makes the call exit 1. Every call is appended to DIR/calls.
#
# Kept bash 3.2 compatible.

stub_gh_install() {
    local dir=$1
    mkdir -p "$dir/bin" "$dir/fixtures"
    : > "$dir/calls"
    cat > "$dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
dir=${STUB_GH_DIR:?}
echo "$*" >> "$dir/calls"
[ "${1:-}" = api ] || { echo "stub gh: unsupported command $*" >&2; exit 64; }
url=$2
expr=.
if [ "${3:-}" = --jq ]; then expr=$4; fi
key=$(printf '%s' "$url" | tr -c 'A-Za-z0-9' '_')
count="$dir/fixtures/$key.count"
n=$(( $(cat "$count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$count"
f="$dir/fixtures/$key.$n"
[ -f "$f" ] || f="$dir/fixtures/$key"
[ -f "$f" ] || { echo "stub gh: no fixture for $url" >&2; exit 1; }
[ "$(cat "$f")" = FAIL ] && { echo "stub gh: $url failed" >&2; exit 1; }
jq -r "$expr" "$f"
STUB
    chmod +x "$dir/bin/gh"
}

# stub_gh_fixture DIR URL CONTENT [N]
stub_gh_fixture() {
    local key
    key=$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '_')
    printf '%s\n' "$3" > "$1/fixtures/$key${4:+.$4}"
}
