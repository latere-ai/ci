---
title: Reusable Frontend Publish Pipeline — build, hash, sync to Spaces, invalidate HTML
status: planned
depends_on:
  - ../../terraform/specs/frontend-cdn-decoupling.md
  - ../../terraform/specs/frontend-cdn-decoupling/cdn-hosting-infra.md
  - ../../latere-ai/specs/frontend-cdn-pilot.md
affects:
  - ci/ (new reusable workflow + example)
  - ci/README.md
  - latere-ai/.github/workflows/ (consumer wiring)
effort: medium
trigger: parent frontend-cdn-decoupling; extract the pilot's publish steps into a reusable pipeline once proven
created: 2026-06-16
updated: 2026-06-16
author: changkun
dispatched_task_id: null
---

# Reusable Frontend Publish Pipeline

> **Status: planned, unbuilt.** This is a frontend CDN publish pipeline (build,
> sync to a Spaces bucket, invalidate HTML). It is distinct from the shipped
> `images-release.yml` (dependency-ordered container-image builds). Both of its
> upstream deps ([[frontend-cdn-pilot]], [[frontend-cdn-decoupling]]) are still
> `planned`, so no frontend is CDN-served yet: every service still go:embeds its
> SPA. For the pipelines that ship today (`service-release.yml`,
> `cli-release.yml`, `images-release.yml`), `ci/README.md` is authoritative.

## Overview

Third child of [[frontend-cdn-decoupling]]. Once [[frontend-cdn-pilot]] proves
the publish steps by hand on `latere-ai`, extract them into a central reusable
workflow in `ci/` so each service gets edge-served frontend delivery with ~10
lines of caller wiring. Same philosophy as [[release-unification]]: one
canonical pipeline in `latere-ai/ci`, thin per-service callers.

This spec is **deliberately sequenced after the pilot** — do not abstract before
there is one working concrete instance to abstract from.

## Current State

- `ci/` ships three reusable, `@v1`-tagged pipelines consumed by thin per-repo
  callers (`service-release.yml`, `cli-release.yml`, `images-release.yml`; see
  `ci/README.md`). They are the established precedent for a central reusable
  workflow, the same philosophy as [[release-unification]].
- Each frontend service currently builds its SPA in CI (`bun run build`) and
  `go:embed`s it into the service binary (`service-release.yml` `split` /
  `dockerfile` build modes, `spa_embed_dir`), so the frontend ships inside the
  image rather than from a CDN bucket. The pilot replaces the embed with a
  publish-to-bucket step; this spec generalizes it.

## Acceptance criteria

1. **Reusable workflow.** A `ci/` reusable GitHub Actions workflow with inputs
   for: service name / bucket key prefix, frontend dir, build command
   (default `bun install && bun run build`), and bucket/CDN identifiers. Secrets
   for the frontend-bucket publish credentials from [[cdn-hosting-infra]].
2. **Contract: build → sync → invalidate.**
   - Build the frontend (vite-ssg / vite) to `dist/`.
   - Sync `dist/` to `<bucket>/<prefix>/` with correct per-object cache headers:
     hashed assets `immutable`, route HTML short-TTL (matching the `spa.go`
     policy the pilot preserved).
   - Invalidate only the HTML entry points at the CDN (hashed assets are
     immutable, so they need no invalidation).
3. **Idempotent + safe.** Re-running publishes deterministically; a failed sync
   does not leave the site half-updated (publish assets before flipping HTML, or
   use an atomic prefix swap — document the chosen strategy).
4. **`latere-ai` consumes it.** The pilot's hand-rolled publish steps are
   replaced by a thin caller of this workflow, proving the abstraction on the
   first real consumer.
5. **Documented.** `ci/README.md` gains a "frontend publish" section with the
   caller snippet, mirroring how the release pipeline is documented.
6. **No silent caps.** If the workflow skips/limits anything (e.g. only
   invalidates a fixed HTML set), it logs what it did and did not touch.

## Notes

- Keep credentials least-privilege: publish scope limited to the frontend bucket
  + CDN invalidation, never the app-storage/audit bucket.
- This pipeline is build-and-publish only; it does not deploy the Go API (that
  stays on the existing release/deploy path).
