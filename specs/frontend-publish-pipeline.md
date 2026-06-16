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

## Overview

Third child of [[frontend-cdn-decoupling]]. Once [[frontend-cdn-pilot]] proves
the publish steps by hand on `latere-ai`, extract them into a central reusable
workflow in `ci/` so each service gets edge-served frontend delivery with ~10
lines of caller wiring. Same philosophy as [[release-unification]]: one
canonical pipeline in `latere-ai/ci`, thin per-service callers.

This spec is **deliberately sequenced after the pilot** — do not abstract before
there is one working concrete instance to abstract from.

## Current State

- `ci/` holds reusable CI building blocks (`ci/examples`, `ci/README.md`); the
  release pipeline ([[release-unification]]) is the existing precedent for a
  central reusable workflow consumed by services.
- Each service currently builds its frontend inside its own `docker.yml`
  (frontend build stage → `go:embed` → image). The pilot replaces that with a
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
