#!/usr/bin/env bash
#
# The tagged commit passed the repository's verify workflow on its branch
# push, so a release is cut from a green tree.
#
# The runs read are the verify runs GitHub recorded for the commit's branch
# push; the run the tag's own push starts is not one of them. Across those
# runs, in this order:
#
#   success                 the commit is verified.
#   failure and the like    refused: timed_out, startup_failure,
#                           action_required, neutral, skipped and stale
#                           count as failure, since none verified it.
#   running or queued       waited for up to WAIT_MINUTES; 0 refuses at
#                           once. Empty waits 60 minutes on a GitHub-hosted
#                           runner and refuses at once on the self-hosted
#                           runner, so a release there does not hold one of
#                           its two slots while verify runs on the other.
#   cancelled               refused: a newer push superseded the run, so
#                           the commit itself was never verified.
#   no run at all           the run may not exist yet, because a release
#                           pushes the branch and the tag together, so it
#                           is waited for up to five minutes (never longer
#                           than WAIT_MINUTES), then refused.
#
# Once the verify workflow passed, every other workflow the same branch push
# ran must have passed too. A repository keeps a check the shared gate cannot
# host yet, such as a device session under a real sandbox, in a workflow of
# its own, and a release from a commit that check failed on is not cut from
# a green tree either. Per workflow file, a success on any of its runs
# passes; one still running is waited for as verify is; a failure and the
# like, or a cancel, refuses. A workflow whose push run skipped every job
# decided it had nothing to check, and a workflow that did not run on the
# commit, such as one whose path filter left it out, has no say.
#
# A commit that changes nothing but SKIP_PATHS carries its parent's code,
# so where its own runs are running, cancelled or missing, the parent is
# read instead. That is the commit `lateregate release` cuts: it changes
# CHANGELOG.md alone and is pushed with its tag, so its own verify run has
# only just started when the release reads it, or the path filter skipped
# it. A run that concluded on the commit itself still decides.
#
# The release is usually a tag push or a published release. A run started
# on a branch (a manual rebuild from main) reads that branch's own push run
# of the commit, since there is no tag push to set apart.
#
# Inputs, from the environment: GITHUB_REPOSITORY, GITHUB_SHA,
# GITHUB_REF_NAME, GITHUB_REF_TYPE (tag, or branch; unset reads as tag),
# GITHUB_RUN_ID, RUNNER_ENVIRONMENT, VERIFY_WORKFLOW (the workflow file name;
# empty takes the one workflow in the checkout's .github/workflows that
# calls latere-ai/ci's lateregate.yml, the per-push gate), WAIT_MINUTES, SKIP_PATHS (one shell pattern per line, matched against
# each changed path; * matches across directories), POLL_SECONDS (30;
# the tests set 0).
set -euo pipefail

: "${GITHUB_REPOSITORY:?}" "${GITHUB_SHA:?}" "${GITHUB_REF_NAME:?}"
# The verify run the tag's own push started, if any, carries the tag as its
# branch; on a branch ref there is no such run to leave out.
TAG_PUSH=""
[ "${GITHUB_REF_TYPE:-tag}" = tag ] && TAG_PUSH=$GITHUB_REF_NAME
export TAG_PUSH
VERIFY_WORKFLOW=${VERIFY_WORKFLOW:-}
# The one place the default wait is decided, for every pipeline that runs
# this check.
if [ -z "${WAIT_MINUTES:-}" ]; then
    if [ "${RUNNER_ENVIRONMENT:-github-hosted}" = self-hosted ]; then
        WAIT_MINUTES=0
    else
        WAIT_MINUTES=60
    fi
fi
POLL_SECONDS=${POLL_SECONDS:-30}
SKIP_PATHS=${SKIP_PATHS-$'specs/*\n*.md'}
# How many skipped commits are read through before giving up. Far past any
# run of documentation-only commits between two that change code.
MAX_WALK=30

case "$WAIT_MINUTES" in
    '' | *[!0-9]*) echo "::error::wait_minutes is '$WAIT_MINUTES'; it takes a whole number of minutes" >&2; exit 1 ;;
esac

die() {
    echo "::error::$*" >&2
    exit 1
}

# The per-push gate is whichever workflow calls lateregate.yml; a
# repository names it ci.yaml or verify.yml as it pleases.
if [ -z "$VERIFY_WORKFLOW" ]; then
    gates=$(grep -El 'uses:[[:space:]]*latere-ai/ci/\.github/workflows/lateregate\.yml@' .github/workflows/*.yml .github/workflows/*.yaml 2> /dev/null || true)
    case "$(printf '%s' "$gates" | grep -c .)" in
        1) VERIFY_WORKFLOW=$(basename "$gates") ;;
        0) die "no workflow in .github/workflows calls latere-ai/ci's lateregate.yml; name the per-push workflow in verify_workflow" ;;
        *) die "more than one workflow calls latere-ai/ci's lateregate.yml ($(printf '%s' "$gates" | xargs -n1 basename | tr '\n' ' ')); name the per-push one in verify_workflow" ;;
    esac
    echo "the per-push gate is $VERIFY_WORKFLOW"
fi
# read_others leaves the verify workflow out by its file name.
export VERIFY_WORKFLOW

# Sets VERDICT to success, failure, pending, cancelled or none for the verify
# runs of commit $1, and RUNS to their conclusions.
read_verdict() {
    # $ENV is jq's, which reads the tag from the environment.
    # shellcheck disable=SC2016
    RUNS=$(gh api "repos/${GITHUB_REPOSITORY}/actions/workflows/${VERIFY_WORKFLOW}/runs?head_sha=$1&event=push&per_page=20" \
        --jq '[.workflow_runs[] | select(.head_branch != $ENV.TAG_PUSH) | .conclusion // "running"] | join(" ")') \
        || die "cannot read the $VERIFY_WORKFLOW runs of $1, so nothing was released"
    case " $RUNS " in
        "  ") VERDICT=none ;;
        *" success "*) VERDICT=success ;;
        *" failure "* | *" timed_out "* | *" startup_failure "* | *" action_required "* | *" neutral "* | *" skipped "* | *" stale "*) VERDICT=failure ;;
        *" running "*) VERDICT=pending ;;
        *" cancelled "*) VERDICT=cancelled ;;
        *) VERDICT=failure ;;
    esac
}

# Sets OTHERS to "file=verdict" for each workflow other than verify that the
# branch push of commit $1 ran, and OTHER to the first verdict that decides:
# failure (with its conclusion), cancelled, running, or empty when every one
# passed or had no say.
read_others() {
    # $ENV is jq's, which reads the tag and the verify workflow from the
    # environment.
    # shellcheck disable=SC2016
    OTHERS=$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs?head_sha=$1&event=push&per_page=100" \
        --jq '[.workflow_runs[] | select(.head_branch != $ENV.TAG_PUSH)
              | {file: (.path | split("/") | last), c: (.conclusion // "running")}
              | select(.file != $ENV.VERIFY_WORKFLOW)]
            | group_by(.file)
            | map(.[0].file + "=" + (
                if any(.[]; .c == "success") then "success"
                elif any(.[]; .c == "running") then "running"
                elif all(.[]; .c == "skipped" or .c == "neutral") then "success"
                elif all(.[]; .c == "cancelled" or .c == "skipped" or .c == "neutral") then "cancelled"
                else ([.[] | .c | select(. != "skipped" and . != "neutral" and . != "cancelled")][0] // "failure") end))
            | join(" ")') \
        || die "cannot read the other workflows the push of $1 ran, so nothing was released"
    # A failure outranks a cancel, and a cancel outranks a run still going.
    OTHER=""
    local entry
    for entry in $OTHERS; do
        case "${entry#*=}" in
            success) ;;
            running) [ -n "$OTHER" ] || OTHER=running ;;
            cancelled) [ "$OTHER" = failure ] || OTHER=cancelled ;;
            *) OTHER=failure ;;
        esac
    done
}

# Sets PARENT and CODE for commit $1: its first parent, and the paths it
# changes that no SKIP_PATHS pattern matches. CODE is empty when the commit
# changes only skipped paths.
read_change() {
    local files f pat matched
    PARENT=$(gh api "repos/${GITHUB_REPOSITORY}/commits/$1" --jq '.parents[0].sha // ""') \
        || die "cannot read the parent of $1, so nothing was released"
    CODE=""
    if [ -z "$PARENT" ]; then
        CODE="(the first commit)"
        return
    fi
    files=$(gh api "repos/${GITHUB_REPOSITORY}/compare/${PARENT}...$1" --jq '.files[].filename') \
        || die "cannot read what $1 changes, so nothing was released"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        matched=0
        while IFS= read -r pat; do
            [ -n "$pat" ] || continue
            # The pattern is matched as a pattern, not as a string.
            # shellcheck disable=SC2053
            if [[ $f == $pat ]]; then
                matched=1
                break
            fi
        done <<< "$SKIP_PATHS"
        if [ "$matched" -eq 0 ]; then
            CODE="${CODE:+$CODE }$f"
        fi
    done <<< "$files"
}

# Moves to the parent when commit $sha changes only skipped paths, saying
# why with $1, and fails when it changes code. What a commit changes is read
# once, not on every poll.
changed_sha=""
through() {
    if [ "$changed_sha" != "$sha" ]; then
        read_change "$sha"
        changed_sha=$sha
    fi
    [ -z "$CODE" ] || return 1
    walked=$((walked + 1))
    if [ "$walked" -gt "$MAX_WALK" ]; then
        die "$VERIFY_WORKFLOW concluded on none of the $MAX_WALK commits up to $GITHUB_SHA"
    fi
    echo "$1 on $sha, which changes only skipped paths; reading its parent $PARENT"
    sha=$PARENT
}

start=$(date +%s)
deadline=$((start + WAIT_MINUTES * 60))
appear=5
[ "$WAIT_MINUTES" -lt "$appear" ] && appear=$WAIT_MINUTES
appear_deadline=$((start + appear * 60))

sha=$GITHUB_SHA
walked=0
while :; do
    read_verdict "$sha"
    case "$VERDICT" in
        success)
            read_others "$sha"
            case "$OTHER" in
                failure)
                    die "$VERIFY_WORKFLOW concluded success on $sha, but not every other workflow its push ran did ($OTHERS); a release is cut from a green tree"
                    ;;
                cancelled)
                    die "$VERIFY_WORKFLOW concluded success on $sha, but another workflow its push ran was cancelled ($OTHERS), so the commit was never verified by it. Re-run that run, or tag a newer commit."
                    ;;
                running)
                    if [ "$(date +%s)" -ge "$deadline" ]; then
                        if [ "$WAIT_MINUTES" -eq 0 ]; then
                            die "$VERIFY_WORKFLOW concluded success on $sha, but another workflow its push ran has not concluded ($OTHERS), and this release does not wait for it. Once it is green: gh run rerun ${GITHUB_RUN_ID:-<this run>} --failed --repo ${GITHUB_REPOSITORY}"
                        fi
                        die "another workflow the push of $sha ran did not conclude within $WAIT_MINUTES minutes ($OTHERS)"
                    fi
                    echo "$VERIFY_WORKFLOW concluded success on $sha; waiting for the other workflows its push ran ($OTHERS)"
                    sleep "$POLL_SECONDS"
                    continue
                    ;;
            esac
            echo "$VERIFY_WORKFLOW concluded success on $sha${OTHERS:+, and so did every other workflow its push ran ($OTHERS)}"
            exit 0
            ;;
        failure)
            die "$VERIFY_WORKFLOW concluded '$RUNS' on $sha; a release is cut from a green tree"
            ;;
        cancelled)
            through "$VERIFY_WORKFLOW was cancelled" && continue
            die "$VERIFY_WORKFLOW was cancelled on $sha, superseded by a newer push, so the commit was never verified. Re-run that $VERIFY_WORKFLOW run, or tag a newer commit."
            ;;
        pending)
            through "$VERIFY_WORKFLOW has not concluded" && continue
            if [ "$(date +%s)" -ge "$deadline" ]; then
                if [ "$WAIT_MINUTES" -eq 0 ]; then
                    die "$VERIFY_WORKFLOW has not concluded on $sha, and this release does not wait for it. Once it is green: gh run rerun ${GITHUB_RUN_ID:-<this run>} --failed --repo ${GITHUB_REPOSITORY}"
                fi
                die "$VERIFY_WORKFLOW did not conclude on $sha within $WAIT_MINUTES minutes"
            fi
            echo "$VERIFY_WORKFLOW is still running on $sha"
            sleep "$POLL_SECONDS"
            ;;
        none)
            through "$VERIFY_WORKFLOW has no run" && continue
            if [ "$(date +%s)" -ge "$appear_deadline" ]; then
                die "$VERIFY_WORKFLOW has no run on $sha, which changes $CODE; tag a commit whose $VERIFY_WORKFLOW ran"
            fi
            echo "no $VERIFY_WORKFLOW run on $sha yet"
            sleep "$POLL_SECONDS"
            ;;
    esac
done
