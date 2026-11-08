# Security

## Reporting a vulnerability

Report one privately, through
[GitHub's private vulnerability reporting](https://github.com/latere-ai/ci/security/advisories/new)
or by email to security@latere.ai. Do not open a public issue for it. The
[organization's security policy](https://github.com/latere-ai/.github/blob/main/SECURITY.md)
sets the response times, how disclosure works, and the safe harbor for
research done in good faith.

A fix ships in the next version 1 release. Callers pin `@v1`, which moves
when that release is cut, so the fix reaches every caller at once; the
[changelog](CHANGELOG.md) says which release has it.

## What is protected

The workflows run in the calling repository, with the token, permissions
and secrets the caller grants. They decide whether a tag may become a
release, build and sign what it ships, deploy it when the caller asks, and
publish the release last. Against a tag on a commit that did not pass its
checks, a re-run of an older tag, a file or image that changes between
the stage that made it and the stage that publishes it, and a tool
download that does not match its published checksum, the pipelines commit
to the following. The named tests check each property; each is named by
its file under `test/` and its title.

| Property | Tests |
|---|---|
| A release is cut only from a commit whose per-push run succeeded. A failed, timed-out or canceled run refuses, a failed push run on any branch refuses even when another succeeded, and the run the tag's own push starts does not count. | `verified_commit_test.sh`: "a failed verify refuses", "a timed-out verify refuses", "a canceled verify refuses: the commit was never verified", "a failure on another branch blocks a success on the release branch", "the run of the tag's own push does not count" |
| Every other workflow the same push ran must have passed too, and an API error refuses rather than reading as no run. | `verified_commit_test.sh`: "another workflow that failed on the push refuses", "another workflow canceled on the push refuses", "an API error refuses rather than reading as no run" |
| A commit that changes only documentation is read through to its parent, but its own failed run still refuses, a red parent refuses, and a file renamed out of code is a code change. | `verified_commit_test.sh`: "a run that failed on a docs-only commit still refuses", "a release commit on a red parent refuses", "a rename out of a code path is not read through" |
| The check runs before anything is built. | `release_ci_check_test.sh`: "verified-commit runs before 'name: Tool versions'"; `cli_release_test.sh`: "the verified job runs verified-commit", "goreleaser runs only on a verified commit whose extra tests did not fail" |
| A tag with build metadata, one off the default branch, or one with no `CHANGELOG.md` section is refused before a build. | `release_preflight_test.sh`: "build metadata is refused before anything else", "a tag off the default branch is refused", "a tag off the branch is still refused in a reused workspace", "a tag with no CHANGELOG section is refused" |
| An image namespace that is not a valid reference, or that would write extra outputs, is refused. | `release_preflight_test.sh`: "an invalid namespace is refused", "a namespace with a newline is refused and writes no output" |
| A re-run of an older tag is refused once a newer `vX.Y.Z` exists, before the image is pushed or the cluster is touched, and a remote that cannot be listed refuses. | `rollback_guard_test.sh`: "a re-run of an older tag is refused, naming the newer one", "the rollback guard runs before the image is pushed and the cluster is touched", "a checkout with no origin refuses rather than passing"; `image_deploy_test.sh`: "the rollback guard runs before the kubeconfig is written" |
| An image is pushed by digest under no tag, and must report the tag's version exactly before it is accepted. | `image_by_digest_test.sh`: "the image is pushed by digest under no tag", "a candidate reporting another version is refused", "a candidate reporting v1.2.00 for tag v1.2.0 is refused" |
| The release tag is applied only to a full digest reference. | `release_steps_test.sh`: "tag-images refuses a reference that is not by digest" |
| A service image is signed by its pushed digest, keyless, with this run's identity, before it deploys. | `service_release_test.sh`: "the image is signed by its pushed digest with the pinned cosign and syft", "tag checks, source SBOM, build, signing, deploy, smoke, CLI build and publish run in order" |
| A core deploys by digest: each image is pinned with `kustomize edit set image`, a tag or short digest is refused, and the render must carry the pinned digest. | `deploy_by_digest_test.sh`: "pin refuses a tag, a short digest and no images", "pin fails when the render does not run the pinned digest"; `image_deploy_test.sh`: "the images are pinned with kustomize edit set image", "no sed over the kustomization" |
| A rollout that does not complete, or a smoke that never passes, fails the deploy and stops the release. | `deploy_by_digest_test.sh`: "a Deployment that does not roll fails the step and stops the rest", "a smoke that never passes fails the step", "a smoke that outlives smoke_timeout is stopped" |
| The deploy credential is written to a mode 600 file under the runner's temporary directory and removed whatever the deploy's outcome. | `service_release_test.sh`: "deploy writes DEPLOY_KUBECONFIG to a 600 file under RUNNER_TEMP", "the kubeconfig is removed after the deploy, whatever its outcome"; `image_deploy_test.sh`: "DEPLOY_KUBECONFIG is written to a 600 file under RUNNER_TEMP", "the kubeconfig is removed in an always() step" |
| The service pipeline holds no cloud-provider credential, only the namespace-scoped rollout identity. | `service_release_test.sh`: "the workflow holds no DigitalOcean credential" |
| The deploy job runs in the `production` environment, so its required reviewers hold the run. | `service_release_test.sh`: "the job runs in the production environment"; `image_deploy_test.sh`: "the job runs in the production environment with the URL input" |
| `checksums.txt` covers every attached file and is signed; a release is created as a draft and published only at the end; a file pattern that matches nothing stops it before anything is created. | `release_steps_test.sh`: "signed-checksums sums every file, sorted, and not its own outputs", "signed-checksums signs checksums.txt into one bundle, replacing a stale one"; `publish_release_action_test.sh`: "it is created as a draft against the existing tag", "it ends published", "a file pattern that matches nothing is refused before anything is created" |
| A published image release is checked again from a runner with no checkout: the checksums signature must name this repository, every asset must match, each image tag must resolve to a signed digest, and the body must open with the changelog section. | `verify_release_test.sh`: "a signature that also verifies for another repository is refused", "an asset that does not match checksums.txt is refused", "an unsigned image is refused", "a body that does not open with the section is refused" |
| The command-line release's signing key reaches the GoReleaser step alone. | `cli_release_test.sh`: "the secret is referenced exactly once", "only the goreleaser step receives the signing key" |
| The daily pin move leaves no token in the checkout while the new gate release and the repository's tests run, and moves the pin only to a release version. | `ci_gate_bump_test.sh`: "no checkout leaves the token in .git/config", "the token reaches git for the push only, not the checkout's config", "an answer that is not a release version fails the check" |
| A public repository's pull request never reaches a self-hosted label through the default runner policy. | `runs_on_test.sh`: "public pull request, hosted runners down: ubuntu-latest", "public pull_request_target, hosted runners down: ubuntu-latest" |
| Every fetched kubectl and kustomize is checked against its published checksum, and the pinned version is fetched over one that only starts with it. | `ensure_tools_test.sh`: "ensure-kubectl refuses a binary whose checksum does not match", "ensure-kustomize refuses an archive whose checksum does not match", "ensure-kustomize fetches the pinned version over a longer one that starts with it" |
| Every third-party action is pinned to a full commit, and no tool is fetched at `latest`. | `pinning_test.sh`: "every SHA pin carries a '# vX' version comment", "no action fetches a tool build at 'latest'" |

## What is not defended

- **The caller's own code runs with the job's credentials.** The build
  commands, the tests, `archives_command`, `after_images_command`,
  `cli_build_cmd`, `preflight`, `after_roll` and the smoke script run the
  tagged commit's content, with the job token and, after the registry
  login, the registry credential in reach. The command inputs run as shell,
  so a caller writes them as constants and never builds them from event
  data.
- **`secrets: inherit` passes every secret.** A called workflow then sees
  every secret of the caller, not only the ones it declares. The starter
  callers use it because the service stage declares several optional
  secrets; a caller that wants a stage to see only what it names maps each
  one instead.
- **`@v1` is trust in this repository's tags.** Whoever can push a
  `v1.MINOR.PATCH` tag to latere-ai/ci changes what every `@v1` caller
  runs, with that caller's permissions and secrets, and the tag move does
  not re-read CI. A repository that needs to hold still pins a full
  version.
- **The rollback guard checks once, when the release job starts.** Two
  release jobs of different tags are not serialized.
- **`service-release.yml` deploys by tag, not digest**, and pushes `latest`
  before it deploys. No stage verifies a signature before it deploys;
  admission-time verification is the cluster's job. A failed rollout or
  smoke leaves the new version running: there is no automatic rollback.
- **`cli-release.yml` and `notes-release.yml` do not run the tag
  preflight**: a tag off the default branch, or one with build metadata,
  is accepted when its per-push run passed. A test leg that is canceled
  rather than failed does not stop a command-line release.
- **"Passed CI" means a push run of the named workflow.** A green pull
  request, a manual dispatch or an external check does not count, and only
  the first page of runs is read.
- **The default runner policy gives a private repository's pull request the
  private label.** When that names a self-hosted runner, the pull request's
  code runs there.
- **Tool downloads trust the host that serves them.** The archive and its
  checksum come from the same release host, so the check catches
  corruption and a mismatched pair, not a compromised host. A tool already
  on `PATH` is used as it is.
- **Signature identity is the workflow at any ref.** A signature from the
  stage's workflow file at any branch or tag of latere-ai/ci verifies; the
  repository check binds the source.
- **The deploy proves the pinned digest is in the render**, not that every
  container uses it. `kubectl apply -k` runs without prune, so an object
  removed from the overlay stays in the cluster.
- **A re-run of a publish replaces the release's files** and does not
  compare them with the `checksums.txt` signed earlier; the verify stage
  catches the mismatch afterwards.
- **A private repository's names become public through Sigstore.** The
  signature and certificate go to the public transparency log, with the
  repository's name and release tags.
- **`tools/repo-settings.sh` runs on your own `gh` login** and does not
  re-read a repository after it writes.

## Audit

ci has had no external security audit.

## Supply chain

- Every third-party action is pinned to a full commit SHA with its version
  in a comment, from the one list of action commits that
  [ci-gate](https://github.com/latere-ai/ci-gate) embeds and its
  `action-pins` gate enforces.
- The tools the stages fetch (cosign, syft, gh, kubectl, kustomize,
  GoReleaser and the note reader) are pinned to exact versions in
  [`actions/lib/versions.sh`](actions/lib/versions.sh) or a workflow
  input default, and kubectl, kustomize and gh are checked against their
  published checksums.
- Each stage runs the shared steps from latere-ai/ci at its own commit
  (`job.workflow_sha`), never from a moving tag or the caller's tree.
- Callers pin `@v1`, which moves only when a version is cut; a full
  version such as `@v1.37.0` stays put.
