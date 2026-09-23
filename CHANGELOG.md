# Changelog

Every tag has a section here, and the section is the body of the GitHub
release. A tag without one fails the release workflow. Write under
`Unreleased` as work lands; cutting a tag moves it into the tag's section.
Pushing a `v1.MAJOR.MINOR` tag also moves the `v1` tag every consumer pins.

A section says what changed for whoever calls these pipelines, not what was
committed: the commit log already holds that.

## Unreleased

### Changed

- On a self-hosted runner, `lateregate.yml` runs the gates that take seconds
  in one job, `static gates and wiring`, followed by `lateregate contract`,
  and keeps jobs of their own only for the gates that run the whole test
  suite. A push used to take one job per gate, about eighteen, and on a
  runner with two slots the queue was made of job setup rather than checks.
  Each folded gate still runs whether another failed, gets a log group, and
  is named in an annotation when it fails. Hosted runners keep one job per
  gate.
- With a lateregate that has the `suite` gate, `suite` runs as one gate job
  on `runs_on` in place of `test`, `race`, `cover`, `tempdir` and
  `hermetic`, and uploads `coverage.out`. The `test_os` matrix drops
  `runs_on` and runs plain `test` on the other systems, so a macOS leg does
  not pay for the race detector and coverage. A lateregate without `suite`
  runs as before.

## v1.16.0 - 2026-09-23

### Changed

- `lateregate.yml` builds every job with `GOFLAGS=-trimpath` when the job runs
  on a self-hosted label, and never on a hosted one. A self-hosted runner keeps
  one Go cache for all of its runner processes, and without the flag the cache
  keys a package on the work directory it was built in, which differs between
  processes: a gate that landed on the other process reran every package. A
  test that finds repository files through `runtime.Caller` gets a
  module-relative path under the flag; use a path relative to the package
  directory, where `go test` runs it.
- Only the `lint` gate runs with the runner process's own `TMPDIR`. Every
  other gate keeps the machine's, because a cached test result is keyed on the
  `TMPDIR` the test read and a per-process value split the cache the same way.

## v1.15.0 - 2026-09-23

### Removed

- `service-release.yml` no longer accepts `DO_TOKEN` or installs doctl. The
  deploy job authenticates only with `DEPLOY_KUBECONFIG`, and fails with an
  error naming it when the repository has none. A caller that passes
  `DO_TOKEN` explicitly, rather than through `secrets: inherit`, must drop it:
  an undeclared secret fails the call before any job starts.

## v1.14.0 - 2026-09-23

### Changed

- `service-release.yml` deploys with the repository secret `DEPLOY_KUBECONFIG`,
  the kubeconfig of the service's own rollout identity: a ServiceAccount bound
  to a Role in its namespace over the kinds `deploy/prod` applies. The deploy
  job then holds no DigitalOcean credential, so a leaked secret reaches one
  namespace's workloads rather than the account. The README's "Deploy
  credential" section builds one. `DO_TOKEN` is now optional and deprecated,
  read only when `DEPLOY_KUBECONFIG` is unset.

## v1.13.0 - 2026-09-18

### Changed

- Run artifacts expire after 7 days in every pipeline, the `*.dockerbuild`
  build record `docker/build-push-action` uploads beside each image included.
  GitHub's 90-day default filled one consumer's artifact store with 284
  artifacts, and a full store fails the upload step of the next release.

### Added

- `cli-release.yml`, `images-release.yml` and `notes-release.yml` accept
  `runs_on`, so every reusable pipeline now moves to the family's self-hosted
  runners with one line on the caller. `cli-release.yml` restores the Go module
  cache only on a hosted label; set `test_os` to the same label to move its
  test matrix too.

## v1.12.0 - 2026-09-13

### Fixed

- Release notes read only the checked-out changelog, so a newer consumer
  gate configuration cannot stop a release using the pinned reader.
- Service releases build the frontend, binary and image in one job. Artifact
  storage quota no longer blocks the build, and the live smoke still checks
  the exact frontend asset produced by that build.
- Concurrent service image builds use separate Docker credential directories.
- Concurrent verification jobs isolate temporary files, so their linter locks
  do not collide on a shared runner host.
- CLI release race tests have ten minutes for their subprocess end-to-end suites.
- Coverage checks still fail below their threshold, but an exhausted artifact
  quota no longer fails CI when uploading the report copy.

### Added

- `go-verify.yml` accepts `runs_on` for private runners and restores Go
  caches only on hosted runners. Set `test_os` to the same private label.
- `lateregate.yml`: configured TypeScript enum checks set up Node 24 and
  Bun 1.3.14, prepare dependencies from committed lockfiles, then run the
  shared gate. Both enum gates follow the shared plan and its dated waivers;
  Go gates do not install JavaScript tools or dependencies.

## v1.11.0 - 2026-09-12

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
