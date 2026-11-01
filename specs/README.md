# Specs

Design specs for the pipelines in this repository. Each file carries its own
status in its frontmatter.

| Spec | Status | Delivers |
| --- | --- | --- |
| [core-service-workflows.md](core-service-workflows.md) | Complete | Shared build and publish stages for signed image releases, a release verifier, and the repeated push checks moved into `lateregate` |
| [frontend-publish-pipeline.md](frontend-publish-pipeline.md) | Planned | A reusable pipeline that publishes a frontend to the CDN |
| [go-verify-pipeline.md](go-verify-pipeline.md) | Superseded | One per-push quality bar for every Go repository; `lateregate.yml` replaced its workflow, and `go-verify.yml` is removed |
| [release-notes-from-changelog.md](release-notes-from-changelog.md) | Complete | Every release publishes the tag's CHANGELOG section |
