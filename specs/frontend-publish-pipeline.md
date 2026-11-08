---
title: "Reusable Frontend Publish Pipeline: build, hash, sync to Spaces, invalidate HTML"
status: planned
affects:
  - ci/ (new reusable workflow + example)
  - ci/README.md
  - the first consumer's workflow (consumer wiring)
effort: medium
trigger: extract the publish steps of a hand-run pilot into a reusable pipeline once proven
created: 2026-06-16
updated: 2026-06-16
author: changkun
dispatched_task_id: null
---

# Reusable Frontend Publish Pipeline

> **Status: planned, unbuilt.** This is a frontend CDN publish pipeline (build,
> sync to a Spaces bucket, invalidate HTML). This repository has no frontend
> publish workflow yet. It is distinct from the dependency-ordered
> container-image builds, which `image-build.yml` and `image-publish.yml` now
> cover. For the pipelines that ship today (`service-release.yml`,
> `cli-release.yml`, `notes-release.yml` and the image stages), `README.md` is
> authoritative.

## Overview

The work needs a CDN bucket, publish credentials for it, and a hand-run pilot of
the publish steps. Once the pilot proves the steps, extract them into a central
reusable workflow in this repository so each service gets edge-served frontend
delivery with ~10 lines of caller wiring. Same philosophy as the release
pipelines: one canonical pipeline in `latere-ai/ci`, thin per-service callers.

This spec is **deliberately sequenced after the pilot**. Do not abstract before
there is one working concrete instance to abstract from.

## Current State

- `ci/` ships reusable, `@v1`-tagged pipelines consumed by thin per-repo
  callers (`service-release.yml`, `cli-release.yml`, `notes-release.yml`; see
  `README.md`). They are the established precedent for a central reusable
  workflow.
- Each frontend service currently builds its SPA in CI (`bun run build`) and
  `go:embed`s it into the service binary (`service-release.yml` `split` /
  `dockerfile` build modes, `spa_embed_dir`), so the frontend ships inside the
  image rather than from a CDN bucket. The pilot replaces the embed with a
  publish-to-bucket step; this spec generalizes it.

## Acceptance criteria

1. **Reusable workflow.** A `ci/` reusable GitHub Actions workflow with inputs
   for: service name / bucket key prefix, frontend dir, build command
   (default `bun install && bun run build`), and bucket/CDN identifiers. Secrets
   for the frontend-bucket publish credentials.
2. **Contract: build, sync, invalidate.**
   - Build the frontend (vite, plus a prerender where the site has one) to `dist/`.
   - Sync `dist/` to `<bucket>/<prefix>/` with correct per-object cache headers:
     hashed assets `immutable`, route HTML short-TTL (matching the `spa.go`
     policy the pilot preserved).
   - Invalidate only the HTML entry points at the CDN (hashed assets are
     immutable, so they need no invalidation).
3. **Idempotent and safe.** Re-running publishes deterministically; a failed sync
   does not leave the site half-updated (publish assets before flipping HTML, or
   use an atomic prefix swap; document the chosen strategy).
4. **The first consumer uses it.** The pilot's hand-rolled publish steps are
   replaced by a thin caller of this workflow, proving the abstraction on the
   first real consumer.
5. **Documented.** `README.md` gains a "frontend publish" section with the
   caller snippet, mirroring how the release pipeline is documented.
6. **No silent caps.** If the workflow skips/limits anything (e.g. only
   invalidates a fixed HTML set), it logs what it did and did not touch.

## Notes

- Keep credentials least-privilege: publish scope limited to the frontend bucket
  + CDN invalidation, never the app-storage/audit bucket.
- This pipeline is build-and-publish only; it does not deploy the Go API (that
  stays on the existing release/deploy path).
