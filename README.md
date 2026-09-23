# latere-ai/ci

Central, reusable CI pipelines for latere.ai projects. One source of truth, no
per-repo forks. Consumer repos keep a thin caller workflow; all the logic lives
here and is versioned with a moving `@v1` tag.

Two kinds of pipeline: **release**, triggered by a version tag, and
**per-push verify** (`lateregate.yml`), triggered by every push.

A version tag (`v*`) push in a consumer repo triggers a release: build the
artifact, deploy to the `latere-k8s` cluster, smoke the live surface to prove
the exact build is serving, and only then publish the GitHub release whose
body is the tag's section in `CHANGELOG.md` plus a smoke-evidence block. A
tag without a section fails; see "A tag is a release, and a release has
notes" below.

## What's here

- `.github/workflows/lateregate.yml` — reusable **per-push** pipeline for a
  Go repo: asks `lateregate` which gates apply and runs one job per gate,
  plus `test` on an OS matrix. Runs on every push and pull request, not on
  a tag.
- `.github/workflows/go-verify.yml` — the previous per-push pipeline, which
  probes a Makefile for targets. Kept until every consumer has moved.
- `.github/workflows/service-release.yml` — reusable (`workflow_call`) pipeline
  for a k8s **service**: verify to build to deploy to smoke to release, all in
  one tag-triggered run.
- `.github/workflows/cli-release.yml` — reusable pipeline for a **CLI tool**
  (goreleaser binaries, no k8s deploy).
- `.github/workflows/images-release.yml` — reusable pipeline for a
  **container-images repo** (an image catalog, no deploy): verify to build+push
  (dependency-ordered) to publish-catalog (S3) to smoke against the published
  images to release with evidence.
- `.github/workflows/notes-release.yml` — reusable pipeline for a **module or
  library** that builds nothing on a tag: read the changelog section, publish
  the release.
- `tools/repo-settings.sh` — applies the org-wide repository settings policy
  (`tools/repo-settings.json`) so a new repo does not sit on GitHub's defaults.
  Run it when you create a repo.
- `examples/` — starter callers so a new repo gets the boilerplate.

## Design principle

The reusable workflow owns **orchestration and ordering**. Each consumer repo
owns **what to build, what to apply, and what "live" means** through standard
directories and a standard script. Variability lives in the repo by convention,
not in a sprawl of workflow inputs.

## Consumer conventions (the contract)

Every repo that releases through a pipeline here must provide:

| Convention | Purpose |
| --- | --- |
| `CHANGELOG.md` | One level-two section per tag, and the section is the release body. See "A tag is a release, and a release has notes". |

A service repo must provide:

| Convention | Purpose |
| --- | --- |
| `deploy/prod/` | Rollable k8s manifests. If `deploy/prod/` contains a `kustomization.yaml` (a kustomize overlay), the pipeline runs `kubectl apply -k deploy/prod/`; otherwise `kubectl apply -f deploy/prod/`. Everything here must be safe to re-apply. |
| `deploy/bootstrap/` | Bootstrap-only / immutable / alternate manifests (storageclass, alternate layouts, separate-cadence dashboards). The pipeline **ignores** this directory. |
| `tools/smoke/release.sh` | Post-deploy live smoke. Honors env `BASE_URL`, `EXPECTED_ASSET`, `OUTPUT_MD`, `SERVICE_TOKEN`. Exits non-zero if the live surface is wrong. Writes a markdown evidence block to `OUTPUT_MD`. |
| Probes | The four paths of `latere.ai/x/pkg/health`, served by its handler: `/livez` (liveness, restart on failure, never depends on a dependency), `/readyz` (readiness, out of rotation on failure, body names the failing check), `/version` (build identity: `version`, `commit`, `build_time`), and `/metrics` where the service has any. Manifests probe `/livez` and `/readyz`; the smoke reads `/livez`, `/readyz`, and `/version`. `/healthz` answers as `/livez` through the package's `LegacyHealthz` option for one release while a manifest moves, and is removed in the release after. |
| `Dockerfile.ci` | Packages the prebuilt binary `out/<service>` into a runtime image. The build job compiles the binary (and embeds the SPA); this Dockerfile only copies it in. |
| frontend at `frontend/` | (services with a UI) Built with `bun run build`, output `frontend/dist/`. The pipeline pins the served Vite asset hash to this build. |

The deployment and its main container are both named `<service>` in the
`<namespace>` namespace, so the pipeline can `kubectl set image` blindly.

An images repo (consumer of `images-release.yml`) must provide:

| Convention | Purpose |
| --- | --- |
| `catalog.yaml` | Image inventory, the single source of truth: name, context dir, platforms, `from` (in-repo base), labels, consumer resource hints. |
| `catalog.sh` | `lint \| matrix \| compose` subcommands, all driven by `catalog.yaml`: schema lint, per-stage build matrices (stage N = FROM-depth N, up to three stages; lint caps chains at depth 2), and the digest-pinned `catalog.json` consumers read from object storage. |
| `catalog_test.sh` | Tests for the catalog tooling; the verify job runs them on every release. |
| `test.sh <tag>` | Runtime assertions run against the **published** images at that tag (honors `RUNTIME` for the container runtime). Exits non-zero on any failed check; its output becomes the release-evidence smoke block. |

The pipeline needs the `CATALOG_S3_*` secrets (endpoint, region, bucket,
prefix, scoped access key + secret) to publish `catalog.json`; the key should
carry a per-bucket grant only, since it lives in a public repo's Actions.

## Using it (Go)

Two per-push pipelines exist. `lateregate.yml` is the current one;
`go-verify.yml` is kept for the consumers that have not moved yet and is
deleted when the last one has.

### `lateregate.yml`

Copy `examples/lateregate.yml` to `.github/workflows/ci.yml`, or let the
binary write it with `go tool lateregate init`. That is the whole caller:

```yaml
jobs:
  gate:
    uses: latere-ai/ci/.github/workflows/lateregate.yml@v1
```

There are no per-gate inputs and no Makefile contract. The pipeline runs
`go tool lateregate list -json` and builds one job per gate the binary says
applies to the repository. Which gates apply is decided by the binary
asking the tree (a repository with no `specs/` is not spec-linted), and the
only way a gate that applies does not run is a dated waiver in the
repository's `.lateregate.yaml`, which the plan reads and the probe log
prints.

| Job | Runs |
| --- | --- |
| `probe` | `lateregate list -json`; its outputs are the job sets |
| `test on <os>` | `lateregate test` on each runner in `test_os`, except `runs_on` once the plan has `suite` |
| `<gate>` | `lateregate <gate>`, one job per running gate on a hosted runner, and only the suite gates on a self-hosted one; `cover` or `suite` uploads `coverage.out` |
| `static gates and wiring` | self-hosted only: every other running gate, one after another, then `lateregate contract` |
| `wiring is in shape` | hosted only: `lateregate contract`, the caller, hook, gitignore and pin are the shared ones |

The suite gates are the ones that each run the whole test suite: `suite`,
which a lateregate with it runs in place of `test`, `race`, `cover`,
`tempdir` and `hermetic`, or those four one by one in a lateregate that
predates it. `suite` runs once, on `runs_on`: the other systems in
`test_os` keep plain `test`, because `suite` adds the race detector and
coverage to the run and a macOS minute bills at ten times a Linux one.

On a self-hosted runner a job is a turn on one of a few runner slots, and one
job per gate made the queue out of job setup rather than checks. So there the
gates that take seconds share the `static gates and wiring` job, each in a
log group of its own, each run whether another failed, and each named in an
annotation when it fails. A hosted runner keeps one job per gate, since its
parallelism costs nothing.

`go tool lateregate` on a laptop runs the same set. That split is the
point: a gate that only runs in CI tells you too late.

The optional `enum-go` and `enum-typescript` gates run when the repository
declares enum domains in `.lateregate.yaml`. For `enum-typescript`, the
workflow sets up Node 24 and Bun 1.3.14, then runs
`go tool lateregate enum-typescript-prepare` before checking. Preparation
installs each configured project's dependencies from its committed npm or
Bun lockfile, using `npm ci` or `bun install --frozen-lockfile`. Run the same
preparation command locally after lockfile changes. Go gates do not install
JavaScript tools or dependencies. Domain configuration and parser exceptions
are documented in [ci-gate](https://github.com/latere-ai/ci-gate#readme).

Inputs are `go_version`, `test_os` and `runs_on`. `runs_on` moves every job
but the test matrix to one runner label, which is how a private repository
adopts the self-hosted Linux runner and how it falls back. golangci-lint's
version is pinned in the binary, so there is no input for it, and a
repository that cannot lint waives `lint` with a reason and a date rather
than turning the job off.

On a self-hosted label every job builds with `GOFLAGS=-trimpath`. Such a
runner keeps one Go build and test cache for all of its runner processes, and
each process checks out under a work directory of its own; without the flag
the cache keys a package on that directory and no process replays a result
another recorded. For the same reason only the `lint` gate gets the runner
process's own `TMPDIR`, which golangci-lint's machine-wide lock needs: a
cached test result is keyed on the `TMPDIR` the test read. A test that finds
repository files through `runtime.Caller` gets a module-relative path under
`-trimpath`; `go test` runs each package in its own directory, so a path
relative to it works on every runner.

### `go-verify.yml`

The previous pipeline. It probes the consumer's `Makefile` with `make -np`
and runs the targets it finds: `fmt-check`, `test` and `lint-modernize`
are required, and `test-hermetic`, `test-race`, `cover`, `spec-lint`,
`dist`, `validate`, `lint-config` and `license` run when present. A missing
optional target skips its job, which is the gap `lateregate.yml` closes.
See `examples/go-verify.yml` for the caller.

Set `runs_on: linux-vm` and `test_os: '["linux-vm"]'` for a private
repository using the org runner. The default remains hosted Linux.

### The checks live in `ci-gate`, not here

This repo owns **orchestration and ordering**. What each gate asserts lives
in [`latere-ai/ci-gate`](https://github.com/latere-ai/ci-gate), pinned by
the consumer's `go.mod`:

```sh
go get -tool latere.ai/x/ci-gate/cmd/lateregate
go tool lateregate
```

`.golangci.yml` is generated rather than hand-written in each repo, because
golangci-lint cannot inherit a shared config: its v2 schema rejects an
`extends` key. `lateregate lint` renders it from the module path and the
repository's `.lateregate.yaml` before every run, and it is gitignored, so
divergence is impossible rather than merely detectable.

## Build modes

`service-release.yml` supports two build shapes via the `build_mode` input:

- **`split`** (default) — CI builds the frontend and the Go binary, then
  `Dockerfile.ci` packages the prebuilt `out/<service>` binary into the runtime
  image. The served Vite asset hash is pinned to the build (strong "actually
  live" check). Used by lux, sandbox, lectio.
- **`dockerfile`** — a single `Dockerfile` builds everything. The caller sets
  `dockerfile: Dockerfile`. Less per-repo wiring, but the frontend builds inside
  the image, so there is **no asset-hash pin**: the smoke proves the service
  responds and serves an SPA, not that this exact bundle is live. Used by auth,
  latere-ai, fs (fs has no frontend, so it loses nothing).

For a frontend service, prefer `split` when you want the asset-pin guarantee;
`dockerfile` is the deliberate, lower-fidelity option for repos that already
build everything in one Dockerfile.

Both build modes publish the image from one job. Split mode keeps its
frontend and binary in that job's workspace, so it needs no artifact storage
to pass build products between jobs. The frontend asset hash reaches the
live smoke as a job output.

## A tag is a release, and a release has notes

Every release pipeline here reads the tag's section from the consumer's
`CHANGELOG.md` and publishes it as the release body. No section fails the
release job before anything is created or edited. The pipelines do not fall
back to GitHub's generated notes: those are built from pull request titles,
and a repo that commits to main directly gets a compare link and nothing
else.

The file's shape: a level-two heading whose second word is the tag opens a
section that runs to the next level-two heading, so `## v1.2.3 - 2026-09-06`
and `## v1.2.3` both name `v1.2.3`. `## Unreleased` holds what the next tag
will say; write under it as work lands. The section says what changed for
whoever uses the release, not what was committed.

The reader is `lateregate release-notes`, from
[`latere-ai/ci-gate`](https://github.com/latere-ai/ci-gate), run at the
version each pipeline pins in its `lateregate_version` input. Pinning it
here rather than reading the consumer's tool pin means the reader is the
same in every repo, including ones that pin no Go tool at all. In a Go repo
the same binary runs in the pre-push hook and refuses the tag before it
leaves the laptop, and `go tool lateregate release vX.Y.Z` moves the notes
under `Unreleased` into the tag's section, commits, tags and pushes. A repo
without the tool writes the section by hand and pushes the tag.

In `service-release.yml` the release job is the last one, so when it fails
on a missing section production is already serving the tag. That is the
intended order, a release announces what is live, and the fix is to add the
section and re-run the job rather than re-tag.

## Using it (module or library)

```yaml
# consumer-repo/.github/workflows/release.yml
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

The single job takes `runs_on` like every other pipeline here; see
"Runners".

## The "actually live" check

"Live" means *this exact build is serving*, not merely that something returns
200. The smoke script pins the served Vite asset hash (`EXPECTED_ASSET`,
threaded from the frontend build evidence) to the bundle CI just built, and
reads `/version` to compare the served `version` with the tag. Release notes
publish only after that smoke passes. That ordering is the spine of the
pipeline.

## Using it (service)

```yaml
# consumer-repo/.github/workflows/release.yml
name: Release
on:
  push:
    tags: ['v*']
# Required: the pipeline pushes the image and creates the release. A reusable
# workflow cannot exceed the caller's token permissions, and the org defaults
# to read-only, so the calling job must grant write here.
permissions:
  contents: write
  packages: write
  actions: read
jobs:
  release:
    uses: latere-ai/ci/.github/workflows/service-release.yml@v1
    with:
      service: luxd
      image: ghcr.io/latere-ai/luxd
      namespace: latere
      url: https://lux.latere.ai
      title: Lux
      has_frontend: true
      spa_embed_dir: internal/web/spa/dist
      main_package: ./cmd/luxd
    secrets: inherit
```

The `permissions` block is mandatory: a reusable workflow's token cannot exceed
the calling job's, and this org defaults to read-only, so omitting it makes the
run fail at startup (no logs) when the pipeline tries to push the image or
create the release.

`runs_on` moves all five jobs of the release to one runner label; see
"Runners" for what that costs and requires. The self-hosted machine ships
docker, git, jq and curl and nothing else, so this pipeline sets up Node beside
bun and fetches kubectl and gh at `kubectl_version` and `gh_version`,
checksum-verified, when the runner has none; hosted runners ship all three and
skip the fetch.

`secrets: inherit` passes the repository secret `DEPLOY_KUBECONFIG`, the
kubeconfig the deploy job applies the release with. It belongs to the service's
own rollout identity: a ServiceAccount in the service's namespace, bound to a
Role over the kinds `deploy/prod` applies, kept in the consumer at
`deploy/bootstrap/rollout-identity.yaml` and applied by an operator. The job
holds no DigitalOcean credential, so a leaked kubeconfig reaches one namespace's
workloads rather than the account. See "Deploy credential" below for building
one.

Service-specific smoke credentials are declared optional on the reusable
workflow. A repo whose secret names differ (e.g. Cella's `CELLA_SMOKE_CLIENT_*`)
passes them explicitly instead of `inherit`, mapping them onto
`SMOKE_CLIENT_ID`/`SMOKE_CLIENT_SECRET` (and then also passing
`DEPLOY_KUBECONFIG: ${{ secrets.DEPLOY_KUBECONFIG }}` by hand, since you cannot
mix `inherit` with explicit secrets).

A repository without `DEPLOY_KUBECONFIG` still builds and publishes its image;
its deploy job fails with an error naming the secret.

### Deploy credential

The identity is a ServiceAccount, a Role and RoleBinding in each namespace
`deploy/prod` writes to, and a `kubernetes.io/service-account-token` Secret
bound to the account; `latere-ai/origo`'s
`deploy/bootstrap/rollout-identity.yaml` is the reference. The Role lists
`get, list, create, update, patch` on each kind `deploy/prod` contains,
`watch` on Deployments and `get, list, watch` on ReplicaSets for
`rollout status`, and `get, list` on pods and `get` on `pods/log`. It holds
nothing on Secrets, Namespaces, or RBAC, and no `delete`. A kind that is not
listed fails the apply with Forbidden, which is the intended failure: add the
kind to the Role and re-apply it.

RBAC objects and cluster-scoped objects do not belong in `deploy/prod`. A
subject can write a Role or ClusterRole only with the grants it already holds,
so a pipeline able to write one could give itself anything; they live in
`deploy/bootstrap` beside the identity.

The kubeconfig is built from the token Secret, set on the repository, and not
kept anywhere else:

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

The server-side dry run authorizes every object the release applies without
changing any, so a Role that misses a kind fails here rather than in a release.
Rotating the credential is deleting the token Secret, re-applying the identity
file, and running the same steps.

## Using it (images)

```yaml
# consumer-repo/.github/workflows/release.yml
name: Release
on:
  push:
    tags: ['v*']
permissions:
  contents: write
  packages: write
jobs:
  release:
    uses: latere-ai/ci/.github/workflows/images-release.yml@v1
    with:
      title: Sandbox Images
    secrets: inherit
```

All seven jobs take `runs_on`; a self-hosted runner needs docker and the
`aws` CLI for the catalog upload. See "Runners".

The images analog of the "actually live" check: the smoke pulls the images
that were **actually pushed** at the release tag and runs the repo's `test.sh`
against them, and the digest table in the evidence comes from the same
`catalog.json` that was published to object storage. The GitHub release exists
only if all of that held.

## Runners

Every reusable workflow here takes `runs_on` (string, default `ubuntu-latest`):
the runner label for its jobs. A repository moves off hosted minutes with one
line on the caller, and back by removing it.

```yaml
jobs:
  release:
    uses: latere-ai/ci/.github/workflows/service-release.yml@v1
    with:
      runs_on: linux-vm
```

The OS test matrix is the exception. `lateregate.yml`, `go-verify.yml` and
`cli-release.yml` run `test` on the runners `test_os` names, so moving those
means setting both:

```yaml
    with:
      runs_on: linux-vm
      test_os: '["linux-vm"]'
```

**The two runners are shared by the whole family.** They are not per-repository.
Two releases that both ask for `linux-vm` queue behind each other, and a job
that fans out wider than two runners serializes. A repository that releases
often, or fans out wide, is better off on hosted runners.

**The runner must already have what the pipeline expects to find.** The VM
ships docker, git, jq and curl. `service-release.yml` fetches kubectl and gh at
`kubectl_version` and `gh_version`, checksum-verified, when they are missing,
and sets up Node beside bun. `images-release.yml` needs docker and the `aws`
CLI for the catalog upload, and fetches neither. Install what is missing before
you move the pipeline, not after a release fails half way through.

**The deploy secrets still have to reach it.** `runs_on` changes where a job
runs, not what it can read: the caller keeps `secrets: inherit` (or its explicit
mapping) for `DEPLOY_KUBECONFIG` and the smoke credentials, and the runner needs
network reach to the `latere-k8s` cluster and to GHCR.

Go caches follow the label on their own. `actions/setup-go` restores the module
cache only on a hosted label, because a self-hosted runner keeps its own between
jobs and restoring a tarball over it fails on every file that already exists.

## Run artifacts

Everything these pipelines upload to a run expires after **7 days**: coverage
profiles, image digests, `catalog.json`, release evidence, CLI binaries, and
the `*.dockerbuild` build record `docker/build-push-action` uploads beside each
image. That covers a re-run and a download while the release still matters.

The figure is fixed, not an input. An artifact store is a fixed per-repository
quota and GitHub's default retention is 90 days, so a busy repo fills it and
then fails the upload step of whatever release runs next; lectio's store hit its
quota holding 284 artifacts. What is worth keeping longer than a week is already
kept somewhere durable: CLI binaries are attached to the GitHub release, smoke
evidence is in the release body, and `catalog.json` is in object storage under
both a current and an immutable history key.

## Tag rules

The image tag is the git tag, byte for byte. `kubectl set image`, the stage
1/2 `BASE_IMAGE` build-arg, and `catalog.json`'s refs all reference the tag you
pushed, with no v-stripping or normalization in between.

That costs one restriction: **a release tag cannot contain `+`.** Docker tags
are limited to `[a-zA-Z0-9._-]`, so a SemVer build-metadata tag (§10) such as
`v1.0.0+exp-sha.5114f85` would push as `v1.0.0-exp-sha.5114f85` while
everything downstream still asked for the `+` form. Both pipelines refuse such a
tag in their first job, before anything is built, pushed, or deployed.

Prereleases work normally: `v1.2.3-rc1` publishes as a GitHub prerelease and is
denied the docker `latest` tag. The hyphen is read in the SemVer version core
(§9) only.

## Versioning

Consumers pin `@v1` (a moving major tag). A bad central push would break every
release at once, so this repo runs `actionlint` on every change and is canaried
on a single pilot consumer before the `v1` tag moves. Repos that need to freeze
can pin a patch tag (e.g. `@v1.2.0`).

Pushing a `v1.MAJOR.MINOR.PATCH` tag moves `v1` to it automatically
(`.github/workflows/major-tag.yml`), so a change reaches consumers as part of
cutting a version rather than as a separate step that can be forgotten. Landing
on main deliberately does *not* move `v1`: main stays un-canaried, and these
workflows run in consumer repos with `contents: write`, `packages: write` and
inherited secrets. Prerelease tags (`v1.2.3-rc1`) do not move `v1` either, so a
release candidate can be canaried on a pilot consumer by pinning it explicitly.

## Supply chain

Every `uses:` in these workflows is pinned to a full commit SHA, with the
version it corresponds to in a trailing comment:

```yaml
- uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6.1.0
```

These workflows run on *your* runners with `contents: write`, `packages: write`
and whatever secrets you inherit. A `@v2`-style tag is mutable, so whoever
controls the upstream repository can repoint it and have new code execute with
that access in every consumer at once. A SHA cannot be repointed.

For the same reason no step fetches a tool build at `latest`. Release
workflows expose Bun and GoReleaser versions as explicit inputs
(`bun_version`, `goreleaser_version`) that you can override per repo. The
TypeScript enum gate pins Bun directly in `lateregate.yml`.

Dependabot opens a weekly PR per action so the pins do not rot: first-party
`actions/*` and `docker/*` updates are grouped, third-party actions land
individually so each gets its own review.

## Repository settings policy

Repository settings are per-repo state that no release pipeline touches, so a
new repo arrives on GitHub's defaults: merge commits and rebase merges enabled,
wiki and projects on, no auto-merge. That breaks the org's linear, one commit
per pull request history before anyone notices.

`tools/repo-settings.json` holds the desired state, and every repo in the org is
driven to it:

| Setting | Value | Why |
| --- | --- | --- |
| `allow_squash_merge` | `true` | The only merge method. One commit per pull request. |
| `allow_merge_commit` | `false` | No merge bubbles in main's history. |
| `allow_rebase_merge` | `false` | Keeps a pull request from landing as N separate commits. |
| `allow_auto_merge` | `true` | A pull request can be queued to merge as soon as required checks pass. |
| `squash_merge_commit_title` | `PR_TITLE` | The squash commit subject is the pull request title, not the first commit's. |
| `squash_merge_commit_message` | `PR_BODY` | The body is the pull request description, not a list of squashed commit messages. |
| `delete_branch_on_merge` | `true` | Head branches are removed once merged. |
| `has_wiki` | `false` | Documentation lives in the repo. |
| `has_projects` | `false` | Planning lives in specs and issues. |

Set a new repo, or a list of them:

```bash
tools/repo-settings.sh apply my-new-repo
tools/repo-settings.sh apply lux auth latere-ai/topos
```

Audit, or re-flatten the whole org:

```bash
tools/repo-settings.sh check --all   # exits 1 and names each drifted field
tools/repo-settings.sh apply --all
```

A bare argument resolves against the `latere-ai` org; an `owner/repo` slug is
used as given. Override the org with `REPO_SETTINGS_ORG`, the policy file with
`REPO_SETTINGS_POLICY`. Archived repos are read-only on the GitHub API, so they
are reported and skipped rather than failed. GitHub also refuses to disable
projects on a repo that still owns classic projects: that repo is retried
without `has_projects`, reported as `PARTIAL`, and every other setting still
lands. Nothing is deleted to force the write through.

**There is no nightly audit.** There was one, and it never ran: it needed a
PAT in `REPO_ADMIN_TOKEN` that was never set, so it failed every night from the
day it was written and reported nothing about drift. A scheduled workflow
failing produces no pull request status and no notification, so six nights of
red went unseen.

The audit was also the wrong shape for the problem. Settings do not drift on
their own — they are wrong from the moment a repo is created, because GitHub's
defaults are wrong. Detecting that the morning after is worse than setting it
at creation:

```bash
tools/repo-settings.sh apply my-new-repo   # do this when the repo is created
tools/repo-settings.sh check --all         # and by hand whenever you want to know
```

Both run on your own `gh` credentials, so neither needs a stored token.

## Local checks

Reusable workflows, `secrets: inherit`, and environments only exercise on
GitHub runners; you cannot run this pipeline locally. The local loop is:

```bash
bash test/run.sh   # regression suite; also runs on every push and PR
actionlint         # static workflow lint; CI runs it here
```

The suite unit-tests copies of the inline workflow shell and greps the workflows
so those copies cannot silently drift. Beyond that, canary a tag on a pilot repo
before moving `v1`.
