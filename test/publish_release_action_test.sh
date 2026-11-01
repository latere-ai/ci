#!/usr/bin/env bash
#
# Tests for actions/publish-release/run.sh against a stub `gh` that keeps a
# release's state in files (absent, draft, published; body; assets) and a
# stub `go` for the note reader, which prints the section under a heading
# for the tag.
#
# Kept bash 3.2 compatible.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/actions/publish-release/run.sh"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# The release lives in $STUB_DIR/release: state, body, assets, args.
r=$STUB_DIR/release
echo "gh $*" >> "$STUB_DIR/calls"
[ "$1" = release ] || exit 64
cmd=$2; shift 2
tag=$1; shift
case "$cmd" in
    view) [ -f "$r/state" ] ;;
    create)
        mkdir -p "$r"; echo published > "$r/state"
        while [ $# -gt 0 ]; do
            case "$1" in
                --draft) echo draft > "$r/state" ;;
                --prerelease) touch "$r/prerelease" ;;
                --title) echo "$2" > "$r/title"; shift ;;
                --notes-file) cp "$2" "$r/body"; shift ;;
                --repo) shift ;;
                --verify-tag) ;;
                *) basename "$1" >> "$r/assets" ;;
            esac
            shift
        done ;;
    edit)
        while [ $# -gt 0 ]; do
            case "$1" in
                --draft=false) echo published > "$r/state" ;;
                --notes-file) cp "$2" "$r/body"; shift ;;
                --repo) shift ;;
            esac
            shift
        done ;;
    upload)
        while [ $# -gt 0 ]; do
            case "$1" in --repo) shift ;; --clobber) ;; *) basename "$1" >> "$r/assets" ;; esac
            shift
        done ;;
esac
STUB
cat > "$TMP/bin/go" <<'STUB'
#!/usr/bin/env bash
# go run <module>@<version> release-notes -C <dir> <tag>: the lines under
# "## <tag>" up to the next heading.
awk -v h="## $6" '$0 == h {on = 1; next} on && /^## / {exit} on' "$5/CHANGELOG.md" | grep . || exit 1
STUB
chmod +x "$TMP/bin/gh" "$TMP/bin/go"

# new_repo: a working directory with a CHANGELOG, an asset and evidence.
new_repo() {
    rm -rf "$TMP/w" "$TMP/release"
    : > "$TMP/calls"
    mkdir -p "$TMP/w/dist"
    printf '# Changelog\n\n## v1.2.0\n\nThe notes.\n\n## v1.3.0-rc1\n\nA candidate.\n' > "$TMP/w/CHANGELOG.md"
    echo archive > "$TMP/w/dist/app.tar.gz"
    echo sums > "$TMP/w/dist/checksums.txt"
    echo "conformance passed" > "$TMP/w/evidence.md"
}
publish() {
    (cd "$TMP/w" && PATH="$TMP/bin:$PATH" STUB_DIR=$TMP GITHUB_REPOSITORY=latere-ai/lux "$@" bash "$SCRIPT" 2>&1)
}

new_repo
if out=$(publish env GITHUB_REF_NAME=v1.2.0 TITLE=Lux FILES=$'dist/*' EVIDENCE=evidence.md); then
    pass "a release publishes"
else
    fail "a release publishes ($out)"
fi
[ "$(cat "$TMP/release/state")" = published ] && pass "it ends published" || fail "it ends published"
if grep -q -- "release create v1.2.0 --repo latere-ai/lux --verify-tag --draft " "$TMP/calls"; then
    pass "it is created as a draft against the existing tag"
else
    fail "it is created as a draft against the existing tag ($(cat "$TMP/calls"))"
fi
[ "$(cat "$TMP/release/title")" = "Lux v1.2.0" ] && pass "the title is the prefix and the tag" || fail "the title is the prefix and the tag ($(cat "$TMP/release/title"))"
if [ "$(sort "$TMP/release/assets" | tr '\n' ' ')" = "app.tar.gz checksums.txt " ]; then
    pass "every file the pattern names is attached"
else
    fail "every file the pattern names is attached ($(tr '\n' ' ' < "$TMP/release/assets"))"
fi
if [ "$(cat "$TMP/release/body")" = "$(printf 'The notes.\n\nconformance passed')" ]; then
    pass "the body is the CHANGELOG section, then the evidence after a blank line"
else
    fail "the body is the CHANGELOG section, then the evidence ($(cat "$TMP/release/body"))"
fi
[ ! -f "$TMP/release/prerelease" ] && pass "a stable tag is not a prerelease" || fail "a stable tag is not a prerelease"

# A re-run over a draft a failed run left: edit, replace, publish.
echo draft > "$TMP/release/state"
echo old > "$TMP/release/body"
: > "$TMP/calls"
if publish env GITHUB_REF_NAME=v1.2.0 FILES=dist/app.tar.gz > /dev/null \
    && ! grep -q "release create" "$TMP/calls" \
    && grep -q "release upload v1.2.0 --repo latere-ai/lux --clobber dist/app.tar.gz" "$TMP/calls" \
    && [ "$(cat "$TMP/release/state")" = published ] \
    && [ "$(cat "$TMP/release/body")" = "The notes." ]; then
    pass "a re-run edits the body, replaces the files and publishes a left draft"
else
    fail "a re-run edits the body, replaces the files and publishes a left draft ($(cat "$TMP/calls"))"
fi

new_repo
publish env GITHUB_REF_NAME=v1.3.0-rc1 > /dev/null
[ -f "$TMP/release/prerelease" ] && pass "a hyphen in the version core makes a prerelease" || fail "a hyphen in the version core makes a prerelease"
[ "$(cat "$TMP/release/title")" = "v1.3.0-rc1" ] && pass "no prefix titles it with the tag alone" || fail "no prefix titles it with the tag alone"

new_repo
if out=$(publish env GITHUB_REF_NAME=v9.9.9); then
    fail "a tag with no CHANGELOG section is refused"
elif printf '%s' "$out" | grep -qF "has no section for v9.9.9" && [ ! -d "$TMP/release" ]; then
    pass "a tag with no CHANGELOG section is refused before anything is created"
else
    fail "a tag with no CHANGELOG section is refused ($out)"
fi

new_repo
if out=$(publish env GITHUB_REF_NAME=v1.2.0 FILES=$'dist/*.zip'); then
    fail "a file pattern that matches nothing is refused"
elif printf '%s' "$out" | grep -qF "'dist/*.zip' names no file" && [ ! -d "$TMP/release" ]; then
    pass "a file pattern that matches nothing is refused before anything is created"
else
    fail "a file pattern that matches nothing is refused ($out)"
fi

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
