# Changelog

Every tag has a section here, and the section is the body of the GitHub
release. A tag without one fails the release workflow. Write under
`Unreleased` as work lands; cutting a tag moves it into the tag's section.
Pushing a `v1.MAJOR.MINOR` tag also moves the `v1` tag every consumer pins.

A section says what changed for whoever calls these pipelines, not what was
committed: the commit log already holds that.

## Unreleased

### Added

- `service-release.yml`: a `runs_on` input routes every job of a release to
  one runner label, so a private repository can release from the
  self-hosted Linux runner. Node is set up beside bun, and kubectl and gh
  are fetched at the pinned `kubectl_version` and `gh_version`, verified
  against their published checksums, when the runner has none. setup-go
  restores its module cache on hosted runners only. Defaults keep every
  existing consumer on hosted runners unchanged.
- `service-release.yml`: the release-evidence artifact upload no longer
  fails the smoke job. The evidence reaches the release body through the
  job output either way; the artifact is a copy.

## v1.10.1 - 2026-09-09

### Fixed

- `lateregate.yml`: setup-go restores its module cache on hosted runners
  only. A self-hosted runner keeps its own cache between jobs, and the
  restore over it failed file by file on every step.

## v1.10.0 - 2026-09-08

### Added

- `lateregate.yml`: a `runs_on` input, `ubuntu-latest` by default, routes the
  probe, every gate job and the wiring check. A private repository moves its
  whole pipeline to the self-hosted `linux-vm` runner by passing the label
  here and in `test_os`, and falls back to hosted runners by removing both.

## v1.9.0 - 2026-09-08

### Changed

- `lateregate.yml`, `go-verify.yml`: the default `test_os` is `["ubuntu-latest"]`.
  macOS bills at ten times the Linux rate and was half of the org's Actions
  spend while only four repositories carry darwin code or ship a darwin
  binary. Those repositories pass `test_os` explicitly; every other caller
  loses the macOS job on its next run without a change.
- `cli-release.yml`: new `test_os` input (default `["ubuntu-latest"]`) so a
  CLI that ships a darwin binary can test on macOS at release time instead
  of on every push.

- README: the consumer conventions name the probe contract every service
  carries through `latere.ai/x/pkg/health`: `/livez`, `/readyz`, `/version`,
  `/metrics` where present, and `/healthz` as an alias of `/livez` for one
  release.

## v1.8.0 - 2026-09-06

Every release pipeline publishes the tag's `CHANGELOG.md` section as the
release body and fails without one. Nothing falls back to GitHub's generated
notes any more.

### Added

- `notes-release.yml`: a reusable pipeline for a module or library that
  builds nothing on a tag. It reads the section and publishes the release,
  with `title` and `lateregate_version` inputs. `examples/notes-release.yml`
  is the caller.
- `lateregate_version` input on every release pipeline, pinning the
  `latere-ai/ci-gate` version whose `release-notes` reads the section.

### Changed

- `service-release.yml` and `images-release.yml` build the release body as
  the section, a blank line, then the smoke evidence, from scratch on every
  run. A re-run edits the release to the same body. The "existing body as
  prefix" and `generate-notes` fallback are gone.
- `cli-release.yml` passes `--release-notes notes.md` to goreleaser, so the
  body is the section rather than the commit list; a consumer's
  `changelog:` block in `.goreleaser.yaml` is unused.
- `images-release.yml` gains a `go_version` input, used to run the reader.

### Consumer action

Add `CHANGELOG.md` with a `## Unreleased` heading (in a Go repository,
`go tool lateregate init` writes it) and put a section under it before the
next tag. The first tag after this pipeline moves to `v1` fails its release
job without one.
