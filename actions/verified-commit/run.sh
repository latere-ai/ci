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
#                           once, so a job on the self-hosted runner does
#                           not hold one of its two slots while verify
#                           runs on the other.
#   cancelled               refused: a newer push superseded the run, so
#                           the commit itself was never verified.
#   no run at all           when the commit changes nothing but SKIP_PATHS,
#                           verify's path filter skipped it and it carries
#                           its parent's code, so the parent is read
#                           instead. Otherwise the run may not exist yet,
#                           because a release pushes the branch and the tag
#                           together, so it is waited for up to five
#                           minutes (never longer than WAIT_MINUTES), then
#                           refused.
#
# Inputs, from the environment: GITHUB_REPOSITORY, GITHUB_SHA,
# GITHUB_REF_NAME, GITHUB_RUN_ID, VERIFY_WORKFLOW (the workflow file name;
# empty takes the one workflow in the checkout's .github/workflows that
# calls latere-ai/ci's lateregate.yml, the per-push gate), WAIT_MINUTES, SKIP_PATHS (one shell pattern per line, matched against
# each changed path; * matches across directories), POLL_SECONDS (30;
# the tests set 0).
set -euo pipefail

: "${GITHUB_REPOSITORY:?}" "${GITHUB_SHA:?}" "${GITHUB_REF_NAME:?}"
VERIFY_WORKFLOW=${VERIFY_WORKFLOW:-}
WAIT_MINUTES=${WAIT_MINUTES:-60}
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

# Sets VERDICT to success, failure, pending, cancelled or none for the verify
# runs of commit $1, and RUNS to their conclusions.
read_verdict() {
    # $ENV is jq's, which reads the tag from the environment.
    # shellcheck disable=SC2016
    RUNS=$(gh api "repos/${GITHUB_REPOSITORY}/actions/workflows/${VERIFY_WORKFLOW}/runs?head_sha=$1&event=push&per_page=20" \
        --jq '[.workflow_runs[] | select(.head_branch != $ENV.GITHUB_REF_NAME) | .conclusion // "running"] | join(" ")') \
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
            echo "$VERIFY_WORKFLOW concluded success on $sha"
            exit 0
            ;;
        failure)
            die "$VERIFY_WORKFLOW concluded '$RUNS' on $sha; a release is cut from a green tree"
            ;;
        cancelled)
            die "$VERIFY_WORKFLOW was cancelled on $sha, superseded by a newer push, so the commit was never verified. Re-run that $VERIFY_WORKFLOW run, or tag a newer commit."
            ;;
        pending)
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
            read_change "$sha"
            if [ -z "$CODE" ]; then
                walked=$((walked + 1))
                if [ "$walked" -gt "$MAX_WALK" ]; then
                    die "$VERIFY_WORKFLOW ran on none of the $MAX_WALK commits up to $GITHUB_SHA"
                fi
                echo "$VERIFY_WORKFLOW skipped $sha, which changes only skipped paths; reading its parent $PARENT"
                sha=$PARENT
                continue
            fi
            if [ "$(date +%s)" -ge "$appear_deadline" ]; then
                die "$VERIFY_WORKFLOW has no run on $sha, which changes $CODE; tag a commit whose $VERIFY_WORKFLOW ran"
            fi
            echo "no $VERIFY_WORKFLOW run on $sha yet"
            sleep "$POLL_SECONDS"
            ;;
    esac
done
