# Contributing

This file is for people changing the pipelines. Calling them from a
repository is the [README](README.md). Every bug fix ships with a test
that fails without it, and every change is one small commit with a
message that says why.

## Local checks

Reusable workflows, `secrets: inherit` and environments only run on
GitHub's runners, so a pipeline cannot be executed locally. The local
loop is:

```bash
bash test/run.sh   # the regression suite; CI runs it on every push and pull request
actionlint         # static workflow lint; CI runs it on every push and pull request
```

The suite is two kinds of check: unit tests over copies of the shell a
workflow runs inline (the tag classification, the changelog read, the
coverage upload), and grep assertions that each copy still matches what
the workflow ships, so the copies cannot drift. `tools/repo-settings.sh`
is tested against a stub `gh` that serves fixtures and records every
write, and further assertions hold the supply-chain rules (every `uses:`
pinned to a SHA).

A new inline script that makes a decision gets a copy and a test in
`test/`, and `test/run.sh` picks up any `*_test.sh` beside it.

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
3. Cut the version: move the notes into a `## v1.MINOR.PATCH - <date>`
   section, commit, and push the tag. `release.yml` publishes the GitHub
   release from that section through this repository's own
   `notes-release.yml`, and `major-tag.yml` moves `v1` to the tag.

## Pinning

Every `uses:` is pinned to a full commit SHA with the version in a
trailing comment, and no step fetches a tool at `latest`. Dependabot
opens a weekly pull request per action so the pins do not rot:
first-party `actions/*` and `docker/*` updates are grouped, and
third-party actions land individually so each gets its own review. A
tool version the workflows fetch is an input with a pinned default, so a
caller can move ahead of the default without a change here.

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
