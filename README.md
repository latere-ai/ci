# latere-ai/ci

Central, reusable release pipeline for latere.ai projects. One source of truth,
no per-repo forks. Consumer repos keep a thin caller workflow; all the logic
lives here and is versioned with a moving `@v1` tag.

A version tag (`v*`) push in a consumer repo triggers a release: build the
artifact, deploy to the `latere-k8s` cluster, smoke the live surface to prove
the exact build is serving, and only then publish the GitHub release with
auto-generated notes plus a smoke-evidence block.

## What's here

- `.github/workflows/service-release.yml` — reusable (`workflow_call`) pipeline
  for a k8s **service**: verify to build to deploy to smoke to release, all in
  one tag-triggered run.
- `.github/workflows/cli-release.yml` — reusable pipeline for a **CLI tool**
  (goreleaser binaries, no k8s deploy).
- `.github/workflows/images-release.yml` — reusable pipeline for a
  **container-images repo** (an image catalog, no deploy): verify to build+push
  (dependency-ordered) to publish-catalog (S3) to smoke against the published
  images to release with evidence.
- `examples/` — starter callers so a new repo gets the boilerplate.

## Design principle

The reusable workflow owns **orchestration and ordering**. Each consumer repo
owns **what to build, what to apply, and what "live" means** through standard
directories and a standard script. Variability lives in the repo by convention,
not in a sprawl of workflow inputs.

## Consumer conventions (the contract)

A service repo must provide:

| Convention | Purpose |
| --- | --- |
| `deploy/prod/` | Rollable k8s manifests. If `deploy/prod/` contains a `kustomization.yaml` (a kustomize overlay), the pipeline runs `kubectl apply -k deploy/prod/`; otherwise `kubectl apply -f deploy/prod/`. Everything here must be safe to re-apply. |
| `deploy/bootstrap/` | Bootstrap-only / immutable / alternate manifests (storageclass, alternate layouts, separate-cadence dashboards). The pipeline **ignores** this directory. |
| `tools/smoke/release.sh` | Post-deploy live smoke. Honors env `BASE_URL`, `EXPECTED_ASSET`, `OUTPUT_MD`, `SERVICE_TOKEN`. Exits non-zero if the live surface is wrong. Writes a markdown evidence block to `OUTPUT_MD`. |
| `Dockerfile.ci` | Packages the prebuilt binary `out/<service>` into a runtime image. The build job compiles the binary (and embeds the SPA); this Dockerfile only copies it in. |
| frontend at `frontend/` | (services with a UI) Built with `bun run build`, output `frontend/dist/`. The pipeline pins the served Vite asset hash to this build. |

The deployment and its main container are both named `<service>` in the
`<namespace>` namespace, so the pipeline can `kubectl set image` blindly.

An images repo (consumer of `images-release.yml`) must provide:

| Convention | Purpose |
| --- | --- |
| `catalog.yaml` | Image inventory, the single source of truth: name, context dir, platforms, `from` (in-repo base), labels, consumer resource hints. |
| `catalog.sh` | `lint \| matrix \| compose` subcommands, all driven by `catalog.yaml`: schema lint, two-stage build matrices (roots, then images that FROM them), and the digest-pinned `catalog.json` consumers read from object storage. |
| `catalog_test.sh` | Tests for the catalog tooling; the verify job runs them on every release. |
| `test.sh <tag>` | Runtime assertions run against the **published** images at that tag (honors `RUNTIME` for the container runtime). Exits non-zero on any failed check; its output becomes the release-evidence smoke block. |

The pipeline needs the `CATALOG_S3_*` secrets (endpoint, region, bucket,
prefix, scoped access key + secret) to publish `catalog.json`; the key should
carry a per-bucket grant only, since it lives in a public repo's Actions.

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

## The "actually live" check

"Live" means *this exact build is serving*, not merely that something returns
200. The smoke script pins the served Vite asset hash (`EXPECTED_ASSET`,
threaded from the frontend build evidence) to the bundle CI just built. Release
notes publish only after that smoke passes. That ordering is the spine of the
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

`secrets: inherit` passes the org `DO_TOKEN`. Service-specific smoke credentials
are declared optional on the reusable workflow. A repo whose secret names differ
(e.g. Cella's `CELLA_SMOKE_CLIENT_*`) passes them explicitly instead of
`inherit`, mapping them onto `SMOKE_CLIENT_ID`/`SMOKE_CLIENT_SECRET` (and then
also passing `DO_TOKEN: ${{ secrets.DO_TOKEN }}` by hand, since you cannot mix
`inherit` with explicit secrets).

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

The images analog of the "actually live" check: the smoke pulls the images
that were **actually pushed** at the release tag and runs the repo's `test.sh`
against them, and the digest table in the evidence comes from the same
`catalog.json` that was published to object storage. The GitHub release exists
only if all of that held.

## Versioning

Consumers pin `@v1` (a moving major tag). A bad central push would break every
release at once, so this repo runs `actionlint` on every change and is canaried
on a single pilot consumer before the `v1` tag moves. Repos that need to freeze
can pin a patch tag (e.g. `@v1.2.0`).

## Local checks

Reusable workflows, `secrets: inherit`, environments, and doctl only exercise on
GitHub runners; you cannot run this pipeline locally. The local loop is
`actionlint` (CI runs it here) to push to canary tag on a pilot repo.
