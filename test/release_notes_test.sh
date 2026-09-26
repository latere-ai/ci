#!/usr/bin/env bash
#
# Every release pipeline publishes the tag's CHANGELOG.md section and fails
# without one. These greps hold each *-release.yml to that: the pinned
# lateregate reader is the step that produces notes.md, the version is an
# input with a default, and nothing falls back to GitHub's generate-notes,
# which on a repository that commits to main directly yields a compare link
# and never fails.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# The reader, up to the redirect; where the notes go is the job's choice,
# and a goreleaser job's choice is held by the test further down.
READER='go run latere.ai/x/ci-gate/cmd/lateregate@${{ inputs.lateregate_version }} release-notes -C "$notes_root" "$TAG" > '

release_workflows() {
    ls "$REPO_ROOT"/.github/workflows/*-release.yml
}

test_every_release_workflow_reads_the_section() {
    local name="every *-release.yml reads the changelog section with the pinned reader"
    local missing=""
    for wf in $(release_workflows); do
        if ! grep -qF "$READER" "$wf"; then
            missing="${missing} $(basename "$wf")"
        fi
    done
    if [ -z "$missing" ]; then
        pass "$name"
    else
        fail "$name (missing in:${missing})"
    fi
}

test_every_release_workflow_declares_the_version_input() {
    local name="every *-release.yml declares lateregate_version with a vX.Y.Z default"
    local missing=""
    for wf in $(release_workflows); do
        if ! grep -A4 '^      lateregate_version:' "$wf" | grep -qE 'default: "v[0-9]+\.[0-9]+\.[0-9]+"'; then
            missing="${missing} $(basename "$wf")"
        fi
    done
    if [ -z "$missing" ]; then
        pass "$name"
    else
        fail "$name (missing in:${missing})"
    fi
}

test_no_workflow_generates_notes() {
    local name="no workflow falls back to GitHub generate-notes"
    local hits
    hits=$(grep -rn 'generate-notes\|--generate-notes' "$REPO_ROOT/.github/workflows" || true)
    if [ -z "$hits" ]; then
        pass "$name"
    else
        fail "$name"
        printf '%s\n' "$hits"
    fi
}

test_every_release_workflow_publishes_notes() {
    local name="every *-release.yml publishes from notes.md (gh --notes-file or goreleaser --release-notes)"
    local missing=""
    for wf in $(release_workflows); do
        if ! grep -qE -- '--notes-file (body|notes)\.md|--release-notes \$\{\{ runner\.temp \}\}/notes\.md' "$wf"; then
            missing="${missing} $(basename "$wf")"
        fi
    done
    if [ -z "$missing" ]; then
        pass "$name"
    else
        fail "$name (missing in:${missing})"
    fi
}

test_three_release_workflows_exist() {
    local name="the three release pipelines exist: service, cli, notes"
    local ok=1
    for kind in service cli notes; do
        [ -f "$REPO_ROOT/.github/workflows/${kind}-release.yml" ] || ok=0
    done
    if [ "$ok" -eq 1 ]; then
        pass "$name"
    else
        fail "$name"
    fi
}

# The pinned reader predates consumer config fields such as identity/enums.
# It must receive only the tag's changelog, not the consumer's gate config.
test_reader_is_independent_of_consumer_config() {
    local wf missing=""
    for wf in $(release_workflows); do
        if ! grep -qF 'cp CHANGELOG.md "$notes_root/CHANGELOG.md"' "$wf" \
            || ! grep -qF 'release-notes -C "$notes_root" "$TAG" > ' "$wf"; then
            missing="${missing} $(basename "$wf")"
        fi
    done
    if [ -z "$missing" ]; then
        pass "release notes do not parse the consumer gate configuration"
    else
        fail "release notes parse unrelated gate configuration:${missing}"
    fi
}

# goreleaser refuses to publish from a checkout with untracked files, and
# --clean only clears dist/. A notes file written into the checkout fails
# every release at that check, after the tests have passed, so a workflow
# that runs goreleaser writes the notes under the runner's temp directory and
# hands goreleaser that path.
test_goreleaser_notes_stay_outside_the_checkout() {
    local name="a workflow that runs goreleaser writes and reads its notes outside the checkout"
    local wf bad="" target args arg seen=0
    for wf in "$REPO_ROOT"/.github/workflows/*.yml; do
        grep -q 'uses: goreleaser/goreleaser-action@' "$wf" || continue
        seen=$((seen + 1))
        target=$(grep -oE 'release-notes -C "\$notes_root" "\$TAG" > [^ ]+' "$wf" | sed 's/.* > //')
        if [ "$target" != '"$RUNNER_TEMP/notes.md"' ]; then
            bad="${bad} $(basename "$wf"):writes=${target:-none}"
        fi
        # Every notes path on a goreleaser args line is under runner.temp.
        # The path is an expression, `${{ runner.temp }}/notes.md`, three
        # words long, so the match takes up to two words after the first.
        args=$(grep -E '^[[:space:]]*args:.*--release-notes ' "$wf" | grep -oE -- '--release-notes [^ ]+( [^ ]+ [^ ]+)?' | sed 's/^--release-notes //')
        if [ -z "$args" ]; then
            bad="${bad} $(basename "$wf"):reads=none"
        fi
        while IFS= read -r arg; do
            [ -n "$arg" ] || continue
            case "$arg" in
                '${{ runner.temp }}/'*) ;;
                *) bad="${bad} $(basename "$wf"):reads=${arg}" ;;
            esac
        done <<< "$args"
    done
    if [ "$seen" -eq 0 ]; then
        fail "$name (no workflow runs goreleaser; the check has nothing to hold)"
    elif [ -z "$bad" ]; then
        pass "$name"
    else
        fail "$name (${bad# })"
    fi
}

test_reader_is_independent_of_consumer_config
test_goreleaser_notes_stay_outside_the_checkout

test_every_release_workflow_reads_the_section
test_every_release_workflow_declares_the_version_input
test_no_workflow_generates_notes
test_every_release_workflow_publishes_notes
test_three_release_workflows_exist

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
