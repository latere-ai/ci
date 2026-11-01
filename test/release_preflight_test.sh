#!/usr/bin/env bash
#
# Tests for actions/release-preflight/run.sh, run in real clones of a bare
# origin. A stub `go` stands in for lateregate's note reader: it succeeds
# when the copied CHANGELOG.md holds a heading for the tag.
#
# Kept bash 3.2 compatible.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/actions/release-preflight/run.sh"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

mkdir -p "$TMP/bin"
cat > "$TMP/bin/go" <<'STUB'
#!/usr/bin/env bash
# go run <module>@<version> release-notes -C <dir> <tag>
[ "$1" = run ] && [ "$3" = release-notes ] && [ "$4" = -C ] || { echo "stub go: $*" >&2; exit 64; }
grep -q "^## \[\{0,1\}${6#v}\]\{0,1\}\|^## \[\{0,1\}$6\]\{0,1\}" "$5/CHANGELOG.md"
STUB
chmod +x "$TMP/bin/go"

ORIGIN="$TMP/origin.git"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "file://$ORIGIN" "$TMP/seed" 2>/dev/null
seed() { git -C "$TMP/seed" "$@"; }
seed checkout -q -b main
printf '# Changelog\n\n## v1.0.0\n\nFirst.\n\n## v1.1.0-rc1\n\nA candidate.\n\n## v1.2.0+meta\n\nMetadata.\n' > "$TMP/seed/CHANGELOG.md"
seed add CHANGELOG.md
seed commit -q -m c1
seed tag v1.0.0
seed tag v1.1.0-rc1
seed tag v1.2.0+meta
seed tag v9.9.9
seed checkout -q --detach
seed commit -q --allow-empty -m "off main"
seed tag v1.0.1
seed push -q origin main v1.0.0 v1.1.0-rc1 v1.2.0+meta v9.9.9 v1.0.1 2>/dev/null

# check NAME TAG OWNER OVERRIDE WANT_RC WANT_TEXT [WANT_OUTPUT_LINE]
check() {
    local name=$1 tag=$2 owner=$3 override=$4 want=$5 text=$6 line=${7:-} dir out rc
    dir=$(mktemp -d "$TMP/clone.XXXX")
    git clone -q --depth 1 --branch "$tag" "file://$ORIGIN" "$dir/w" 2>/dev/null
    : > "$dir/out"
    out=$(cd "$dir/w" && PATH="$TMP/bin:$PATH" GITHUB_OUTPUT="$dir/out" GITHUB_REF_NAME=$tag \
        GITHUB_REPOSITORY_OWNER=$owner NAMESPACE_OVERRIDE=$override DEFAULT_BRANCH=main \
        bash "$SCRIPT" 2>&1)
    rc=$?
    if [ "$rc" -ne "$want" ] || ! printf '%s' "$out" | grep -qF -- "$text"; then
        fail "$name (exit $rc, want $want; output: $out)"
        return
    fi
    if [ -n "$line" ] && ! grep -qxF -- "$line" "$dir/out"; then
        fail "$name (no output line '$line' in: $(tr '\n' ' ' < "$dir/out"))"
        return
    fi
    pass "$name"
}

check "a tag on main with notes passes, under the owner lowered" v1.0.0 Latere-AI "" 0 "images publish under latere-ai" "owner=latere-ai"
check "a stable tag is not a prerelease" v1.0.0 latere-ai "" 0 "" "prerelease=false"
check "a hyphen in the version core marks a prerelease" v1.1.0-rc1 latere-ai "" 0 "" "prerelease=true"
check "the build identity carries the short commit" v1.0.0 latere-ai "" 0 "" "commit=$(git -C "$TMP/seed" rev-parse --short v1.0.0)"
check "build metadata is refused before anything else" v1.2.0+meta latere-ai "" 1 "carries SemVer build metadata"
check "a tag off the default branch is refused" v1.0.1 latere-ai "" 1 "v1.0.1 is not on main"
check "a tag with no CHANGELOG section is refused" v9.9.9 latere-ai "" 1 "has no section for v9.9.9"
check "the namespace override wins, lowered" v1.0.0 latere-ai "Example/Images" 0 "" "owner=example/images"
check "an invalid namespace is refused" v1.0.0 latere-ai "bad..name" 1 "is not a valid image namespace"

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
