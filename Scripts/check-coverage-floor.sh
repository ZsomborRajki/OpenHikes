#!/usr/bin/env bash
#
# Decides whether a run's line coverage cleared the floor CI holds it to.
#
# Reads the JSON `xcrun xccov view --report --json` writes, publishes one line
# saying what was measured over which selection, and fails the step when the
# number fell under the floor.
#
# The floor, the target and the selection are environment variables rather than
# constants here, because the argument for each of them is a comment in
# `.github/workflows/ci.yml` next to the value it justifies, and a number that
# lives in two places drifts in one of them.
#
# This is a file rather than a heredoc inside that workflow because a program
# embedded in YAML is a program no parser ever reads: nothing lints it, and a
# syntax error in it surfaces as a failed job on the pull request that had
# nothing to do with it. Every program this repository runs is parse-checked by
# the `quality` job and covered by `Scripts/run-script-tests.sh`, and this one
# can fail a merge.
#
# Exit status:
#   0  at or above the floor
#   1  under the floor, or the report has no such target

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Scripts/check-coverage-floor.sh <report.json>

Checks the line coverage of COVERAGE_TARGET in an `xccov --json` report
against COVERAGE_FLOOR, and says which selection produced it.

Environment:
  COVERAGE_TARGET     The target the floor is about (e.g. OpenHikes.app)
  COVERAGE_FLOOR      The percentage the run must reach (e.g. 55.0)
  COVERAGE_SELECTION  What ran, named in the published line
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

report="${1:-}"
if [[ -z "$report" ]]; then
    echo "error: no coverage report given." >&2
    usage >&2
    exit 2
fi

: "${COVERAGE_TARGET:?COVERAGE_TARGET is not set}"
: "${COVERAGE_FLOOR:?COVERAGE_FLOOR is not set}"
: "${COVERAGE_SELECTION:?COVERAGE_SELECTION is not set}"

# Puts a line on the job summary as well as in the log, when there is one.
publish() {
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
}

# The one target the floor is about. A report with no such target is not zero
# coverage — it is a report about something else, which is what a renamed
# target or an uninstrumented build produces. Saying which targets *were* in it
# is what makes that difference visible from the log alone.
measured="$(
    jq -r --arg target "$COVERAGE_TARGET" '
        (.targets // []) as $targets
        | ($targets | map(select(.name == $target)) | first) as $found
        | if $found == null then
              "missing\t" + (
                  ($targets | map(.name // "?") | join(", ")) as $seen
                  | if $seen == "" then "nothing" else $seen end
              )
          else
              "found\t\($found.lineCoverage)\t\($found.coveredLines)\t\($found.executableLines)"
          end
    ' "$report"
)"

IFS=$'\t' read -r outcome first second third <<< "$measured"

if [[ "$outcome" != "found" ]]; then
    echo "::error::No $COVERAGE_TARGET in the coverage report — saw $first. Either the target was renamed or the build was not instrumented."
    exit 1
fi

percentage="$(awk -v fraction="$first" 'BEGIN { printf "%.2f", fraction * 100 }')"
floor="$(awk -v value="$COVERAGE_FLOOR" 'BEGIN { printf "%.2f", value }')"

# Compared unrounded, published rounded: a number that reads as the floor on
# the summary line and fails anyway is the kind of thing nobody trusts twice.
if awk -v fraction="$first" -v limit="$COVERAGE_FLOOR" \
    'BEGIN { exit !(fraction * 100 < limit) }'; then
    standing="below"
    under=true
else
    standing="at or above"
    under=false
fi

line="\`$COVERAGE_TARGET\` line coverage **$percentage%**, $standing the $floor% floor ($second/$third lines), measured over \`$COVERAGE_SELECTION\`."

# The measured number is worth reading on a run that passed, so it is printed
# before the failure rather than instead of it — a gate that swallowed it would
# leave the log saying only that something was too low.
printf '%s\n' "$line"
publish "$line"

if [[ "$under" == true ]]; then
    echo "::error::Coverage fell to $percentage%, under the $floor% floor set in .github/workflows/ci.yml."
    exit 1
fi
