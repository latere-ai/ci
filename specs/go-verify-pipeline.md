---
title: Reusable Go verify pipeline — one per-push quality bar for every Go repo
status: planned
depends_on: []
affects:
  - pkg/ (new cmd/covercheck)
  - ci/ (new reusable workflow + example caller)
  - ci/README.md (consumer contract)
  - llmops/ (first consumer; convert its workflow to a caller)
  - tgo/ (second consumer; needs judgement, see "leave alone")
effort: medium
trigger: three CI failures in one day in llmops, all from tests that depended on the machine running them; the fix was built in llmops and should not be built again per repo
created: 2026-08-29
updated: 2026-08-29
author: changkun
dispatched_task_id: null
---

# Reusable Go verify pipeline

## Context for whoever picks this up

`latere-ai/ci` centralizes **release**: three `workflow_call` pipelines
(`service-release.yml`, `cli-release.yml`, `images-release.yml`), all
triggered by a version tag. It centralizes nothing about the **per-push**
gates — test, lint, coverage — so every Go repo builds those itself.

The duplication is already real:

- `tgo/.github/workflows/ci.yml` has eight jobs, written for tgo.
- `llmops/.github/workflows/ci.yml` had one job; on 2026-08-29 it grew to
  six, written independently of tgo's.
- `covercheck` — a per-package coverage gate — now exists **twice**, as
  `tgo/internal/covercheck` and `llmops/internal/covercheck`.

The goal is that the next Go repo gets this by writing a caller file, not
by rebuilding it.

## Why this is worth doing, concretely

Three llmops CI failures on 2026-08-29 shared one root cause: **tests that
depended on what happened to be installed on the machine running them.**

1. A test shelled out to `systemctl daemon-reload`. macOS has no
   `systemctl`, so the code took its "not found, skip" branch and the test
   passed. The Linux runner *has* systemctl but unprivileged, so it
   returned `Interactive authentication required` and three tests failed.
2. A test resolved a harness binary with `exec.LookPath("claude")`. It
   passed on the developer's laptop, which had Claude Code installed, and
   failed on a runner that did not.
3. The same bug again after a partial fix: the `exec` was made injectable
   but the `LookPath` before it was not, so the stub was never reached.

Every one passed locally and failed in CI, which is the worst order to
find out. Two gates prevent the whole class, and both now exist in llmops:

- **`make test-hermetic`** — runs the suite with only the Go toolchain and
  the system directories on PATH. Reproduces a runner's environment
  closely enough to catch this before a push, *and is runnable locally*,
  which is the point.
- **An OS matrix** (ubuntu + macos), because development happens on macOS
  and deployment on Linux, and that asymmetry is structural.

A fourth thing surfaced separately: llmops' repository-average coverage
gate passed at **90.4%** while `internal/harness` sat at **85.7%** and
`internal/install` at **87.8%**. An average lets a well-tested package
carry an untested one and reports a number nobody can act on.

## Proposal

Two pieces. Only one of them is a workflow.

### 1. `covercheck` moves to `latere.ai/x/pkg`

Add it as a command — `pkg/cmd/covercheck` — so a consumer's `make cover`
runs `go run latere.ai/x/pkg/cmd/covercheck -profile=coverage.out`.

**`llmops`, `tgo` and `lux` already depend on `latere.ai/x/pkg`**, so this
costs consumers nothing new.

Take `llmops/internal/covercheck/` as the starting point: it is ~190 lines
with tests, gates per package against a 90% floor, and carries exemptions
in a map whose *value is the reason*, so an entry cannot exist without
one. `tgo/internal/covercheck` is the same idea and either is a fine base;
diff them and keep the better parts.

Two behaviours worth preserving, both learned the hard way:

- With `-coverpkg=./...` the same block appears once per test binary that
  executed it. Count each block **once**, covered if any run covered it.
  Summing inflates the totals.
- A profile that covers no packages is an error, not a pass.

**Decision to make deliberately: the tool goes in `pkg`, not in
`ci/tools/`.** Putting it in `ci` means `make cover` needs that repo
checked out, so it becomes CI-only in practice — and the entire lesson
above is that a gate you can only run in CI tells you too late. In `pkg`
it runs identically on a laptop and a runner, versioned by `go.mod`.

### 2. A reusable `go-verify.yml` in `ci`

Follow the principle already stated in `ci/README.md`: *the reusable
workflow owns orchestration and ordering; the consumer owns what to run
through convention, not a sprawl of workflow inputs.*

The convention is make targets. A consumer repo must provide:

| Target | Gate |
| --- | --- |
| `fmt-check` | fails if any file is not gofmt'd |
| `test` | `go vet` + `go test ./...` |
| `test-hermetic` | the suite with only the toolchain on PATH |
| `test-race` | `CGO_ENABLED=1 go test -race ./...` |
| `cover` | per-package coverage gate via covercheck |
| `lint-modernize` | `go fix` diff must be empty |
| `validate` | optional; repo-specific consistency checks |

Jobs: `test` (matrix: ubuntu-latest, macos-latest), `hermetic`, `race`,
`coverage` (uploads the profile artifact), `lint` (golangci-lint action +
`make lint-modernize`).

`llmops/.github/workflows/ci.yml` at commit `4fd51b4` is a working
implementation of exactly this shape — lift it, parameterize what must
vary, and leave the reasoning comments in place. They explain *why* each
job exists, which is the part that stops someone deleting a job that looks
redundant.

`llmops/Makefile` at the same commit has the target implementations,
including:

```make
test-hermetic:
	@go_dir=$$(dirname $$(command -v $(GO))); \
	env PATH="$$go_dir:/usr/bin:/bin" $(GO) test ./...
```

### 3. Convert llmops as the first consumer

It is the repo the gates were built in, so it should be the proof that the
reusable version is equivalent. Its workflow shrinks to a caller; its
`internal/covercheck` is deleted in favour of the `pkg` command.

## Leave alone

**Do not standardize tgo's extra jobs yet.** It has four the others do not:
a cgo-free grep, cross-compile across ten `GOOS/GOARCH` pairs, a fuzz seed
corpus, and a dependency-footprint gate (`internal/depcheck`). Each exists
because tgo promises something specific — cgo-free is a stated design
decision, the README claims cross-compilation, `llmdialect`'s stdlib-only
subtree is a property worth guarding. llmops promises none of those.

A shared gate built for one consumer is that consumer's gate with extra
indirection. Standardize the mechanism when a second repo actually wants
it.

**`speclint` is the interesting near-miss.** tgo has `internal/speclint`
enforcing spec frontmatter and lifecycle. llmops has a 26-spec tree with
its own frontmatter shape and no linting — and during the 2026-08-29
session its wikilinks, frontmatter key order and index rows were checked by
hand repeatedly, which is exactly the work that rots. It is a good
candidate for the *third* piece of this, but the two repos' conventions
differ enough that it needs its own design pass. Not in scope here.

**Converting tgo is not in scope.** Its workflow encodes decisions
(a 45-minute race timeout with a documented CPU budget, a three-tier test
strategy) that should be moved by someone who has read
`tgo/specs/010-conformance.md`, not mechanically.

## Acceptance criteria

- **AC1** `pkg/cmd/covercheck` exists with tests, gates per package, and
  reports exemptions with their reasons. `tgo` and `llmops` copies are
  deleted, not left as duplicates.
- **AC2** `ci/.github/workflows/go-verify.yml` is a `workflow_call`
  pipeline running the jobs above, with an example caller in
  `ci/examples/` and a contract table in `ci/README.md`.
- **AC3** llmops calls it, and its own workflow is a caller file. Its
  full gate set still passes, including on macOS.
- **AC4** A consumer missing an optional target (`validate`) is not a
  failure; a consumer missing a required one fails with a message naming
  the target.
- **AC5** `make test-hermetic` is runnable locally in any consumer and
  needs nothing checked out beyond that repo. This is the criterion that
  the whole design exists to satisfy — if it ends up CI-only, the
  approach is wrong.
- **AC6** The reasoning comments survive the move. A gate whose rationale
  is deleted gets deleted next.

## Out of scope

- The release pipelines. They are orthogonal and already centralized.
- Non-Go repos.
- Converting tgo, and standardizing spec linting (see "leave alone").
- Any change to what llmops or tgo actually test. This is about where the
  gates live, not what they assert.
