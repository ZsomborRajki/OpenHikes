#!/usr/bin/env bash
#
# Asserts that the ThreadSanitizer job ran the suites it claims to run.
#
# The job passes `xcodebuild` a list of `-only-testing:` identifiers, and
# `xcodebuild` never validates them: one that resolves to nothing is dropped
# without a warning and the run still exits 0. That is a green job with less
# sanitizer coverage than it advertises, and the exit status cannot see it. The
# result bundle can, so this counts what actually ran and holds it against the
# pins in `.github/workflows/ci.yml`, which is also where the pins are argued
# for.
#
# Suites are exact in both directions. A fall means an identifier stopped
# matching — renamed, moved into an `extension`, misspelt. A rise means the
# list grew without the pin growing with it, and the next fall would then be
# measured against a stale number. Tests are a floor, because a suite gaining a
# test should not turn a build red.
#
# This is a file rather than a heredoc inside the workflow for the reason
# `Scripts/check-coverage-floor.sh` gives.
#
# Exit status:
#   0  the selection ran as pinned
#   1  the suite count moved, or too few tests ran

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Scripts/check-sanitized-selection.sh <test-results.json>

Counts the suites and tests in an `xcresulttool get test-results tests`
bundle and holds them against the pins CI sets.

Environment:
  EXPECTED_SUITES  The suite count the selection is pinned at
  TEST_FLOOR       The fewest tests the run may report
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

results="${1:-}"
if [[ -z "$results" ]]; then
    echo "error: no test-results report given." >&2
    usage >&2
    exit 2
fi

: "${EXPECTED_SUITES:?EXPECTED_SUITES is not set}"
: "${TEST_FLOOR:?TEST_FLOOR is not set}"

publish() {
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
}

# Every suite and every test in the bundle, by their full path. Named by path
# rather than by leaf, because two suites in different bundles are allowed to
# share a name and counting them as one would hide exactly the disappearance
# this gate exists to catch.
walked="$(
    jq -r '
        def visit($trail):
            ((.name // "?") as $name
             | ($trail + [$name]) as $here
             | (if .nodeType == "Test Suite" then "suite\t" + ($here | join("/")) + "\n"
                elif .nodeType == "Test Case" then "test\t" + ($here | join("/")) + "\n"
                else "" end)
               + ((.children // []) | map(visit($here)) | add // ""));
        (.testNodes // []) | map(visit([])) | add // ""
        | rtrimstr("\n")
    ' "$results"
)"

suites="$(printf '%s\n' "$walked" | grep -c '^suite	' || true)"
tests="$(printf '%s\n' "$walked" | grep -c '^test	' || true)"

line="ThreadSanitizer ran **$tests tests** in **$suites suites** (pinned at $EXPECTED_SUITES suites, floor $TEST_FLOOR tests)."
printf '%s\n' "$line"
printf '%s\n' "$walked" | sed -n 's/^suite	/  /p' | sort
publish "$line"

failed=false

if (( suites != EXPECTED_SUITES )); then
    if (( suites < EXPECTED_SUITES )); then
        direction="fell to"
    else
        direction="rose to"
    fi
    echo "::error::The sanitized suite count $direction $suites, against the $EXPECTED_SUITES pinned in .github/workflows/ci.yml. A fall means an -only-testing: identifier no longer resolves and its suite was silently skipped; a rise means the list grew and the pin did not."
    failed=true
fi

if (( tests < TEST_FLOOR )); then
    echo "::error::Only $tests tests ran under ThreadSanitizer, under the $TEST_FLOOR floor set in .github/workflows/ci.yml."
    failed=true
fi

[[ "$failed" == false ]]
