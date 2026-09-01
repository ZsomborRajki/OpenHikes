#!/usr/bin/env bash
#
# Shared xcodebuild output formatting, sourced by Scripts/run-ui-tests.sh and
# Scripts/run-performance-tests.sh. Not executable on its own.
#
# xcodebuild's raw output is thousands of lines per run, most of it compiler
# invocations nobody reads. The scripts here used to reduce it with hand-rolled
# `grep -E` pipelines, which had two problems: a pattern that stopped matching
# silently showed nothing, and a compiler warning never appeared at all because
# no pattern asked for one. xcbeautify does that job properly and, under
# `--renderer github-actions`, turns each diagnostic into an inline annotation
# on the pull request.
#
# It is used rather than depended on. xcbeautify 3.2.1 ships preinstalled on
# the `macos-26` runner image and is the version Homebrew installs today, so
# local and CI output match — but a machine without it still gets the previous
# grep behaviour rather than an error, because neither script's job is to
# format text.
#
# One thing xcbeautify must not be trusted with: it drops `measured [Time, s]`
# lines, and drops indented `PERF-` markers, in both its default mode and under
# `--preserve-unbeautified`. Those two are the entire product of
# Scripts/run-performance-tests.sh and of the launch-metric test in
# Scripts/run-ui-tests.sh, so the raw stream is always tee'd to a log and the
# measurement lines are re-emitted from it afterwards by
# print_measurement_lines. Formatting the display must never be able to lose
# the numbers the run was for.

# Lines the scripts need that xcbeautify does not emit. Kept in one place
# because both the fallback filter and the post-run re-emission use it.
readonly XCODEBUILD_MEASUREMENT_PATTERN='PERF-|measured \['

# The pattern the scripts filtered with before xcbeautify existed. Retained
# verbatim so a machine without xcbeautify behaves exactly as it used to.
readonly XCODEBUILD_FALLBACK_PATTERN="Test Case|Test Suite .* (passed|failed)|error:|TEST (SUCCEEDED|FAILED)|${XCODEBUILD_MEASUREMENT_PATTERN}"

# github-actions renderer only when actually running there; a developer piping
# to a terminal wants colour and symbols, not `::error` directives.
xcodebuild_output_renderer() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        printf 'github-actions'
    else
        printf 'terminal'
    fi
}

# Reads raw xcodebuild output on stdin, writes it verbatim to $1, and prints a
# formatted version to stdout.
#
# Call it as the last element of a pipeline so ${PIPESTATUS[0]} still reports
# xcodebuild's exit status: the pipeline inside this function runs in its own
# subshell and does not disturb the caller's. This function's own status is
# then ${PIPESTATUS[1]}, and it means one thing only — whether the raw log was
# written. Call it under `set +e`, because the formatter is allowed to fail and
# a caller running with errexit would not survive that long enough to be told.
format_xcodebuild_stream() {
    local raw_log="$1"
    local statuses

    if command -v xcbeautify >/dev/null 2>&1; then
        tee "$raw_log" \
            | xcbeautify --renderer "$(xcodebuild_output_renderer)" --disable-logging
    else
        tee "$raw_log" \
            | grep -E "$XCODEBUILD_FALLBACK_PATTERN"
    fi
    statuses=("${PIPESTATUS[@]}")

    # Only the second half of that pipeline is allowed to fail: xcbeautify
    # exits non-zero on a run it read as failing, and grep exits 1 when a short
    # run matched none of the fallback patterns. Neither adds anything to the
    # xcodebuild status the caller already holds, and a blanket `|| true` used
    # to tolerate them by tolerating the whole pipeline — which quietly covered
    # tee as well. tee is the half that must not fail: the raw log is the only
    # record of the lines the formatter drops, so losing it loses the
    # measurements, the sanitizer reports, and every crash that produces no
    # formatted line at all.
    if (( statuses[0] != 0 )); then
        echo "error: could not write the raw xcodebuild log to $raw_log." >&2
        return 1
    fi
}

# Re-emits the measurement lines xcbeautify swallows, from the raw log written
# by format_xcodebuild_stream. A no-op when the run produced none, so the
# functional suites stay silent.
print_measurement_lines() {
    local raw_log="$1"

    [[ -f "$raw_log" ]] || return 0
    command -v xcbeautify >/dev/null 2>&1 || return 0

    local measurements
    measurements="$(grep -E "$XCODEBUILD_MEASUREMENT_PATTERN" "$raw_log" || true)"
    [[ -n "$measurements" ]] || return 0

    printf '\nMeasurements:\n%s\n' "$measurements"
}
