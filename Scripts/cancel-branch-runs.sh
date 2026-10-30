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
# the only thing that will ever say whether that commit compiles, and a wall of
# cancelled runs there has already hidden five unverified merges — see
# *CI* in `AGENTS.md`, and `cancel-on-push-masks-broken-main`.
#
# A run that finishes between the listing and the cancel answers 409, which is
# this script's own race and not a failure. Anything else a cancel reports is
# one: a refusal is almost always the token's, and a silent one would leave the
# queue exactly as full as before while the job went green.
#
# Exit status:
#   0  every active run for the branch was cancelled, or there were none
#   1  a cancel was refused
#   2  the arguments or the branch were not usable

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Scripts/cancel-branch-runs.sh --branch <name> [options]

Cancels every queued or running workflow run whose head branch is <name>.

Options:
  --branch <name>   The head branch whose runs are superseded (required)
  --repo <owner/name>
                    The repository, when not the checkout in the working
                    directory
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

if ! command -v gh > /dev/null 2>&1; then
    echo "error: gh is not installed, so no run can be listed or cancelled." >&2
    exit 2
fi

# gh reads this for every subcommand below, which keeps the repository out of
# three argument lists.
[[ -z "$repo" ]] || export GH_REPO="$repo"

default_branch="$(gh repo view --json defaultBranchRef \
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

# One line per run: its id, its status, and the workflow it belongs to. The
# status is read here rather than asked of the API, because `gh run list`
# filters on one status at a time and a run waiting for a runner is `queued`,
# `requested`, `waiting` or `pending` depending on why it waits.
runs="$(gh run list --branch "$branch" --limit "$limit" \
    --json databaseId,status,workflowName \
    --jq '.[] | [.databaseId, .status, .workflowName] | @tsv')"

cancelled=0
refused=0
while IFS=$'\t' read -r id status workflow; do
    [[ -n "$id" ]] || continue
    [[ "$status" != "completed" ]] || continue

    if [[ "$dry_run" == true ]]; then
        echo "Would cancel $workflow run $id ($status) on $branch."
        cancelled=$(( cancelled + 1 ))
        continue
    fi

    answer=""
    if answer="$(gh run cancel "$id" 2>&1)"; then
        echo "Cancelled $workflow run $id ($status) on $branch."
        cancelled=$(( cancelled + 1 ))
    elif [[ "$answer" == *409* ]]; then
        # It finished while this script was reading the list.
        echo "$workflow run $id on $branch had already finished."
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
    echo "Nothing was queued for $branch."
fi
