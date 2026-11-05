# Changelog

Every tag has a section here, and the section is the body of the GitHub
release. A tag without one fails the release workflow. Write under
`Unreleased` as work lands; cutting a tag moves it into the tag's section.
Pushing a `v1.MAJOR.MINOR` tag also moves the `v1` tag every consumer pins.

A section says what changed for whoever calls these pipelines, not what was
committed: the commit log already holds that.

## Unreleased

### Fixed

- `lateregate.yml` no longer asks for `actions: read`. A reusable workflow
  that asks for a permission its caller does not grant fails at startup with
  no job, so since v1.32.0 every run of a caller that grants only
  `contents: read` failed before it began. The jobs now run with the
  caller's token: a caller that grants `actions: read` gets the plan from
  the last green commit, and one that does not checks the whole tree.

## v1.32.0 - 2026-11-05

### Changed

- `lateregate.yml` measures the plan from the last green commit. The job that
  reads the plan runs `lateregate base -since green` and lists from the
  commit it prints, naming it in the log and the step summary. When the pinned
  `lateregate` has no `base` command, no run was green, or the API refuses,
  the whole tree is checked and the log says why. The workflow now asks for
  `actions: read`; a caller that grants only `contents: read` keeps working and
  checks the whole tree.
- The tools a gate installs come from the plan's `needs`: Node and Bun, and
  Chromium in each `chromium:<dir>`. A hosted gate job installs only what its
  gate needs. A pinned `lateregate` without `needs` gets the previous rule.
- The test systems come from the `test` entry's `os`, else `test_os`.
- The module that pins the tool is found by its `tool` line when
  `gate_module` is empty: the root, else the one tracked `go.mod` that has it;
  several nested ones fail the job and ask for `gate_module`.
- `test_os`, `frontend_browser_package` and `gate_module` are still accepted and
  documented as superseded by `.lateregate.yaml` and auto-detection.

## v1.31.0 - 2026-11-05

### Fixed

- `ci-gate-bump.yml` finds the per-push caller by its `uses:` line. A comment
  or a header example that names `lateregate.yml@v1` is no longer counted as a
  second caller, so a repository that documents the pipeline in a comment no
  longer fails the dispatch of the gate on the pin commit.

### Added

- `image-deploy.yml`, a stage a core calls between `image-build.yml` and
  `image-publish.yml` to deploy its own release. It takes the build's
  `images` (one to three `<ref>@<digest>` lines, or `<name>=<ref>@<digest>`
  where the overlay names the image otherwise) and the `deployments` to wait
  for, sets each image by digest in `deploy/prod`'s `kustomization.yaml` with
  `kustomize edit set image`, runs `kubectl apply -k`, waits for each
  Deployment, runs `after_roll`, removes the kubeconfig, and runs the smoke
  script, which it repeats for `smoke_timeout` seconds so a Deployment on the
  Recreate strategy can come back. The job runs in the `production`
  environment with `url`, refuses once a newer tag exists, and uploads the
  smoke evidence as the artifact `smoke-evidence` for `image-publish.yml`'s
  `evidence: '*-evidence'`. The caller gates the job with its own repository
  variable and maps its secret onto `DEPLOY_KUBECONFIG`
  (`DEPLOY_KUBECONFIG: ${{ secrets.ARCA_KUBECONFIG }}`), and grants
  `contents: read`. `examples/image-release.yml` shows the job and the
  `publish` condition that tolerates a skipped deploy.
- `actions/ensure-kubectl`, `actions/ensure-kustomize` and
  `actions/deploy-by-digest`, the shared steps behind it, and
  `KUBECTL_VERSION` and `KUSTOMIZE_VERSION` in `actions/lib/versions.sh`
  (`kubectl` and `kustomize` outputs).

## v1.30.0 - 2026-11-05

### Added

- `service-release.yml` and `notes-release.yml` refuse a tag whose commit did
  not pass CI. Their first step is the shared `verified-commit` check that
  `image-build.yml` and `cli-release.yml` already run: the tagged commit's
  per-push gate run on its branch push must have succeeded, so a tag on a
  commit whose CI failed, was cancelled or never ran builds, deploys and
  publishes nothing. Both take the same `verify_workflow` (empty: the
  workflow that calls `lateregate.yml`), `wait_minutes` and `skip_paths`
  (`specs/*`, `*.md`) inputs. A `notes-release.yml` caller
  now grants `actions: read` beside `contents: write`; without it the
  release fails at startup.

### Changed

- `wait_minutes`, in every release pipeline that checks CI, defaults to
  waiting 60 minutes on a GitHub-hosted runner and to refusing at once on
  the self-hosted runner, where a waiting release held one of the two
  slots the run it waited for needed. The refusal prints the command that
  re-runs the release once CI is green. A caller that passes a number keeps
  it.
- `verified-commit`, in a run started on a branch rather than a tag (a
  manual rebuild from `main`), reads that branch's own push run of the
  commit. It used to set those runs apart as the tag push's and refuse.

## v1.29.0 - 2026-11-01

### Changed

- `image-build.yml`, in a public repository: the bill of materials'
  attestation calls `actions/attest` directly, since
  `actions/attest-sbom` is deprecated, and neither attestation asks for a
  storage record, which failed on every release with a warning.

### Fixed

- `service-release.yml`: the release preflight no longer refuses a tag on the
  default branch as off it. On a self-hosted runner that reuses its workspace,
  an earlier run can hold the branch's tip as a shallow commit; when the branch
  had moved past the tag, the check read that cut history as a tag off the
  branch. A refusal is now decided on the whole branch.

## v1.28.0 - 2026-11-01

### Added

- `image-build.yml`, `image-publish.yml` and `release-verify.yml`: the
  stages of a signed image release, called with the repository's own jobs
  (conformance, an install walk, a deploy) between them. The build stage
  waits for the tagged commit's verify run, checks the tag, builds up to
  three images by digest under no tag, checks each reports the tag's
  version, signs it, writes its SPDX bill of materials and, in a public
  repository, attests it. The publish stage tags the digests, signs
  `checksums.txt` over the attached files, and publishes the release with
  its files attached before it is visible. The verify stage checks the
  published release from a runner with no checkout. See the README,
  "Releasing signed images", and `examples/image-release.yml`.
- `actions/`: the composite actions the stages are built from
  (`verified-commit`, `release-preflight`, `image-by-digest`, `sign-image`,
  `tag-images`, `signed-checksums`, `publish-release`, `verify-release`,
  `ensure-gh`), callable on their own as `latere-ai/ci/actions/<name>@v1`.
  A stage runs them from ci at its own commit, so a prerelease tag tries
  its own steps. `verified-commit` reads a commit that changes only
  `skip_paths` (the one `lateregate release` cuts, say) through to its
  parent while its own run is still going, so a release does not wait for
  a run over the same code.
- `rollback-guard`, the shared step that refuses a tag once a newer
  `vX.Y.Z` exists.

### Changed

- `service-release.yml` runs the shared steps: `release-preflight` checks
  the tag (no build metadata, on the default branch, a `CHANGELOG.md`
  section) before anything is built, so a tag without notes no longer
  deploys before it fails; `sign-image` signs the image and writes its
  SBOM; `publish-release` publishes the release as a draft until its files
  are attached. The image SBOM asset is now `sbom-<image>.cdx.json`
  (`sbom-platformd.cdx.json`), not `sbom-image.cdx.json`. Still one job,
  and the deploy is unchanged.
- `cli-release.yml` no longer runs lint and the tests again on the tag:
  it checks that the tagged commit passed its per-push gate (the workflow
  that calls `lateregate.yml`, or `verify_workflow`), then tests on the
  extra runners in `test_os` alone. The caller grants `actions: read`
  beside `contents: write`. `run_lint` and `golangci_version` are accepted
  and ignored.
- `notes-release.yml` publishes through `publish-release`.
- The tool versions default to `actions/lib/versions.sh` in every
  pipeline, and each input still overrides: cosign v3.1.4, syft v1.55.0,
  gh 2.103.3, and the note reader at ci-gate v0.61.0 (was v0.29.0; the
  notes it writes are the same).
- `actions/setup-go` restores its cache wherever the runner is hosted, read
  from `runner.environment` rather than from the runner label.
- `lateregate.yml` takes `gate_module`, the directory of the module whose
  `go.mod` pins ci-gate, for a repository that keeps the tool out of its
  consumers' module graph (managed-agents pins it in `internal/gate`).
  Every gate runs from that module with `-C` set to the repository root;
  empty keeps the root.
- Bun moves to 1.4.4 in `lateregate.yml`, `ci-gate-bump.yml` and
  `service-release.yml`; 1.3 cannot read the lockfile version 1.4 writes.
- `lateregate.yml` takes `frontend_browser_package`, the Bun package whose
  tests drive Chromium: Playwright installs the browser before the
  `frontend` gate, on a hosted runner and on the self-hosted one. Empty
  installs nothing.
- `lateregate.yml` and `ci-gate-bump.yml` set up Node 24 and Bun for
  lateregate's `frontend` gate as they do for `enum-typescript`, so a
  repository that names its Bun packages under `frontend.projects` (from
  ci-gate v0.62.0) gets them installed, type-checked, tested and built on
  every push without a job of its own.

### Removed

- `go-verify.yml`, its example and its tests. Its one caller,
  managed-agents, pins it by commit and keeps running that copy. A
  repository still on it moves to `lateregate.yml`; see the README, "The
  per-push gate".

### Fixed

- `image-build.yml`: the version check pulls the candidate quietly before
  it runs it. `docker run` printed its pull progress, "Unable to find
  image … locally", ahead of the binary's output, so every image whose
  version was checked failed the check.
- `image-build.yml`, in a public repository: the attestations push to the
  registry with the job's login. `actions/attest` reads its credentials
  from `$HOME/.docker/config.json` and not from `DOCKER_CONFIG`, where the
  build stage isolates the login, so every public release failed at the
  bill of materials' attestation with "No credentials found for registry".

## v1.27.0 - 2026-10-31

### Fixed

- `service-release.yml` refuses a tag whose commit is not on the
  repository's default branch, before anything is built or pushed. A tag
  pushed from a side branch, or one that went out while its release's
  push to the branch was rejected, used to build and deploy code the
  branch never had. The run now fails naming the tag and the branch;
  delete the tag, land the change on the branch, and tag a commit there.

## v1.26.0 - 2026-10-31

### Added

- `service-release.yml` signs the image it pushes, by digest and before
  the deploy, with keyless cosign: the certificate names the workflow and
  the caller's repository, tag and commit, and is recorded in the public
  Sigstore log. Every release carries two CycloneDX 1.6 SBOMs as assets,
  `sbom-source.cdx.json` (what the checkout's lockfiles pin, development
  packages included) and `sbom-image.cdx.json` (what the image holds). A
  public caller also gets GitHub attestations of the image's provenance
  and SBOM in the registry. New inputs `cosign_version` (`v3.0.6`) and
  `syft_version` (`v1.51.1`) pin the two tools.

### Changed

- Callers of `service-release.yml` must grant `id-token: write` and
  `attestations: write` in their release workflow, beside `contents`,
  `packages` and `actions`. A caller that grants neither fails at startup,
  before the build. The examples show the block.

- On a self-hosted runner, `lateregate.yml` runs in one job, `all gates
  passed`: it reads the plan, runs every gate one after another in plan
  order (`test` too when the plan has no `suite`), then `lateregate
  contract`, uploads `coverage.out` when `cover` or `suite` ran, and fails
  when any of them did. The `which gates apply`, `<gate>` and `static gates
  and wiring` jobs no longer run there, so a push waits for one runner slot
  instead of three in a row. Each gate still runs whether another failed,
  has a log group, an annotation when it fails, and a row in the step
  summary with its result and time. A `test_os` that names a runner other
  than `runs_on` still gets the probe and the test matrix, and `all gates
  passed` starts after them. Hosted runners keep one job per gate. The
  required check keeps its name, `gate / all gates passed`. A cancelled run
  on the self-hosted runner, pull request runs included, cancels the job,
  which reports cancelled.

## v1.25.1 - 2026-10-21

### Fixed

- `service-release.yml` refuses a tag once a newer `vX.Y.Z` tag exists,
  before anything is built or pushed. Since v1.25.0 a re-run repeats the
  build and the deploy, so re-running an older release would have pushed
  it as `latest` and rolled production back to it. Its notes can still be
  published by hand with `gh release create`.
- After the deploy steps `KUBECONFIG` names an empty file rather than
  nothing, so a later `kubectl` cannot fall back to a config in the
  runner's home directory.

## v1.25.0 - 2026-10-21

### Changed

- `service-release.yml` runs as one job instead of five. On a busy
  self-hosted runner each job waits for a slot of its own, so the build,
  deploy, smoke, CLI and publish stages each waited in the queue; a release
  now waits once. The steps and their order are unchanged, and a failed
  step still stops everything after it. Two consequences for callers: the
  whole job runs in the `production` environment, so an approval that
  environment requires now comes before the build rather than before the
  deploy; and re-running a failed release repeats the build. The
  kubeconfig is removed as soon as the deploy steps finish, so the smoke
  script, the CLI build and the note reader never hold it.

## v1.24.0 - 2026-10-18

### Added

- `runner-health.yml` also moves `CI_RUNNER_PRIVATE` to `ubuntu-latest`
  while the self-hosted runner is busy: when a runner is online and a
  queued job that asks for `linux-vm` in a private repository has waited
  more than 20 minutes (`BUSY_AFTER_MINUTES`). It moves back once no such
  job has waited more than 5 minutes (`CLEAR_BELOW_MINUTES`), and keeps
  its value in between. The offline rule is unchanged and wins over the
  busy one. `RUNNER_HEALTH_TOKEN` now also needs "Actions: read" on every
  repository.
- Every move of `CI_RUNNER_PRIVATE` is a line in the organization variable
  `CI_RUNNER_SWITCHES`, with the rule, the oldest wait and how long the
  previous label held, so the hosted minutes the fallback spends can be
  read back.

## v1.23.0 - 2026-10-18

### Added

- `cli-release.yml` takes an optional `RELEASE_SIGNING_KEY` secret and sets
  it in GoReleaser's environment, for a repository whose `.goreleaser.yaml`
  signs its release. `secrets: inherit` passes a repository secret of that
  name. Only the GoReleaser step sees it, and a repository without the
  secret builds and publishes as before.

## v1.22.0 - 2026-10-18

### Changed

- Every pipeline's `runs_on` defaults to the organization's runner policy
  instead of `ubuntu-latest`: a private repository runs on the self-hosted
  runner and falls back to `ubuntu-latest` while that runner is offline; a
  public repository runs on `ubuntu-latest` and falls back to the
  self-hosted runner, for a push, a tag, a schedule, a dispatch or a
  release only, while hosted runners are down. The organization variables
  `CI_RUNNER_PRIVATE` and `CI_RUNNER_PUBLIC` hold the two labels; see the
  README's Runners section. A caller that passes `runs_on: linux-vm`
  keeps that label and gives up the fallback, so private repositories
  drop the line.
- `test_os` in `lateregate.yml`, `go-verify.yml` and `cli-release.yml`
  defaults to the runner `runs_on` resolves to, so a caller no longer
  passes `test_os: '["linux-vm"]'` beside `runs_on`.

### Added

- `runner-health.yml` runs every ten minutes in this repository, looks for
  an online `linux-vm` runner, and moves `CI_RUNNER_PRIVATE` to
  `ubuntu-latest` when none is online for a minute and back when one is.
  It needs the `RUNNER_HEALTH_TOKEN` secret described in the README; until
  it is set, the run warns and the variable is moved by hand.

### Fixed

- `notes-release.yml` fetches the GitHub CLI at `gh_version` (default
  `2.100.0`), checksum-verified, when the runner has none, as
  `service-release.yml` does. On the self-hosted runner the publish step
  failed with no `gh`, which pushed private repositories' releases onto
  hosted runners.

## v1.21.0 - 2026-10-13

### Added

- `service-release.yml` takes `after_roll`, a shell command the deploy job
  runs once the Deployment has rolled, with the same kubeconfig and before
  the smoke. A repository whose release also owns a second tree, whose
  workloads call the new release and so must start after it, applies that
  tree there and waits for it. A failing command fails the deploy job, so
  neither the smoke nor the release runs. It defaults to empty, which skips
  the step, so no caller changes until it sets one.

### Changed

- `lateregate.yml`'s `all gates passed` job is skipped in a cancelled push
  run. Every run a newer push supersedes, and every duplicate run GitHub
  starts for one push, still queued it on the caller's runner, so on the
  two-slot self-hosted runner each cancellation held a slot for about half
  a minute to report what the run's conclusion already says. Pull request
  runs, which branch protection reads, keep running it after a
  cancellation and fail.

## v1.20.0 - 2026-09-27

### Fixed

- Every `setup-bun` step installs bun into the job's own temp directory.
  Runner slots on one machine share a home directory, and a job running bun
  while another slot extracted it failed with `spawn ETXTBSY`, which failed
  a release's image build at random.

### Removed

- `images-release.yml`. No repository calls it: `latere-ai/sandbox-images`
  releases through its own workflow, and the hosted Cella plane pins its
  images in platformd's catalog rather than reading the `catalog.json` this
  pipeline published.

## v1.19.0 - 2026-09-26

### Added

- `lateregate.yml` ends with an `all gates passed` job that runs after every
  other job and fails unless each one succeeded or was skipped. Branch
  protection can require that single check, `gate / all gates passed` for
  a caller whose job id is `gate`, in place of the per-gate jobs, whose
  names change as the plan adds or drops gates.

## v1.18.1 - 2026-09-25

### Fixed

- The issue `ci-gate-bump.yml` opens lists `go tool lateregate contract`
  among the commands that reproduce the failure. The bump runs the wiring
  check after the bar, and a failure there, such as a per-push caller
  without the top-level `concurrency` block newer releases require, did not
  reproduce with `go tool lateregate` alone.

## v1.18.0 - 2026-09-25

### Added

- `ci-gate-bump.yml` moves a Go repository's `latere.ai/x/ci-gate` pin to
  the latest release once a day. It runs the whole bar and the wiring check
  on the new version. When they pass, it pushes `gate: ci-gate vX.Y.Z` to
  the branch and dispatches the per-push caller on that commit. When they
  fail, it pushes nothing and opens one issue for the version, with each
  failing gate's output, which later runs update and a moved pin closes. A
  current pin costs one short job and no gate run. Copy
  `examples/ci-gate-bump.yml` and add `workflow_dispatch:` to the per-push
  caller's triggers.

## v1.17.1 - 2026-09-24

### Changed

- The README is organized around what a calling repository adds, with an
  input and secret table for `service-release.yml` and the jobs and
  conventions of every pipeline. How to cut a version and try a change on
  one repository first moved to `CONTRIBUTING.md`. No pipeline changed.

### Fixed

- `cli-release.yml` publishes again. It wrote the release note to
  `notes.md` inside the checkout, and goreleaser refuses to publish from a
  tree with an untracked file, so every CLI release failed after its tests
  passed. The note is now written under the runner's temp directory.

## v1.17.0 - 2026-09-23

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
