# ci

Reusable GitHub Actions pipelines for Latere repositories: the per-push
quality gate, the daily move of the gate's version pin, and the
tag-triggered releases for a Kubernetes service, a command-line tool, and
a library. A repository keeps a short caller workflow; the logic lives here
and reaches every caller through the moving `@v1` tag.

[![test](https://github.com/latere-ai/ci/actions/workflows/test.yml/badge.svg)](https://github.com/latere-ai/ci/actions/workflows/test.yml)
[![actionlint](https://github.com/latere-ai/ci/actions/workflows/actionlint.yml/badge.svg)](https://github.com/latere-ai/ci/actions/workflows/actionlint.yml)

This repository owns orchestration and ordering: which jobs run, on which
runner, in what order, with which credentials. What each quality gate
asserts lives in [`latere-ai/ci-gate`](https://github.com/latere-ai/ci-gate),
the `lateregate` binary a repository pins in its own `go.mod`. What to
build, what to apply, and what "live" means stay in the consuming
repository, by convention rather than through a long list of inputs.

## The pipelines

| Workflow | Runs on | For | Jobs |
| --- | --- | --- | --- |
| [`lateregate.yml`](.github/workflows/lateregate.yml) | every push and pull request | a Go repository | the plan, one job per gate, the test matrix, the wiring check |
| [`ci-gate-bump.yml`](.github/workflows/ci-gate-bump.yml) | once a day | a Go repository that pins `latere.ai/x/ci-gate` | move the pin to the latest release when the bar passes on it, or open an issue |
| [`go-verify.yml`](.github/workflows/go-verify.yml) | every push and pull request | a Go repository that has not moved to `lateregate.yml` | Makefile targets, probed |
| [`service-release.yml`](.github/workflows/service-release.yml) | a `v*` tag | a Kubernetes service | build the image, deploy, smoke the live surface, publish the release |
| [`cli-release.yml`](.github/workflows/cli-release.yml) | a `v*` tag | a command-line tool | lint, test, GoReleaser |
| [`notes-release.yml`](.github/workflows/notes-release.yml) | a `v*` tag | a module or library that builds nothing on a tag | publish the release |

Every release pipeline publishes the GitHub release last, with the tag's
section of `CHANGELOG.md` as its body; a tag without a section fails. See
[A tag is a release](#a-tag-is-a-release-and-a-release-has-notes).

[`examples/`](examples/) holds a starter caller for each.
[`tools/repo-settings.sh`](tools/repo-settings.sh) applies the
organization's repository settings to a new repository.

## Adopting it

For a new Go repository:

1. **The per-push gate.** Pin the gate binary and let it write the caller,
   the hooks, the `.gitignore` lines and the changelog:

   ```sh
   go get -tool latere.ai/x/ci-gate/cmd/lateregate
   go tool lateregate init
   ```

   Then declare the two decisions it cannot make, in `.lateregate.yaml`:

   ```yaml
   identity:
     role: none          # a library or a tool; a service declares its own role
   license:
     spdx: MIT
     holder: Latere AI
   ```

   `go tool lateregate contract` says whether the wiring is in shape, and
   `go tool lateregate` runs the bar locally exactly as CI will.

2. **The daily pin move.** Copy
   [`examples/ci-gate-bump.yml`](examples/ci-gate-bump.yml) to
   `.github/workflows/ci-gate-bump.yml`, give its cron a minute no other
   repository on the same runner uses, and add `workflow_dispatch:` to the
   triggers of the per-push caller; see
   [Moving the gate pin](#moving-the-gate-pin-ci-gate-bumpyml).

3. **A release caller**, chosen by what the repository ships: copy the
   matching file from [`examples/`](examples/) to
   `.github/workflows/release.yml` and adjust its inputs. The sections
   below say what each pipeline needs from the repository.

4. **Repository settings.** Run `tools/repo-settings.sh apply <repo>` once
   when the repository is created; see
   [Repository settings](#repository-settings).

The per-push caller `init` writes is the whole CI configuration for the
gate:

```yaml
name: ci

on:
  push:
    branches: [main]
  pull_request:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}-${{ github.event_name }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  gate:
    uses: latere-ai/ci/.github/workflows/lateregate.yml@v1
```

## The per-push gate: `lateregate.yml`

There are no per-gate inputs and no Makefile contract. The pipeline runs
`go tool lateregate list -json` and builds one job per gate the binary
says applies. Which gates apply is decided by the binary reading the tree
(a repository with no `specs/` is not spec-linted), and the only way a
gate that applies does not run is a dated waiver in the repository's
`.lateregate.yaml`, which the plan reads and the probe log prints.

| Input | Default | Meaning |
| --- | --- | --- |
| `go_version` | `1.27` | the Go toolchain |
| `test_os` | `["ubuntu-latest"]` | the runners `test` runs on, as a JSON array |
| `runs_on` | `ubuntu-latest` | the runner label for every other job |

golangci-lint's version is pinned in the binary, so there is no input for
it. A repository that cannot lint waives `lint` with a reason and a date
rather than turning the job off.

| Job | Runs |
| --- | --- |
| `which gates apply` | `lateregate list -json`; its outputs are the job sets |
| `test on <os>` | `lateregate test` on each runner in `test_os`, except `runs_on` once the plan has `suite` |
| `<gate>` | `lateregate <gate>`: one job per running gate on a hosted runner, and only the suite gates on a self-hosted one; `cover` or `suite` uploads `coverage.out` |
| `static gates and wiring` | self-hosted only: every other running gate, one after another, then `lateregate contract` |
| `wiring is in shape` | hosted only: `lateregate contract` |
| `all gates passed` | always, after every other job: passes when each one succeeded or was skipped, and fails on a failure or a cancellation |

Branch protection requires one check: `all gates passed`. The gate jobs
are named for the gates the plan picks, so the set changes when a pin adds
or drops a gate, and a job that did not apply reports as skipped. This
job is always present under the same name, runs whatever the other jobs
did, and fails unless each of them succeeded or was skipped. GitHub names
a reusable workflow's check after the caller's job id, so a caller whose
job is `gate` requires `gate / all gates passed`.

`suite` runs the test suite once with the race detector, coverage, the
temporary-directory check and the stripped `PATH` all on, in place of the
separate `test`, `race`, `cover`, `tempdir` and `hermetic` gates; with a
`lateregate` that predates it, those run one by one. `suite` runs once, on
`runs_on`. The other systems in `test_os` keep plain `test`, because
`suite` adds the race detector and coverage and a macOS minute bills at
ten times a Linux one.

On a self-hosted runner a job is a turn on one of a few runner slots, and
one job per gate would make the queue out of job setup rather than checks.
There the gates that take seconds share the `static gates and wiring` job,
each in a log group of its own, each run whether another failed, and each
named in an annotation when it fails. A hosted runner keeps one job per
gate, since its parallelism costs nothing.

On a self-hosted label every job builds with `GOFLAGS=-trimpath`. Such a
runner keeps one Go build and test cache for all of its runner processes,
and each process checks out under a work directory of its own; without the
flag the cache keys a package on that directory and no process replays a
result another recorded. For the same reason only the `lint` gate gets the
runner process's own `TMPDIR`, which golangci-lint's machine-wide lock
needs: a cached test result is keyed on the `TMPDIR` the test read. A test
that finds repository files through `runtime.Caller` gets a
module-relative path under `-trimpath`; `go test` runs each package in its
own directory, so a path relative to it works on every runner.

The optional `enum-go` and `enum-typescript` gates run when the repository
declares enum domains in `.lateregate.yaml`. For `enum-typescript` the
workflow sets up Node 24 and Bun 1.3.14 and runs `go tool lateregate
enum-typescript-prepare` before checking, which installs each configured
project's dependencies from its committed npm or Bun lockfile. Go gates
install no JavaScript tooling. Domain configuration is documented in
[ci-gate's gate reference](https://github.com/latere-ai/ci-gate/blob/main/docs/gates.md).

## Moving the gate pin: `ci-gate-bump.yml`

A repository pins `latere.ai/x/ci-gate` by exact version in its `go.mod`
tool directive, so the hooks on a laptop and CI run the same `lateregate`.
The pin moves only in a commit, and this pipeline makes that commit once a
day:

```yaml
# .github/workflows/ci-gate-bump.yml
name: ci-gate bump
on:
  schedule:
    - cron: "17 3 * * *"
  workflow_dispatch:
permissions:
  contents: write
  issues: write
  actions: write
jobs:
  bump:
    uses: latere-ai/ci/.github/workflows/ci-gate-bump.yml@v1
    with:
      runs_on: linux-vm   # only where the per-push gate runs there too
```

The `permissions` block is mandatory: the pipeline pushes the pin, opens
issues, and dispatches the per-push gate, and the organization's token is
read-only by default.

| Job | Runs |
| --- | --- |
| `is the pin current` | asks the module proxy for the newest release above the pin, and closes the issues this pipeline opened for versions the pin has reached. When the pin is current, the run ends here: no gate runs. |
| `bump to vX.Y.Z` | `go get -tool latere.ai/x/ci-gate/cmd/lateregate@vX.Y.Z` and `go mod tidy`, then the whole bar on the result: every gate `go tool lateregate` runs, one after another, and `lateregate contract`. |

When the bar passes, the job commits `go.mod` and `go.sum` as
`gate: ci-gate vX.Y.Z` and pushes to the branch the run is on, which for
the schedule is the default branch. A branch that moved while the bar ran
is rebased onto, up to three attempts; when the new commits touched
`go.mod`, the pin is moved again on top of them. A push made with the
Actions token starts no workflow, so the job then dispatches the per-push
caller, the one workflow that calls `lateregate.yml`, on the new commit.
That is why the per-push caller needs `workflow_dispatch:` among its
triggers: without a run on the commit, `lateregate release` has no CI to
read.

When the bar fails, nothing is pushed. The job opens one issue per version,
titled `ci-gate vX.Y.Z does not pass the gate`, with each failing gate's
output, and updates its body on every later run that still fails; one a
person closed stays closed. The run itself
stays green with a warning that links the issue: `lateregate release`
refuses to cut while the latest run of any workflow on the branch is red,
and a release the repository does not yet pass should not hold back
releases the current pin verifies. Fix the tree, with or without the pin in
the same commit; the next run moves the pin once the bar passes, and the
issue closes when the pin reaches the version. A release that would raise
the repository's `go` or `toolchain` line is reported the same way, since
which Go a repository builds with is decided by hand.

| Input | Default | Meaning |
| --- | --- | --- |
| `go_version` | `1.27` | the Go toolchain; keep it the one the per-push gate runs, since `vuln` judges the standard library of the toolchain that runs it |
| `runs_on` | `ubuntu-latest` | the runner label for both jobs |

The bar runs as the per-push gate's jobs do: no service containers, a test
that needs Docker reaches the runner's daemon, `lint` gets the runner
process's own `TMPDIR`, and on a self-hosted label every gate builds with
`GOFLAGS=-trimpath`. The TypeScript enum gate gets Node and Bun as in
`lateregate.yml`. No credential stays in the checkout while the new release
and the repository's tests run; only the push step hands git the token.

## The previous per-push gate: `go-verify.yml`

`go-verify.yml` probes the repository's `Makefile` with `make -np` and
runs the targets it finds. `fmt-check`, `test` and `lint-modernize` are
required; `test-hermetic`, `test-race`, `cover`, `spec-lint`, `dist`,
`validate`, `lint-config` and `license` run when present. A missing
optional target skips its job, which is the gap `lateregate.yml` closes.
It takes `go_version`, `test_os`, `runs_on`, `golangci_version` (default
`v2.13.1`) and `run_lint` (default `true`). It stays until the last
repository that calls it has moved; see
[`examples/go-verify.yml`](examples/go-verify.yml) for the caller.

## A tag is a release, and a release has notes

Every release pipeline here reads the tag's section from the consuming
repository's `CHANGELOG.md` and publishes it as the release body. No
section fails the release job before anything is created or edited. The
pipelines do not fall back to GitHub's generated notes: those are built
from pull request titles, and a repository that commits to main directly
would get a compare link and nothing else.

A level-two heading whose second word is the tag opens a section that runs
to the next level-two heading, so `## v1.2.3 - 2026-09-06` and `## v1.2.3`
both name `v1.2.3`. `## Unreleased` holds what the next tag will say;
write under it as work lands. The section says what changed for whoever
uses the release, not what was committed.

The reader is `lateregate release-notes` from `latere-ai/ci-gate`, run at
the version each release pipeline pins in its `lateregate_version` input.
Pinning it here rather than reading the consumer's tool pin makes the
reader the same in every repository, including ones that pin no Go tool.
In a Go repository the same binary runs in the pre-push hook and refuses
the tag before it leaves the laptop, and `go tool lateregate release
vX.Y.Z` moves the notes under `Unreleased` into the tag's section,
commits, tags and pushes. A repository without the tool writes the
section by hand and pushes the tag.

In `service-release.yml` the release job is the last one, so when it fails
on a missing section production is already serving the tag. That is the
intended order, a release announces what is live, and the fix is to add
the section and re-run the job rather than re-tag.

## Releasing a service: `service-release.yml`

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    tags: ['v*']
permissions:
  contents: write
  packages: write
  actions: read
jobs:
  release:
    uses: latere-ai/ci/.github/workflows/service-release.yml@v1
    with:
      service: platformd
      image: ghcr.io/latere-ai/platformd
      namespace: latere
      url: https://platform.latere.ai
      title: Latere Platform
      main_package: ./cmd/platformd
      spa_embed_dir: internal/web/spa/dist
    secrets: inherit
```

The `permissions` block is mandatory: a reusable workflow's token cannot
exceed the calling job's, and the organization defaults to read-only, so
without it the run fails at startup, with no logs, when the pipeline
pushes the image or creates the release.

The run is five jobs in order. `build-image` builds and pushes the image;
in `split` mode it first builds the frontend (with a typecheck) and the Go
binary (after `go vet`) on the runner. `deploy` applies `deploy/prod/` and rolls the Deployment to the new
image. `smoke` runs the repository's smoke script against the live URL.
`cli` builds command-line binaries when `build_cli` is set. `release`
publishes the GitHub release with the changelog section and the smoke
evidence. The pipeline does not run the test suite: the per-push gate on
the tagged commit is the verification, and `lateregate release` refuses to
cut a tag while CI is red.

### What the repository provides

| Convention | Purpose |
| --- | --- |
| `CHANGELOG.md` | one level-two section per tag; the section is the release body |
| `deploy/prod/` | rollable manifests. With a `kustomization.yaml` the pipeline runs `kubectl apply -k deploy/prod/`, otherwise `kubectl apply -f deploy/prod/`. Everything here must be safe to re-apply on every release. |
| `deploy/bootstrap/` | one-time or immutable manifests (the namespace, the rollout identity, a storage class). The pipeline never reads this directory. |
| `tools/smoke/release.sh` | the post-deploy smoke (`smoke_script` moves it). It reads `BASE_URL`, `EXPECTED_ASSET`, `OUTPUT_MD` and `SERVICE_TOKEN`, exits non-zero when the live surface is wrong, and writes a Markdown evidence block to `OUTPUT_MD`. |
| probes | the four paths of `latere.ai/x/pkg/health`, served by its handler: `/livez` (liveness; never depends on a dependency), `/readyz` (readiness; the body names the failing check), `/version` (`version`, `commit`, `build_time`), and `/metrics` where the service has any. Manifests probe `/livez` and `/readyz`; the smoke reads all three. |
| `Dockerfile.ci` | in `split` mode, packages the prebuilt binary `out/<service>` into the runtime image; the build job compiles it (and embeds the frontend) first |
| `frontend/` | for a service with a UI: built with `bun run build` into `frontend/dist/` |

The Deployment and its main container are both named `<service>` in
`<namespace>` unless `deployment` and `container` say otherwise, so the
pipeline can `kubectl set image` without reading the manifests.

### Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `service` | required | the Deployment, container and binary name |
| `image` | required | the image path without a tag |
| `namespace` | required | the Kubernetes namespace |
| `url` | required | the public production URL; the smoke's `BASE_URL` |
| `title` | required | the release title prefix: `Lux` gives `Lux v1.2.3` |
| `build_mode` | `split` | `split` or `dockerfile`; see below |
| `has_frontend` | `true` | `split` only: build the frontend and pin the served asset hash |
| `frontend_dir` | `frontend` | the frontend directory |
| `spa_embed_dir` | empty | where the built frontend is copied before the Go build embeds it; empty skips the embed |
| `main_package` | `.` | the Go package built into the service binary |
| `dockerfile` | `Dockerfile.ci` | the Dockerfile that builds the image |
| `deployment`, `container` | `service` | the Deployment, and the container in it, that get the new image |
| `rollout_timeout` | `180s` | `kubectl rollout status` timeout |
| `preflight` | empty | a shell command run after the kubeconfig is written and before the apply |
| `smoke_script` | `tools/smoke/release.sh` | the post-deploy smoke |
| `smoke_scope` | empty | an OAuth scope requested with the smoke token |
| `build_cli`, `cli_build_cmd` | `false`, empty | also build command-line binaries (the command writes them under `dist/`) and attach them to the release |
| `go_version`, `bun_version` | `1.27`, `1.3.14` | toolchains |
| `kubectl_version`, `gh_version` | `1.35.1`, `2.100.0` | fetched, checksum-verified, when the runner has none |
| `lateregate_version` | `v0.29.0` | the `ci-gate` release whose `release-notes` reads the changelog |
| `runs_on` | `ubuntu-latest` | the runner label for all five jobs |

| Secret | Meaning |
| --- | --- |
| `DEPLOY_KUBECONFIG` | the kubeconfig the deploy job applies with; see [Deploy credential](#deploy-credential). Without it the image still builds and publishes, and the deploy job fails naming the secret. |
| `SMOKE_BEARER` | a pre-minted token the smoke presents |
| `SMOKE_CLIENT_ID`, `SMOKE_CLIENT_SECRET` | a client the smoke mints a short-lived `client_credentials` token with, at `https://auth.latere.ai/token`, with the `service` input as the audience |

With neither smoke credential the smoke runs without a token. A repository
whose secret names differ passes them explicitly instead of `inherit`,
mapping them onto these names, and then passes `DEPLOY_KUBECONFIG` by hand
too, since `inherit` cannot be mixed with explicit secrets.

### Build modes

- **`split`** (default): CI builds the frontend and the Go binary, then
  `Dockerfile.ci` copies the prebuilt `out/<service>` into the runtime
  image. The build records the hash of the Vite asset it produced, and the
  smoke checks that the live service serves that exact bundle.
- **`dockerfile`**: one `Dockerfile` builds everything; set `dockerfile:
  Dockerfile`. Less wiring per repository, but the frontend builds inside
  the image, so there is no asset-hash pin: the smoke proves the service
  responds and serves a single-page app, not that this bundle is live.

Prefer `split` for a service with a frontend when the asset pin matters.
Both modes publish the image from one job, so no artifact storage is
needed between jobs; the asset hash reaches the smoke as a job output.

### The "actually live" check

Live means this exact build is serving, not merely that something returns
200. The smoke compares the served asset hash (`EXPECTED_ASSET`) with the
bundle CI just built, and reads `/version` to compare the served
`version` with the tag. The release is published only after that smoke
passes.

### Deploy credential

`secrets: inherit` passes the repository secret `DEPLOY_KUBECONFIG`, the
kubeconfig the deploy job applies the release with. It belongs to the
service's own rollout identity: a ServiceAccount in the service's
namespace, bound to a Role over the kinds `deploy/prod` applies, kept in
the repository at `deploy/bootstrap/rollout-identity.yaml` and applied by
an operator. The job holds no cloud-provider credential, so a leaked
kubeconfig reaches one namespace's workloads rather than the account.

The identity is a ServiceAccount, a Role and RoleBinding in each namespace
`deploy/prod` writes to, and a `kubernetes.io/service-account-token`
Secret bound to the account; `latere-ai/origo`'s
`deploy/bootstrap/rollout-identity.yaml` is the reference. The Role lists
`get, list, create, update, patch` on each kind `deploy/prod` contains and
`watch` on Deployments, which is what `apply`, `set image` and `rollout
status` use: `rollout status` reads the rollout's state from the
Deployment's status and reads no ReplicaSet or Pod. It holds nothing on
Secrets, Namespaces, or RBAC, and no `delete`. A kind that is not
listed fails the apply with Forbidden, which is the intended failure: add the
kind to the Role and re-apply it.

RBAC objects and cluster-scoped objects do not belong in `deploy/prod`. A
subject can write a Role or ClusterRole only with the grants it already
holds, so a pipeline able to write one could give itself anything; they
live in `deploy/bootstrap` beside the identity.

The kubeconfig is built from the token Secret, set on the repository, and
not kept anywhere else:

```bash
kubectl apply -f deploy/bootstrap/rollout-identity.yaml
NS=latere SA=<service>-rollout
kubeconfig=$(mktemp) && chmod 600 "$kubeconfig"
KUBECONFIG="$kubeconfig" kubectl config set-cluster latere-k8s \
  --server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
KUBECONFIG="$kubeconfig" kubectl config set clusters.latere-k8s.certificate-authority-data \
  "$(kubectl -n "$NS" get secret "$SA-token" -o jsonpath='{.data.ca\.crt}')"
KUBECONFIG="$kubeconfig" kubectl config set-credentials "$SA" \
  --token="$(kubectl -n "$NS" get secret "$SA-token" -o jsonpath='{.data.token}' | base64 -d)"
KUBECONFIG="$kubeconfig" kubectl config set-context "$SA" \
  --cluster=latere-k8s --user="$SA" --namespace="$NS"
KUBECONFIG="$kubeconfig" kubectl config use-context "$SA"
KUBECONFIG="$kubeconfig" kubectl apply -k deploy/prod --dry-run=server  # or -f
gh secret set DEPLOY_KUBECONFIG --repo <owner>/<repo> < "$kubeconfig"
rm "$kubeconfig"
```

The server-side dry run authorizes every object the release applies
without changing any, so a Role that misses a kind fails here rather than
in a release. Rotating the credential is deleting the token Secret,
re-applying the identity file, and running the same steps.

## Releasing a command-line tool: `cli-release.yml`

```yaml
jobs:
  release:
    uses: latere-ai/ci/.github/workflows/cli-release.yml@v1
    secrets: inherit
```

`lint`, then `test` on each runner in `test_os`, then `goreleaser`, which
builds the binaries from the repository's own `.goreleaser.yaml` and
publishes the release with the changelog section as its body; a tag
without a section fails before GoReleaser runs. Inputs: `go_version`,
`golangci_version`, `goreleaser_version` (default `v2.17.1`),
`lateregate_version`, `run_lint`, `run_tests`, `test_os` and `runs_on`.
The caller grants `contents: write`.

## Releasing a module or library: `notes-release.yml`

```yaml
name: Release
on:
  push:
    tags: ['v*']
permissions:
  contents: write
jobs:
  release:
    uses: latere-ai/ci/.github/workflows/notes-release.yml@v1
    secrets: inherit
```

Nothing is built. The release body is the changelog section, the title is
the tag (or `title: Name` for `Name vX.Y.Z`), and a hyphen in the version
core marks a prerelease. A re-run edits the body rather than failing on an
existing release.

## Runners

Every pipeline takes `runs_on` (default `ubuntu-latest`), the runner label
for its jobs. A repository moves to the self-hosted runner with one line
on the caller, and back by removing it:

```yaml
jobs:
  release:
    uses: latere-ai/ci/.github/workflows/service-release.yml@v1
    with:
      runs_on: linux-vm
```

The test matrix is the exception. `lateregate.yml`, `go-verify.yml` and
`cli-release.yml` run `test` on the runners `test_os` names, so moving
those means setting both:

```yaml
    with:
      runs_on: linux-vm
      test_os: '["linux-vm"]'
```

- **The self-hosted runners are shared by every repository.** Two
  releases that both ask for `linux-vm` queue behind each other, and a job
  that fans out wider than the runner's slots serializes. A repository
  that releases often, or fans out wide, is better off on hosted runners.
- **The runner must already have what the pipeline expects.** The machine
  ships docker, git, jq and curl. `service-release.yml` fetches kubectl
  and gh at `kubectl_version` and `gh_version`, checksum-verified, when
  they are missing, and sets up Node beside Bun.
- **The secrets still have to reach it.** `runs_on` changes where a job
  runs, not what it can read: the caller keeps `secrets: inherit` (or its
  explicit mapping), and the runner needs network reach to the cluster and
  to the registry.

`actions/setup-go` restores the module cache only on a hosted label,
because a self-hosted runner keeps its own between jobs and restoring a
tarball over it fails on every file that already exists.

## Run artifacts

Everything these pipelines upload to a run expires after 7 days: coverage
profiles, release evidence, command-line binaries, and the
`*.dockerbuild` build record `docker/build-push-action`
uploads beside each image. The figure is fixed, not an input. A
repository's artifact store has a fixed quota and GitHub's default
retention is 90 days, so a busy repository would fill it and fail the
upload step of its next release. What is worth keeping longer is kept
elsewhere: binaries on the GitHub release and smoke evidence in the
release body.

## Tag rules

The image tag is the git tag, byte for byte. `kubectl set image` uses the
tag you pushed, with no normalization in between.

That costs one restriction: **a release tag cannot contain `+`.** Docker
tags are limited to `[a-zA-Z0-9._-]`, so a SemVer build-metadata tag such
as `v1.0.0+exp-sha.5114f85` would push as `v1.0.0-exp-sha.5114f85` while
everything downstream asked for the `+` form. The service pipeline
refuses such a tag in its first job, before anything is built, pushed or
deployed.

Prereleases work normally: `v1.2.3-rc1` publishes as a GitHub prerelease
and is not tagged `latest` in the registry. A hyphen marks a prerelease
only in the SemVer version core.

## Versioning

Callers pin `@v1`, a tag that moves. Pushing a `v1.MINOR.PATCH` tag to
this repository moves `v1` to it (`major-tag.yml`), so a change reaches
callers as part of cutting a version. Landing on main does not move `v1`,
and neither does a prerelease tag such as `v1.2.3-rc1`, which is how a
change is tried on one repository before every repository runs it. A
repository that needs to hold still pins a full version, `@v1.17.0`.

## Supply chain

Every `uses:` in these workflows is pinned to a full commit SHA, with the
version it corresponds to in a trailing comment:

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

These workflows run in your repository with `contents: write`,
`packages: write` and whatever secrets you pass. A `@v2`-style tag is
mutable, so whoever controls the upstream repository could repoint it and
run new code with that access in every caller at once. A SHA cannot be
repointed. For the same reason no step fetches a tool at `latest`: Bun,
GoReleaser, kubectl, gh and the changelog reader are explicit inputs with
pinned defaults, and the TypeScript enum gate pins Bun in
`lateregate.yml`. The one exception is the release `ci-gate-bump.yml`
exists to try, the repository's own gate: it is resolved to an exact
version, verified against the Go checksum database, run with no token in
its environment or in the checkout, and lands only as an exact pin in a
commit.

## Repository settings

Repository settings are per-repository state that no pipeline touches, so
a new repository starts on GitHub's defaults: merge commits and rebase
merges enabled, wiki and projects on, no auto-merge.
`tools/repo-settings.json` holds the organization's settings:

| Setting | Value | Why |
| --- | --- | --- |
| `allow_squash_merge` | `true` | the only merge method: one commit per pull request |
| `allow_merge_commit` | `false` | no merge commits in main's history |
| `allow_rebase_merge` | `false` | a pull request never lands as several commits |
| `allow_auto_merge` | `true` | a pull request can be queued to merge once required checks pass |
| `squash_merge_commit_title` | `PR_TITLE` | the squash commit subject is the pull request title |
| `squash_merge_commit_message` | `PR_BODY` | the body is the pull request description |
| `delete_branch_on_merge` | `true` | head branches are removed once merged |
| `has_wiki` | `false` | documentation lives in the repository |
| `has_projects` | `false` | planning lives in specs and issues |

Apply them when a repository is created, and check them whenever you want
to know:

```bash
tools/repo-settings.sh apply my-new-repo             # one repository, or a list
tools/repo-settings.sh apply lux auth latere-ai/topos
tools/repo-settings.sh check --all                   # exits 1 and names each drifted field
tools/repo-settings.sh apply --all
```

A bare name resolves against the `latere-ai` organization; an
`owner/repo` slug is used as given. `REPO_SETTINGS_ORG` overrides the
organization and `REPO_SETTINGS_POLICY` the policy file. Archived
repositories are read-only on the GitHub API, so they are reported and
skipped. GitHub refuses to disable projects on a repository that still
owns classic projects: that repository is retried without `has_projects`,
reported as `PARTIAL`, and every other setting still lands. Both commands
run on your own `gh` credentials, so no token is stored anywhere.

## Contributing

[`CONTRIBUTING.md`](CONTRIBUTING.md) covers the local checks, how the
workflows are tested, and how a version is cut and reaches callers.
