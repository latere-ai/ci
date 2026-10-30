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
    # Skip rather than fail: the ubuntu-latest runners this shell actually
    # runs on ship bash 5, so CI is the authoritative execution of this
    # suite. A local machine without bash 4+ must not report a red suite
    # for a shell incompatibility that cannot occur in production.
    printf "  \033[33mSKIP\033[0m needs bash 4+ (found %s); brew install bash\n" "${BASH_VERSION}"
    exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# assemble_body is the verbatim body line of the service-release "publish"
# step: the changelog section, a blank line, the smoke evidence. It reads notes.md and evidence.md in the working directory.
assemble_body() {
    { cat notes.md; printf '\n'; cat evidence.md; } > body.md
}

# publish_tail is the verbatim tail of the service-release "publish"
# step, from the asset collection through the create/edit branch.
publish_tail() {
    set -euo pipefail

    # The source and image SBOMs are attached to every release, and
    # CLI binaries (build_cli) beside them.
    assets=("$RUNNER_TEMP/sbom-source.cdx.json" "$RUNNER_TEMP/sbom-image.cdx.json")
    if [ "$BUILD_CLI" = "true" ]; then
        shopt -s nullglob
        cli=(dist/*)
        shopt -u nullglob
        [ ${#cli[@]} -gt 0 ] || { echo "build_cli set but dist/ is empty" >&2; exit 1; }
        assets+=("${cli[@]}")
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
        RUNNER_TEMP=/tmp/runner
        prerelease=""
        publish_tail
    ) || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$name"
    else
        fail "$name (exit ${rc}, every stubbed gh call succeeded)"
    fi
}

# Both SBOMs reach the release on the create path and on an edit re-run,
# with or without CLI binaries, and the binaries come after them.
test_sboms_are_attached() {
    local name="both SBOMs are attached on create and edit, CLI binaries after them"
    local dir rc=0
    dir=$(mktemp -d)
    (
        cd "$dir" || exit 1
        mkdir dist && touch dist/cli-linux-amd64
        RUNNER_TEMP=/tmp/runner
        TAG=v1.2.3
        TITLE=svc
        prerelease=""
        sboms="/tmp/runner/sbom-source.cdx.json /tmp/runner/sbom-image.cdx.json"

        # create path: gh release view fails, so the assets go to create.
        gh() { [ "$1 $2" = "release view" ] && return 1; printf '%s\n' "$*" >> calls; }
        BUILD_CLI=false publish_tail
        grep -qxF "release create v1.2.3 --title svc v1.2.3 --notes-file body.md $sboms" calls || exit 1
        rm calls
        BUILD_CLI=true publish_tail
        grep -qxF "release create v1.2.3 --title svc v1.2.3 --notes-file body.md $sboms dist/cli-linux-amd64" calls || exit 1
        rm calls

        # edit path: gh release view succeeds, so the assets go to upload.
        gh() { [ "$1 $2" = "release view" ] && return 0; printf '%s\n' "$*" >> calls; }
        BUILD_CLI=false publish_tail
        grep -qxF "release upload v1.2.3 $sboms --clobber" calls || exit 1
    ) || rc=$?
    rm -rf "$dir"
    if [ "$rc" -eq 0 ]; then
        pass "$name"
    else
        fail "$name"
    fi
}

# The body is the section, then the evidence, rebuilt from both on every
# run; an edit re-run must produce the same body as the create did, so a
# release never stacks two evidence blocks.
test_body_is_section_then_evidence() {
    local name="body is the changelog section, a blank line, then the evidence; a re-run is identical"
    local dir
    dir=$(mktemp -d)
    (
        cd "$dir" || exit 1
        printf 'The note.\n\n### Added\n\n- a thing\n' > notes.md
        printf '<!-- release-evidence -->\n\n## Release Evidence\n\n- Smoke: ok\n' > evidence.md
        assemble_body
        cp body.md first.md
        assemble_body
        expected=$'The note.\n\n### Added\n\n- a thing\n\n<!-- release-evidence -->\n\n## Release Evidence\n\n- Smoke: ok\n'
        [ "$(cat body.md)" = "$(printf '%s' "$expected")" ] && cmp -s first.md body.md
    )
    local rc=$?
    rm -rf "$dir"
    if [ "$rc" -eq 0 ]; then
        pass "$name"
    else
        fail "$name"
    fi
}

# The copy above must match what the workflow ships.
assert_body_line_matches_workflows() {
    local name="service-release.yml carries the tested body line"
    local line="{ cat notes.md; printf '\\n'; cat evidence.md; } > body.md"
    if grep -qF "$line" "$REPO_ROOT/.github/workflows/service-release.yml"; then
        pass "$name"
    else
        fail "$name"
    fi
}

assert_assets_line_matches_workflow() {
    local name="service-release.yml carries the tested assets line and the SBOM outputs it names"
    local wf="$REPO_ROOT/.github/workflows/service-release.yml"
    local line='assets=("$RUNNER_TEMP/sbom-source.cdx.json" "$RUNNER_TEMP/sbom-image.cdx.json")'
    if grep -qF "$line" "$wf" \
        && grep -qF 'output-file: ${{ runner.temp }}/sbom-source.cdx.json' "$wf" \
        && grep -qF 'output-file: ${{ runner.temp }}/sbom-image.cdx.json' "$wf"; then
        pass "$name"
    else
        fail "$name"
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
test_sboms_are_attached
test_body_is_section_then_evidence
assert_body_line_matches_workflows
assert_assets_line_matches_workflow
assert_no_bare_upload_conditional

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
