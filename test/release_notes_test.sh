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

READER='go run latere.ai/x/ci-gate/cmd/lateregate@${{ inputs.lateregate_version }} release-notes "$TAG" > notes.md'

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
        if ! grep -qE -- '--notes-file (body|notes)\.md|--release-notes notes\.md' "$wf"; then
            missing="${missing} $(basename "$wf")"
        fi
    done
    if [ -z "$missing" ]; then
        pass "$name"
    else
        fail "$name (missing in:${missing})"
    fi
}

test_four_release_workflows_exist() {
    local name="the four release pipelines exist: service, cli, images, notes"
    local ok=1
    for kind in service cli images notes; do
        [ -f "$REPO_ROOT/.github/workflows/${kind}-release.yml" ] || ok=0
    done
    if [ "$ok" -eq 1 ]; then
        pass "$name"
    else
        fail "$name"
    fi
}

test_every_release_workflow_reads_the_section
test_every_release_workflow_declares_the_version_input
test_no_workflow_generates_notes
test_every_release_workflow_publishes_notes
test_four_release_workflows_exist

if [ "$FAILURES" -gt 0 ]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
