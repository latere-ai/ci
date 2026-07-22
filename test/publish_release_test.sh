#!/usr/bin/env bash
#
# Regression tests for the release-publish shell in the reusable
# workflows.
#
# A reusable workflow invoked as latere-ai/ci/.github/workflows/x.yml@v1
# does not ship sibling files to the consumer runner, so the publish
# block cannot be extracted into a script that the workflow sources.
# The block below is therefore a copy of the inline YAML and can drift;
# assert_no_bare_upload_conditional greps the workflow so drift is
# caught.
#
# Requires bash 4+: on bash 3.2 (macOS /bin/bash) "${arr[@]}" on an
# empty array errors under set -u, a failure mode that does not exist
# on the ubuntu-latest runners this shell actually runs on.
set -uo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [ -x "$candidate" ] && exec "$candidate" "$0" "$@"
    done
    echo "publish_release_test: needs bash 4+ (found ${BASH_VERSION}); brew install bash" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# publish_tail is the verbatim tail of the service-release "publish"
# step, from the asset collection through the create/edit branch.
publish_tail() {
    set -euo pipefail

    # CLI binaries (build_cli) are attached to the release.
    assets=()
    if [ "$BUILD_CLI" = "true" ]; then
        shopt -s nullglob
        assets=(dist/*)
        shopt -u nullglob
        [ ${#assets[@]} -gt 0 ] || { echo "build_cli set but dist/ is empty" >&2; exit 1; }
    fi

    if gh release view "$TAG" >/dev/null 2>&1; then
        gh release edit "$TAG" --notes-file body.md
        if [ ${#assets[@]} -gt 0 ]; then
            gh release upload "$TAG" "${assets[@]}" --clobber
        fi
    else
        gh release create "$TAG" $prerelease \
            --title "${TITLE} ${TAG}" \
            --notes-file body.md "${assets[@]}"
    fi
}

test_edit_path_without_cli() {
    local name="publish edit path succeeds when build_cli is false"
    local rc=0
    (
        gh() { return 0; }
        BUILD_CLI=false
        TAG=v1.2.3
        TITLE=svc
        prerelease=""
        publish_tail
    ) || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$name"
    else
        fail "$name (exit ${rc}, every stubbed gh call succeeded)"
    fi
}

assert_no_bare_upload_conditional() {
    local name="workflows carry no bare '] && gh release upload' conditional"
    local hits
    hits=$(grep -rn '\] && gh release upload' "$REPO_ROOT/.github/workflows" || true)
    if [ -z "$hits" ]; then
        pass "$name"
    else
        fail "$name"
        printf '%s\n' "$hits"
    fi
}

test_edit_path_without_cli
assert_no_bare_upload_conditional

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
