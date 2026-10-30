#!/usr/bin/env bash
#
# Cancels the workflow runs still queued for a branch whose work is over.
#
# Merging a pull request frees nothing. The runs its last push started stay
# queued, and on this project each one holds a macOS runner for the better part
# of an hour while the pull requests still open wait behind it: run 41017637698
# was queued for `fix/weather-badge-under-area-search` four minutes after
# PR #1255 merged and its branch was deleted, ahead of two live branches and of
# `main`'s own push. The `concurrency` group in `.github/workflows/ci.yml`
# cancels a run only when a newer push to the same ref supersedes it, and a
# merge is not a push to the branch that was merged, so nothing there ever
# reaches one.
#
# `.github/workflows/cancel-superseded-runs.yml` is what calls this, on a
# deleted branch and on a closed pull request.
#
# It refuses the default branch, whatever it is told. A queued run on `main` is
# the only thing that will ever say whether that commit compiles (*CI* in
# `AGENTS.md`), and a wall of cancelled runs there has already hidden five
# unverified merges.
#
# It cancels only what a push started, directly or through a pull request. A
# `workflow_dispatch` run is somebody's deliberate request: the TestFlight
# workflow uploads from whichever branch it is run on, and merging that branch
# mid-archive must not take the release down, least of all between the upload
# and its tag.
#
# It cancels only runs created before --created-before, which the workflow sets
# to the moment the pull request closed. Reopening a pull request is the usual
# way to run its checks again, and the runs that starts carry the same branch:
# a cleanup that reaches its listing tens of seconds after the close would
# otherwise take them down too, and nothing would follow to put them back.
#
# It spares the workflow that calls it (--spare-workflow). A run started by a
# closed pull request carries that pull request's head branch, so the cleanup
# run lists itself, in progress and newest of all: cancelled first, it would be
# stopped before the cancels behind it were ever sent, and on a merge that
# keeps its branch no `delete` event follows to send them. When the `delete`
# event's cleanup runs first, the other one is listed too, waiting on the
# workflow's concurrency group, and has nothing to take down.
#
# A run that finishes between the listing and the cancel is this script's own
# race and not a failure. The API answers that cancel 409, which `gh run cancel`
# rewrites into a sentence with no status code, and a run whose cancel is still
# being carried out may answer the same way when the second of a merge's two
# cleanups reaches it, so that sentence is read as nothing left to do. Any other
# failure is followed by a look at the run, so that one which completed is still
# reported as such if gh ever words it differently. Anything else is a failure:
# a refusal is almost always the token's, and a silent one would leave the
# queue exactly as full as before while the job went green.
#
# Exit status:
#   0  every run it may cancel on the branch was cancelled, or there was none
#   1  a cancel was refused
#   2  the arguments or the branch were not usable

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Scripts/cancel-branch-runs.sh --branch <name> [options]

Cancels every queued or running workflow run that a push or a pull request
started on the branch <name>.

Options:
  --branch <name>   The head branch whose runs are superseded (required)
  --repo <owner/name>
                    The repository, when not the checkout in the working
                    directory
  --spare-workflow <name>
                    Leave the runs of this workflow alone: the one calling
                    this script, whose own run is listed for the branch
  --created-before <time>
                    Leave alone the runs created after this UTC time, written
                    as GitHub writes one (2026-10-30T07:49:09Z)
  --limit <n>       How many of the branch's most recent runs to look at
                    (default 100)
  --dry-run         Print what would be cancelled and cancel nothing
  -h, --help        Show this help
EOF
}

require_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        echo "error: missing value for $option." >&2
        usage >&2
        exit 2
    fi
}

branch=""
repo=""
spared_workflow=""
created_before=""
limit=100
dry_run=false
show_help=false

# Every argument is checked, and --help is answered only once the whole line
# has been read: a line that also carries an option this script does not
# understand is a line whose author expected something it will not do.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch)
            require_value "$1" "${2:-}"
            branch="$2"
            shift 2
            ;;
        --repo)
            require_value "$1" "${2:-}"
            repo="$2"
            shift 2
            ;;
        --spare-workflow)
            require_value "$1" "${2:-}"
            spared_workflow="$2"
            shift 2
            ;;
        --created-before)
            require_value "$1" "${2:-}"
            created_before="$2"
            shift 2
            ;;
        --limit)
            require_value "$1" "${2:-}"
            limit="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        -h|--help)
            show_help=true
            shift
            ;;
        *)
            echo "error: unknown option '$1'." >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$show_help" == true ]]; then
    usage
    exit 0
fi

if [[ -z "$branch" ]]; then
    echo "error: no branch given." >&2
    usage >&2
    exit 2
fi

if [[ ! "$limit" =~ ^[0-9]+$ ]] || (( limit < 1 )); then
    echo "error: --limit takes a positive whole number, not '$limit'." >&2
    exit 2
fi

# Only GitHub's own spelling is taken, because the comparison below is of the
# digits alone, and they order correctly only in that layout.
timestamp_pattern='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
if [[ -n "$created_before" && ! "$created_before" =~ $timestamp_pattern ]]; then
    echo "error: --created-before takes a UTC time such as" \
        "2026-10-30T07:49:09Z, not '$created_before'." >&2
    exit 2
fi

if ! command -v gh > /dev/null 2>&1; then
    echo "error: gh is not installed, so no run can be listed or cancelled." >&2
    exit 2
fi

# gh's `run` subcommands read this, which keeps the repository out of each of
# their argument lists. `repo view` does not: it reads the checkout's remotes
# whatever GH_REPO says, so the repository is named to it outright, or the
# default branch below would be another repository's.
[[ -z "$repo" ]] || export GH_REPO="$repo"

default_branch="$(gh repo view ${repo:+"$repo"} --json defaultBranchRef \
    --jq '.defaultBranchRef.name')"
if [[ -z "$default_branch" ]]; then
    echo "error: could not read the repository's default branch." >&2
    exit 2
fi

if [[ "$branch" == "$default_branch" ]]; then
    echo "Refusing to cancel runs on $branch: it is the default branch, and its" \
        "runs are the only record that its commits compile."
    exit 2
fi

# One line per run: its id, its status, the event that started it, when, and
# the workflow it belongs to. The status is read here rather than asked of the
# API, because `gh run list` filters on one status at a time and a run waiting
# for a runner is `queued`, `requested`, `waiting` or `pending` depending on why
# it waits.
runs="$(gh run list --branch "$branch" --limit "$limit" \
    --json databaseId,status,event,createdAt,workflowName \
    --jq '.[] | [.databaseId, .status, .event, .createdAt, .workflowName]
        | @tsv')"

cancelled=0
refused=0
while IFS=$'\t' read -r id status event created_at workflow; do
    [[ -n "$id" ]] || continue
    [[ "$status" != "completed" ]] || continue
    [[ "$event" == "push" || "$event" == "pull_request" ]] || continue
    [[ -z "$spared_workflow" || "$workflow" != "$spared_workflow" ]] || continue
    if [[ -n "$created_before" \
        && "${created_at//[^0-9]/}" > "${created_before//[^0-9]/}" ]]; then
        continue
    fi

    if [[ "$dry_run" == true ]]; then
        echo "Would cancel $workflow run $id ($status) on $branch."
        cancelled=$(( cancelled + 1 ))
        continue
    fi

    answer=""
    if answer="$(gh run cancel "$id" 2>&1)"; then
        echo "Cancelled $workflow run $id ($status) on $branch."
        cancelled=$(( cancelled + 1 ))
    elif [[ "$answer" == *"Cannot cancel a workflow run that is completed"* \
        || "$(gh run view "$id" --json status --jq '.status' 2> /dev/null)" \
        == "completed" ]]; then
        # It finished while this script was reading the list, or the other
        # cleanup's cancel of it is still being carried out.
        echo "$workflow run $id on $branch had already finished," \
            "or was already being cancelled."
    else
        echo "error: could not cancel $workflow run $id on $branch: $answer" >&2
        refused=$(( refused + 1 ))
    fi
done <<< "$runs"

if (( refused > 0 )); then
    echo "error: $refused run(s) on $branch could not be cancelled." >&2
    exit 1
fi

if (( cancelled == 0 )); then
    echo "Nothing was left to cancel on $branch."
fi
