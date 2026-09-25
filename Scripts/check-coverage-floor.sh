#!/usr/bin/env bash
#
# Decides whether a run's line coverage cleared the floor CI holds it to.
#
# Reads the JSON `xcrun xccov view --report --json` writes, publishes one line
# saying what was measured over which selection, and fails the step when the
# number fell under the floor.
#
# With COVERAGE_EXCLUSIONS set, the number is recomputed over the target's
# files with the listed ones left out, and the whole-target figure is published
# beside it for the trend. What belongs in that list, and why measuring every
# file made this gate answer the wrong question, is argued in the list itself.
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
# can fail the workflow.
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
  COVERAGE_EXCLUSIONS Optional. A file of repo-relative paths, one per line,
                      left out of the measurement. Blank lines and lines
                      starting with # are ignored. A path matching no file in
                      the report fails the gate.
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

# The paths left out of the measurement, if any. Comments and blank lines are
# stripped here rather than in jq so that the list can be argued in prose — it
# is a file people have to be willing to read before adding to.
patterns=""
if [[ -n "${COVERAGE_EXCLUSIONS:-}" ]]; then
    if [[ ! -f "$COVERAGE_EXCLUSIONS" ]]; then
        echo "::error::No exclusion list at $COVERAGE_EXCLUSIONS."
        exit 2
    fi
    patterns="$(sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$COVERAGE_EXCLUSIONS")"
fi

# The one target the floor is about. A report with no such target is not zero
# coverage — it is a report about something else, which is what a renamed
# target or an uninstrumented build produces. Saying which targets *were* in it
# is what makes that difference visible from the log alone.
#
# With no exclusions the target's own totals are used as they always were, so a
# report carrying no per-file breakdown still measures. With exclusions the
# number is summed from the files that survive the list, which is why a report
# without them is refused rather than silently measured whole.
measured="$(
    jq -r --arg target "$COVERAGE_TARGET" --arg exclusions "$patterns" '
        ($exclusions | split("\n") | map(select(length > 0))) as $patterns
        | (.targets // []) as $targets
        | ($targets | map(select(.name == $target)) | first) as $found
        | def excluded($path): $patterns | any(. as $p | $path == $p or ($path | endswith("/" + $p)));
          if $found == null then
              "missing\t" + (
                  ($targets | map(.name // "?") | join(", ")) as $seen
                  | if $seen == "" then "nothing" else $seen end
              )
          elif ($patterns | length) == 0 then
              "found\t\($found.lineCoverage)\t\($found.coveredLines)\t\($found.executableLines)\t\($found.coveredLines)\t\($found.executableLines)\t0\t0\t"
          elif ($found.files == null) then
              "nofiles\t"
          else
              ($found.files) as $files
              | ($files | map(select(excluded(.path)))) as $dropped
              | ($files | map(select(excluded(.path) | not))) as $kept
              | ($patterns | map(. as $p | select(
                    $files | any(.path == $p or (.path | endswith("/" + $p))) | not
                ))) as $unmatched
              | (([$kept[].coveredLines] | add) // 0) as $covered
              | (([$kept[].executableLines] | add) // 0) as $executable
              | (([$dropped[].executableLines] | add) // 0) as $setAside
              | "found\t\(if $executable > 0 then $covered / $executable else 0 end)\t\($covered)\t\($executable)\t\($found.coveredLines)\t\($found.executableLines)\t\($dropped | length)\t\($setAside)\t\($unmatched | join(", "))"
          end
    ' "$report"
)"

IFS=$'\t' read -r outcome first second third wholeCovered wholeExecutable droppedFiles droppedLines unmatched <<< "$measured"

if [[ "$outcome" == "nofiles" ]]; then
    echo "::error::$COVERAGE_TARGET in this report carries no per-file breakdown, so COVERAGE_EXCLUSIONS cannot be applied. Produce the report with \`xccov view --report --json\`."
    exit 1
fi

if [[ "$outcome" != "found" ]]; then
    echo "::error::No $COVERAGE_TARGET in the coverage report — saw $first. Either the target was renamed or the build was not instrumented."
    exit 1
fi

# A path that matches nothing is the list rotting: a screen was renamed or
# deleted, and the entry that used to name it now exempts nothing at all. Said
# plainly and failed, because the alternative is an exemption nobody meant to
# grant turning up months later as a number that will not move.
if [[ -n "$unmatched" ]]; then
    echo "::error::These exclusions match no file in the report — rename or remove them in $COVERAGE_EXCLUSIONS: $unmatched"
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

# The whole-target number is published beside the gated one rather than
# instead of it. It is the figure that moves when a screen is added, so it is
# worth watching and not worth failing on — and a summary that showed only the
# filtered number would make the exclusions invisible to everyone but whoever
# went looking for the list.
if [[ "${droppedFiles:-0}" != "0" ]]; then
    whole="$(awk -v covered="$wholeCovered" -v executable="$wholeExecutable" \
        'BEGIN { printf "%.2f", (executable > 0 ? covered * 100 / executable : 0) }')"
    line="$line Excludes $droppedFiles view files and the $droppedLines lines in them; the whole target reads **$whole%** ($wholeCovered/$wholeExecutable)."
fi

# The measured number is worth reading on a run that passed, so it is printed
# before the failure rather than instead of it — a gate that swallowed it would
# leave the log saying only that something was too low.
printf '%s\n' "$line"
publish "$line"

if [[ "$under" == true ]]; then
    echo "::error::Coverage fell to $percentage%, under the $floor% floor set in .github/workflows/ci.yml."
    exit 1
fi
