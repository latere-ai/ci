---
title: Every release pipeline publishes the changelog section, and fails without one
status: draft
depends_on:
  - ../../ci-gate/specs/012-a-tag-is-a-release.md
affects:
  - ci/.github/workflows/service-release.yml
  - ci/.github/workflows/cli-release.yml
  - ci/.github/workflows/images-release.yml
  - ci/.github/workflows/notes-release.yml (new)
  - ci/examples/notes-release.yml (new)
  - ci/test/publish_release_test.sh
  - ci/test/release_notes_test.sh (new)
  - ci/README.md
  - every repository that tags (adoption, listed under Rollout)
effort: medium
trigger: 29 of 30 tagged repositories publish a release whose body is one compare link; pkg's changelog rule moved into lateregate (ci-gate 012) and the pipelines are where it becomes universal
created: 2026-09-06
updated: 2026-09-06
author: changkun
dispatched_task_id: null
---

# Every release pipeline publishes the changelog section

## Context

ci-gate spec 012 put the changelog rule into the binary: `lateregate
release-notes TAG` prints the `CHANGELOG.md` section for a tag or fails,
the pre-push refuses a release tag without one, and `lateregate release`
cuts the tag. What the binary cannot do is publish the GitHub release. The
three reusable pipelines here do that, today from `generate-notes` behind
`|| true`, which on a repository that commits to main directly yields a
compare link and never fails. This spec makes every pipeline read the
section, fail closed without it, and publish it as the body.

## The decision

**One step, the same in every release workflow.** After checkout and
setup-go:

```yaml
- name: Read the release note for this tag
  run: go run latere.ai/x/ci-gate/cmd/lateregate@${{ inputs.lateregate_version }} release-notes "$GITHUB_REF_NAME" > notes.md
```

`go run` at a pinned version rather than `go tool`, because the pipeline
runs in repositories that do not pin the tool (an image catalog, a
TypeScript SDK, a bun library) and in Go repositories whose pin may predate
the command. The version is a workflow input with a default, like
`goreleaser_version`, and moves by editing this repository. The module is
fetched through the Go proxy and verified against the checksum database,
which is the same trust every `go get` in the organisation already places.

**The body is the section, then the evidence.** `service-release.yml` and
`images-release.yml` write `notes.md`, a blank line, the evidence marker
and the smoke evidence, and create or edit the release with that. The
"reuse the existing body as prefix" branch goes: the section is the same on
a re-run, so the body is rebuilt from the changelog every time and a re-run
replaces rather than stacks. `cli-release.yml` passes `--release-notes
notes.md` to goreleaser, which then publishes that file instead of its
commit list; the consumer's `changelog:` block becomes unused and is
deleted on adoption.

**A fourth pipeline for repositories that build nothing.** pkg, ci-gate,
latere-ui and topos tag a module or a library: no image, no deploy, no
binaries to attach. `notes-release.yml` is checkout, setup-go, the step
above, and `gh release create --title TAG --notes-file notes.md
--verify-tag`, with `--prerelease` when the version core carries a hyphen.
It takes `title` as an optional input for the same reason
`service-release.yml` does, and `lateregate_version`.

**Fail closed is the contract.** A missing section fails the job before
anything is created or edited. In `service-release.yml` the release job is
the last one, so production is already serving the tag when this fails;
that is the intended order (a release announces what is live) and the fix
is to add the section and re-run the job, not to re-tag. The pre-push hook
exists so this branch is rarely taken.

**Tests.** `publish_release_test.sh` keeps its verbatim copy of the publish
tail and gains the body assembly: the body is the section, a blank line,
the marker, the evidence, and an edit re-run produces the same body.
`release_notes_test.sh` greps every `*-release.yml` for the `release-notes`
step and for the absence of `generate-notes`, so a pipeline cannot slip
back.

## Acceptance

1. Each of the four release workflows carries the `release-notes` step with
   the pinned version input, and none carries `generate-notes` or
   `--generate-notes`; `test/run.sh` asserts both.
2. `service-release.yml` and `images-release.yml` build the body as
   section, blank line, marker, evidence; the publish-tail copy in the test
   matches the workflow; an edit path produces the same body as a create.
3. `cli-release.yml` runs goreleaser with `--release-notes notes.md`.
4. `notes-release.yml` publishes a release whose body is exactly the
   section, marks a prerelease, and fails on a tag with no section.
5. `actionlint` passes; `README.md` documents the changelog convention as a
   consumer contract, the fourth pipeline, and the `lateregate_version`
   input.
6. A canary: one service repository cuts a tag with a section and the
   release body opens with it; the same repository is refused a tag without
   one at the pre-push.

## Rollout

Every repository that tags adopts in one commit each. In order:

1. This repository: land, tag `v1.8.0`, and `v1` moves.
2. ci-gate: `.github/workflows/release.yml` calling `notes-release.yml@v1`;
   its next tag publishes its own note.
3. pkg: `release.yml` calls `notes-release.yml@v1`; `Makefile` `release`
   and `release-notes` delegate; the two scripts and the hook's own lines
   are deleted.
4. The 13 `service-release.yml` consumers (ai-as-an-infrastructure, auth,
   drive, eval, latere-ai, lectio, lux, platform, replichai, sandbox, and
   the rest): bump the ci-gate pin, `lateregate init` seeds `CHANGELOG.md`,
   commit. `v1` carries the workflow change.
5. latere-cli: switch its own goreleaser workflow to `cli-release.yml@v1`
   and drop the `changelog:` block.
6. wallfacer, service-template, agents: vendored pipelines gain the step and
   lose `generate-notes`.
7. lux-python-sdk, lux-typescript-sdk: `publish.yml` gains setup-go and the
   step, and `gh release create` takes `--notes-file` instead of
   `--generate-notes`.
8. images: confirm which pipeline its `release.yml` runs and adopt the step
   there.
9. latere-ui, topos: a `release.yml` calling `notes-release.yml@v1`.
10. Repositories on lateregate that have never tagged (llmops, tgo, origo,
    managed-agents, pay, llm-gateway-bench): the pin bump seeds the
    changelog; nothing else.

Each seeded changelog starts empty under `## Unreleased`; the first tag
after adoption is the first that needs a note, and the pre-push says so.
