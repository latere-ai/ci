# Contributing

This file is for people changing the pipelines. Calling them from a
repository is the [README](README.md). Every bug fix ships with a test
that fails without it, and every change is one small commit with a
message that says why.

## Getting set up

You need bash, git, Go at the version `go.mod` names,
[actionlint](https://github.com/rhysd/actionlint) and
[shellcheck](https://www.shellcheck.net/), which actionlint runs over
every `run:` block. Reusable workflows, `secrets: inherit` and
environments only run on GitHub's runners, so a pipeline cannot be
executed locally. The local loop is:

```bash
git config core.hooksPath .githooks   # once: the pre-commit and pre-push hooks
bash test/run.sh                      # the regression suite; CI runs it on every push and pull request
actionlint                            # static workflow lint; CI runs it on every push and pull request
go tool lateregate                    # the shared bar, as the per-push gate runs it here
```

The suite is two kinds of check: unit tests over copies of the shell a
workflow runs inline (the tag classification, the changelog read, the
coverage upload), and grep assertions that each copy still matches what
the workflow ships, so the copies cannot drift. `tools/repo-settings.sh`
is tested against a stub `gh` that serves fixtures and records every
write, and further assertions hold the supply-chain rules (every `uses:`
pinned to a SHA).

A decision a pipeline makes belongs in a script under `actions/`, which a
stage runs from ci at its own commit, and gets a test in `test/` that runs
that script itself; `test/stub_gh.sh` stubs the GitHub CLI for it. Inline
shell that stays in a workflow gets a copy and a test, as before.
`test/run.sh` picks up any `*_test.sh`.

## Sending a change

1. Keep each change to one small commit whose message reads
   `scope: lowercase description`, the scope being the workflow, action
   or file it changes, with the reason in the body when the subject
   does not carry it.
2. A bug fix carries a test in `test/` that fails without it; a new
   decision in a script gets a test that runs the script.
3. Run `bash test/run.sh`, `actionlint` and `go tool lateregate`.
4. Write the change under `## Unreleased` in `CHANGELOG.md` for whoever
   calls the pipelines. Mark it **Breaking** when a caller must change
   something, or when a run that passed before can now fail.
5. Open a pull request against `main`; the `test`, `actionlint` and `ci`
   workflows check it.

Contributions are accepted under the repository's [MIT license](LICENSE),
as the license itself provides. There is no contributor agreement and no
sign-off line.

## How a change reaches callers

Callers pin `@v1`. Landing on main changes nothing for them: these
workflows run in other repositories with `contents: write`,
`packages: write` and inherited secrets, so main is not trusted until a
version is cut.

1. Write under `## Unreleased` in `CHANGELOG.md` what changed for whoever
   calls the pipelines: a new input, a changed default, a job that moved.
2. To try a change on one repository first, push a prerelease tag
   (`v1.18.0-rc1`) and point that repository's caller at it
   (`@v1.18.0-rc1`). A prerelease tag does not move `v1`.
3. Cut the version from a clean checkout of `main` at origin's tip with
   `go tool lateregate release v1.MINOR.PATCH`. It moves the notes into a
   `## v1.MINOR.PATCH - <date>` section, commits, and pushes the commit and
   an annotated tag together. It refuses while CI is red on `main`. The root
   `go.mod` pins `lateregate` and nothing else. `release.yml` publishes the
   GitHub release from that section through this repository's own
   `notes-release.yml`, and `major-tag.yml` moves `v1` to the tag.

## Pinning

Every `uses:` is pinned to a full commit SHA with the version in a
trailing comment, and no step fetches a tool at `latest`. A third-party
action's commit is the organization's one commit for it, from the list
ci-gate embeds (`internal/actionpins/action.yml` in latere-ai/ci-gate);
its `action-pins` gate holds this repository to that list as it does
every other. A version moves there first: Dependabot in ci-gate opens the
update, the ci-gate release carries it, and here `go tool lateregate
action-pins -w` rewrites the pins in the same commit that moves the gate.
This repository runs no Dependabot of its own for actions, since one
repository moving one action alone would fail the gate. A tool version the
workflows fetch is an input with a pinned default, so a caller can move
ahead of the default without a change here.

## Writing

Every sentence the pipelines emit or carry is written for one reader, and
the register follows the reader:

- User, a person or a coding harness: workflow step summaries, error
  annotations, the release body a calling repository publishes, and the
  README. Short and plain: what happened and what to do next, naming a
  command or a page.
- Contributor, someone changing the pipelines: specs, this file, commit
  messages, source comments. Precise, in the project's own terms, with
  the reason a design is what it is.
- Developer, someone debugging a run: step logs and the test scripts'
  failure output. Exact and complete: object, operation, observed value,
  expected value, and the underlying error.

The canonical statement and the review checklist are
[`docs/writing/registers.md`](https://github.com/latere-ai/pkg/blob/main/docs/writing/registers.md)
in `latere-ai/pkg`. The design records behind the larger pipelines are in
[`specs/`](specs/).

## Reporting a vulnerability

Not in an issue: [`SECURITY.md`](SECURITY.md) says how to report one
privately and what the pipelines protect.
