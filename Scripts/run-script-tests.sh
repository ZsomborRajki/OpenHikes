#!/usr/bin/env bash
#
# Smoke tests for the shell scripts no Swift suite can reach.
#
# Neither Scripts/run-ui-tests.sh nor Scripts/run-performance-tests.sh can be
# exercised by any suite in this repository: they *are* the thing that runs the
# suites. What they decide — which device the run lands on, whether a report was
# assembled out of anything at all — is invisible until a developer reads a
# number that came from the wrong machine, so it is asserted here instead.
# Scripts/lint.sh is here for the same reason: it is what decides whether a
# change is clean, and a run that accepted an option it did not understand
# reports "clean" about a lint it never configured the way it was asked to.
# Scripts/perf-report.py is the third: it decides what a person reads first
# after a performance run, and a finding about the instrument rather than about
# the app reads exactly like a regression until somebody checks it against the
# event file by hand. Those cases run the real script against a fixture.
# Scripts/periphery.sh is the fourth, and for the same reason as lint.sh: a
# Periphery that read none of .periphery.yml scans on anyway and prints a
# result, and on this project the result it prints is a clean one.
#
# `xcrun`, `xcodebuild`, `python3`, `swiftlint` and `periphery` are replaced
# with recording stubs on PATH and the scripts are run for real against them. Nothing is built,
# nothing is booted, no simulator on this machine is touched, and no file in the
# working tree is rewritten.
#
# Exit status:
#   0  every case passed
#   1  a case failed

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: Scripts/run-script-tests.sh [--verbose]

Runs the repository's shell scripts against stubbed
xcrun/xcodebuild/swiftlint/periphery and asserts what they sent where.

Options:
  --verbose       Print each script's own output as it runs
  -h, --help      Show this help
EOF
}

verbose=false
show_help=false
# Every argument, not just the first, and --help only once the whole line has
# been checked — the same rule this suite asserts of Scripts/lint.sh below. A
# harness that quietly accepts an option it does not understand is the last
# place to learn that lesson twice.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose)
            verbose=true
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

work="$(mktemp -d -t openhikes-script-tests)"
trap 'rm -rf "$work"' EXIT
stub_bin="$work/bin"
mkdir -p "$stub_bin"

# Answers the handful of simctl subcommands the scripts make, and records every
# call so a test can assert which device each one addressed. STUB_DEVICES names
# the `simctl list devices` fixture; STUB_CONTAINER is what get_app_container
# prints, and an empty one makes it fail the way a missing app does.
cat > "$stub_bin/xcrun" <<'STUB'
#!/usr/bin/env bash
printf 'xcrun %s\n' "$*" >> "$STUB_CALL_LOG"
[[ "${1:-}" == "simctl" ]] || exit 0
shift
case "${1:-}" in
    list)
        cat "$STUB_DEVICES"
        ;;
    get_app_container)
        if [[ -z "${STUB_CONTAINER:-}" ]]; then
            echo "No such file or directory" >&2
            exit 1
        fi
        printf '%s\n' "$STUB_CONTAINER"
        ;;
esac
STUB

cat > "$stub_bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
printf 'xcodebuild %s\n' "$*" >> "$STUB_CALL_LOG"
echo "Test Suite 'All tests' passed at 2026-08-30 12:00:00.000."
exit "${STUB_XCODEBUILD_STATUS:-0}"
STUB

# Stands in for Scripts/perf-report.py, which has its own inputs and is not
# what these cases are about. It writes the report the script announces.
cat > "$stub_bin/python3" <<'STUB'
#!/usr/bin/env bash
printf 'python3 %s\n' "$*" >> "$STUB_CALL_LOG"
previous=""
for argument in "$@"; do
    if [[ "$previous" == "--out" ]]; then
        printf '# stub report\n' > "$argument"
    fi
    previous="$argument"
done
STUB

# Records every swiftlint invocation and reports whatever outcome a case asks
# for. `swiftlint version` answers with the pin, so the version-drift warning
# stays out of the output these cases read; STUB_SWIFTLINT_STATUS and
# STUB_SWIFTLINT_OUTPUT stand in for the lint's own verdict.
cat > "$stub_bin/swiftlint" <<'STUB'
#!/usr/bin/env bash
printf 'swiftlint %s\n' "$*" >> "$STUB_CALL_LOG"
if [[ "${1:-}" == "version" ]]; then
    printf '%s\n' "$STUB_SWIFTLINT_VERSION"
    exit 0
fi
printf '%s' "${STUB_SWIFTLINT_OUTPUT:-}"
exit "${STUB_SWIFTLINT_STATUS:-0}"
STUB

# Records every periphery invocation and reports whatever a case asks for.
# `periphery version` answers with the pin, so the version check passes unless
# a case sets STUB_PERIPHERY_VERSION to something else; STUB_PERIPHERY_OUTPUT
# stands in for what the scan printed, which is the only thing the script reads
# to decide whether .periphery.yml was honoured.
cat > "$stub_bin/periphery" <<'STUB'
#!/usr/bin/env bash
printf 'periphery %s\n' "$*" >> "$STUB_CALL_LOG"
if [[ "${1:-}" == "version" ]]; then
    printf '%s\n' "$STUB_PERIPHERY_VERSION"
    exit 0
fi
printf '%s' "${STUB_PERIPHERY_OUTPUT:-* No unused code detected.}"
exit "${STUB_PERIPHERY_STATUS:-0}"
STUB

chmod +x "$stub_bin"/*

# Two booted devices, so `simctl booted` would have to guess, plus a shutdown
# device sharing a name with a booted one across runtimes and a watchOS device
# whose own name contains parentheses.
cat > "$work/devices-two-booted.txt" <<'EOF'
== Devices ==
-- iOS 18.6 --
    iPhone 17 Pro (44444444-4444-4444-4444-444444444444) (Shutdown) 
-- iOS 26.5 --
    iPhone 17 (11111111-1111-1111-1111-111111111111) (Booted) 
    iPhone 17 Pro (22222222-2222-2222-2222-222222222222) (Booted) 
-- watchOS 26.5 --
    Apple Watch Series 11 (46mm) (33333333-3333-3333-3333-333333333333) (Shutdown) 
EOF

cat > "$work/devices-duplicate-name.txt" <<'EOF'
== Devices ==
-- iOS 26.5 --
    iPhone 17 Pro (22222222-2222-2222-2222-222222222222) (Booted) 
    iPhone 17 Pro (55555555-5555-5555-5555-555555555555) (Booted) 
EOF

pro_udid="22222222-2222-2222-2222-222222222222"
plain_udid="11111111-1111-1111-1111-111111111111"

failures=0
current=""

# Runs a script with the stubs in front of PATH. Sets `output` (stdout and
# stderr together), `calls` (what the stubs recorded) and `status`.
run_script() {
    current="$1"
    shift
    export STUB_CALL_LOG="$work/calls.log"
    : > "$STUB_CALL_LOG"
    status=0
    # A PATH of the stubs plus the system directories only: xcbeautify is
    # deliberately out of reach, so the output these cases read is the same on
    # a machine that has it and one that does not.
    output="$(PATH="$stub_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$@" 2>&1)" || status=$?
    calls="$(cat "$STUB_CALL_LOG")"
    if [[ "$verbose" == true ]]; then
        printf '\n--- %s ---\n%s\n' "$current" "$output"
    fi
}

fail() {
    echo "  FAIL  $current: $1" >&2
    [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/          /' >&2
    failures=$(( failures + 1 ))
}

pass() {
    echo "  ok    $current"
}

expect_status() {
    local expected="$1"
    if [[ "$status" != "$expected" ]]; then
        fail "exited $status, expected $expected" "$output"
        return 1
    fi
}

expect_contains() {
    local haystack="$1" needle="$2" what="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        fail "$what does not contain '$needle'" "$haystack"
        return 1
    fi
}

expect_absent() {
    local haystack="$1" needle="$2" what="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        fail "$what still contains '$needle'" "$haystack"
        return 1
    fi
}

ui_tests="$repository_root/Scripts/run-ui-tests.sh"
performance_tests="$repository_root/Scripts/run-performance-tests.sh"

echo "Simulator resolution"

export STUB_DEVICES="$work/devices-two-booted.txt"
unset STUB_CONTAINER STUB_XCODEBUILD_STATUS || true

run_script "run-ui-tests --dry-run targets the named device by UDID" \
    "$ui_tests" --device "iPhone 17 Pro" --dry-run
if expect_status 0 \
    && expect_contains "$output" "id=$pro_udid" "the xcodebuild destination" \
    && expect_absent "$output" "name=iPhone" "the xcodebuild destination"; then
    pass
fi

run_script "run-ui-tests resolves the other booted device to its own UDID" \
    "$ui_tests" --device "iPhone 17" --dry-run
if expect_status 0 && expect_contains "$output" "id=$plain_udid" "the xcodebuild destination"; then
    pass
fi

run_script "run-ui-tests sends xcodebuild and simctl to the same device" \
    "$ui_tests" --device "iPhone 17 Pro"
if expect_status 0 \
    && expect_contains "$calls" "id=$pro_udid" "the xcodebuild call" \
    && expect_contains "$calls" "xcrun simctl location $pro_udid clear" "the recorded calls" \
    && expect_absent "$calls" "booted" "the recorded calls"; then
    pass
fi

run_script "run-ui-tests rejects a device name no simulator has" \
    "$ui_tests" --device "iPhone 42 Pro" --dry-run
if expect_status 2 && expect_contains "$output" "No available iOS simulator named" "the error"; then
    pass
fi

STUB_DEVICES="$work/devices-duplicate-name.txt" \
    run_script "run-ui-tests refuses to guess between two devices of one name" \
        "$ui_tests" --device "iPhone 17 Pro" --dry-run
if expect_status 2 && expect_contains "$output" "More than one" "the error"; then
    pass
fi

echo "Result bundle handling"

# --dry-run is documented as printing the invocation and exiting, so the path
# handed to --result-bundle has to survive it untouched: the option takes a
# directory the caller names, and the run that only prints is not the one
# allowed to delete it. A real run still clears the stale bundle, because
# xcodebuild refuses to write over one that already exists.
sentinel_bundle="$work/sentinel.xcresult"
make_sentinel_bundle() {
    rm -rf "$sentinel_bundle"
    mkdir -p "$sentinel_bundle"
    printf 'sentinel\n' > "$sentinel_bundle/Info.plist"
}

make_sentinel_bundle
run_script "run-ui-tests --dry-run leaves the result bundle in place" \
    "$ui_tests" --device "iPhone 17 Pro" --dry-run --result-bundle "$sentinel_bundle"
if expect_status 0 \
    && expect_contains "$output" "-resultBundlePath" "the printed invocation" \
    && expect_absent "$calls" "xcodebuild" "the recorded calls"; then
    if [[ -f "$sentinel_bundle/Info.plist" ]]; then
        pass
    else
        fail "--dry-run deleted $sentinel_bundle"
    fi
fi

make_sentinel_bundle
run_script "run-ui-tests clears a stale result bundle on a real run" \
    "$ui_tests" --device "iPhone 17 Pro" --result-bundle "$sentinel_bundle"
if expect_status 0 \
    && expect_contains "$calls" "-resultBundlePath $sentinel_bundle" "the xcodebuild call"; then
    if [[ -e "$sentinel_bundle" ]]; then
        fail "the stale bundle at $sentinel_bundle was not removed"
    else
        pass
    fi
fi

echo "Performance collection"

# The app container the stubbed get_app_container hands back.
container="$work/container"
mkdir -p "$container/Documents/PerformanceLogs"
printf 'stub\n' > "$container/Documents/PerformanceLogs/live-recording.tsv"
printf 'stub\n' > "$container/Documents/PerformanceLogs/map-pan.tsv"

run_performance() {
    run_script "$1" "$performance_tests" --device "iPhone 17 Pro" \
        --output "$work/reports-$RANDOM"
}

STUB_CONTAINER="$container" \
    run_performance "run-performance-tests addresses one device throughout"
if expect_status 0 \
    && expect_contains "$calls" "id=$pro_udid" "the xcodebuild call" \
    && expect_contains "$calls" "xcrun simctl privacy $pro_udid grant" "the recorded calls" \
    && expect_contains "$calls" "xcrun simctl get_app_container $pro_udid" "the recorded calls" \
    && expect_absent "$calls" "booted " "the recorded calls" \
    && expect_contains "$output" "Collected 2 event file(s)" "the output"; then
    pass
fi

STUB_CONTAINER="" \
    run_performance "run-performance-tests fails when the app has no container"
if [[ "$status" == 0 ]]; then
    fail "a run with no container exited 0" "$output"
elif expect_contains "$output" "measured nothing" "the error"; then
    pass
fi

empty_container="$work/empty-container"
mkdir -p "$empty_container/Documents"
STUB_CONTAINER="$empty_container" \
    run_performance "run-performance-tests fails when the container holds no logs"
if [[ "$status" == 0 ]]; then
    fail "a run with no PerformanceLogs directory exited 0" "$output"
elif expect_contains "$output" "No PerformanceLogs directory" "the error"; then
    pass
fi

logless_container="$work/logless-container"
mkdir -p "$logless_container/Documents/PerformanceLogs"
STUB_CONTAINER="$logless_container" \
    run_performance "run-performance-tests fails a passing run that wrote no scenario logs"
if [[ "$status" == 0 ]]; then
    fail "a passing run that collected nothing exited 0" "$output"
elif expect_contains "$output" "Collected 0 event file(s)" "the output"; then
    pass
fi

echo "Raw log handling"

# Drives Scripts/lib/xcodebuild-output.sh the way both test scripts do — as the
# last element of a pipeline, under `set +e`, reading both halves of
# PIPESTATUS — and prints the two statuses so a case can assert them. The
# upstream half exits with whatever status the case asks for, standing in for
# xcodebuild.
cat > "$work/format-stream.sh" <<'CASE'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
source "$1/Scripts/lib/xcodebuild-output.sh"
raw_log="$2"
upstream_status="${3:-0}"
set +e
{
    echo "Building for testing..."
    echo "note: a line neither the formatter nor the fallback filter prints"
    exit "$upstream_status"
} | format_xcodebuild_stream "$raw_log"
statuses=("${PIPESTATUS[@]}")
printf 'upstream=%s log=%s\n' "${statuses[0]}" "${statuses[1]}"
CASE
chmod +x "$work/format-stream.sh"

# A directory that does not exist rather than one chmod'd unwritable: this
# suite has to fail tee the same way when it is run as root, which a mode-500
# directory would not.
missing_log="$work/no-such-directory/xcodebuild.log"
written_log="$work/written.log"

run_script "format_xcodebuild_stream reports a raw log it could not write" \
    "$work/format-stream.sh" "$repository_root" "$missing_log"
if expect_status 0 \
    && expect_contains "$output" "could not write the raw xcodebuild log to $missing_log" "the error" \
    && expect_contains "$output" "log=1" "the reported statuses"; then
    pass
fi

# The point of reading the two halves separately: a failed write must not be
# read as a failed run, and a failed run must not be read as a failed write.
run_script "format_xcodebuild_stream keeps xcodebuild's status while reporting the write" \
    "$work/format-stream.sh" "$repository_root" "$missing_log" 65
if expect_status 0 && expect_contains "$output" "upstream=65 log=1" "the reported statuses"; then
    pass
fi

# The fallback filter matches none of these lines and exits 1 for it. That is
# the status the old `|| true` was there for, and it still has to pass as a
# written log.
rm -f "$written_log"
run_script "format_xcodebuild_stream tolerates a filter that matched nothing" \
    "$work/format-stream.sh" "$repository_root" "$written_log"
if expect_status 0 \
    && expect_contains "$output" "log=0" "the reported statuses" \
    && expect_absent "$output" "could not write" "the output"; then
    if [[ -s "$written_log" ]] && grep -q "neither the formatter nor the fallback filter" "$written_log"; then
        pass
    else
        fail "the raw log at $written_log did not get the unformatted line"
    fi
fi

echo "Report findings"

# One fixture carrying one of each artefact the findings list used to report:
# the sampler's own 1 Hz counter and its two gauges, a body count that is
# entirely the phase's scene transitions, a decode kept off the main thread,
# and a launch cost every scenario pays. Run against the real
# Scripts/perf-report.py rather than the stub above, on a PATH without it.
report_work="$work/report"
mkdir -p "$report_work/events"

{
    printf "Test Case '\-[PerformanceUITests testBackgroundRecording]' passed\n"
    printf 'PERF-PHASE\tbackground-recording\tbackground-recording\t1000.0\t1016.7\n'
    # Four bodies for four scene transitions and three fixes: the app rendered
    # nothing a fix paid for.
    printf 'PERF-COUNT\tbackground-recording\tbackground-recording\tMapSheetBody\t4.0\t1.3333333333333333\n'
    printf 'PERF-COUNT\tbackground-recording\tbackground-recording\tScenePhaseChanged\t4.0\t1.3333333333333333\n'
    printf 'PERF-COUNT\tbackground-recording\tbackground-recording\tLiveFixAccepted\t3.0\t1.0\n'
    # Nine for the same four transitions: five of them are the fixes'.
    printf 'PERF-COUNT\tbackground-recording\tbackground-recording\tMapSheetHikesBody\t9.0\t3.0\n'
    printf 'PERF-PHASE\tidle\tidle\t1000.0\t1010.0\n'
    printf 'PERF-COUNT\tidle\tidle\tProcess\t7.0\t\n'
    printf 'PERF-COUNT\tidle\tidle\tFootprint.MB\t12.0\t\n'
} > "$report_work/build.log"

write_events() {
    printf '# epoch_s\telapsed_s\tkind\tname\tvalue\tdetail\n' > "$1"
    printf '1000.1\t0.1\tinterval\tModelContainerInit\t%s\tthread=main\n' "$2" >> "$1"
    printf '1000.2\t0.2\tinterval\tPhotoImageDecoded\t67.0\tthread=off-main\n' >> "$1"
    printf '1000.3\t0.3\tinterval\tTileUnclaimedSweep\t43.8\tthread=off-main\n' >> "$1"
}
write_events "$report_work/events/photo-gallery.tsv" 40.2
write_events "$report_work/events/settings.tsv" 43.8

# Sets `findings` to the report's findings list alone, which is the section
# these cases are about.
run_report() {
    current="$1"
    status=0
    output="$(python3 "$repository_root/Scripts/perf-report.py" \
        --log "$report_work/build.log" \
        --events "$report_work/events" \
        --out "$report_work/report.md" 2>&1)" || status=$?
    findings="$(awk '/^## Findings/{inside=1; next} /^## /{inside=0} inside' \
        "$report_work/report.md")"
    if [[ "$verbose" == true ]]; then
        printf '\n--- %s ---\n%s\n' "$current" "$findings"
    fi
}

run_report "perf-report keeps the sampler's own counters out of the findings"
if expect_status 0 \
    && expect_absent "$findings" "Process" "the findings" \
    && expect_absent "$findings" "Footprint.MB" "the findings"; then
    pass
fi

run_report "perf-report charges scene transitions to nobody's fixes"
if expect_status 0 \
    && expect_absent "$findings" "MapSheetBody" "the findings" \
    && expect_contains "$findings" "MapSheetHikesBody" "the findings"; then
    pass
fi

run_report "perf-report applies the frame budget to main-thread work only"
if expect_status 0 \
    && expect_absent "$findings" "PhotoImageDecoded" "the findings" \
    && expect_absent "$findings" "TileUnclaimedSweep" "the findings" \
    && expect_contains "$findings" "ModelContainerInit" "the findings"; then
    pass
fi

run_report "perf-report states a finding two scenarios share once"
if expect_status 0 \
    && expect_contains "$findings" "in 2 scenarios — worst 43.8 ms in \`settings\`" \
        "the findings"; then
    if [[ "$(grep -c 'ModelContainerInit' <<< "$findings")" == 1 ]]; then
        pass
    else
        fail "the shared launch cost was stated more than once" "$findings"
    fi
fi

echo "This suite's own arguments"

# Only invocations that exit before any test runs: this script is the one being
# run, and a case that let it reach the suite proper would run it again.
script_tests="$repository_root/Scripts/run-script-tests.sh"

run_script "run-script-tests --help prints the options" "$script_tests" --help
if expect_status 0 && expect_contains "$output" "Usage: Scripts/run-script-tests.sh" "the help"; then
    pass
fi

run_script "run-script-tests rejects an unknown option after --verbose" \
    "$script_tests" --verbose --not-a-real-option
if expect_status 2 && expect_contains "$output" "unknown option '--not-a-real-option'" "the error"; then
    pass
fi

run_script "run-script-tests rejects an unknown option after --help" \
    "$script_tests" --help --not-a-real-option
if expect_status 2 && expect_contains "$output" "unknown option '--not-a-real-option'" "the error"; then
    pass
fi

echo "Lint argument handling"

lint="$repository_root/Scripts/lint.sh"
export STUB_SWIFTLINT_VERSION="$(cat "$repository_root/.swiftlint-version")"
unset STUB_SWIFTLINT_STATUS STUB_SWIFTLINT_OUTPUT || true

run_script "lint with no arguments lints once and reports clean" "$lint"
if expect_status 0 \
    && expect_contains "$calls" "swiftlint lint --strict --quiet --force-exclude" "the recorded calls" \
    && expect_absent "$calls" "--fix" "the recorded calls" \
    && expect_contains "$output" "SwiftLint clean" "the output"; then
    pass
fi

run_script "lint --fix corrects and then re-lints" "$lint" --fix
if expect_status 0 \
    && expect_contains "$calls" "swiftlint lint --fix --quiet --force-exclude" "the recorded calls" \
    && expect_contains "$calls" "swiftlint lint --strict --quiet --force-exclude" "the recorded calls" \
    && expect_contains "$output" "SwiftLint clean" "the output"; then
    pass
fi

run_script "lint --help prints the options without linting" "$lint" --help
if expect_status 0 \
    && expect_contains "$output" "Usage: Scripts/lint.sh" "the help" \
    && expect_absent "$calls" "swiftlint lint" "the recorded calls"; then
    pass
fi

# The four below are the ones an argument parser that reads only $1 gets wrong:
# it acts on the first token and never looks at the rest, so a typo rides along
# with a valid option and the run still exits 0.
run_script "lint rejects an unknown option after --help" "$lint" --help --not-a-real-option
if expect_status 2 \
    && expect_contains "$output" "unknown option '--not-a-real-option'" "the error" \
    && expect_absent "$calls" "swiftlint lint" "the recorded calls"; then
    pass
fi

run_script "lint rejects an unknown option after --fix" "$lint" --fix --not-a-real-option
if expect_status 2 \
    && expect_contains "$output" "unknown option '--not-a-real-option'" "the error" \
    && expect_absent "$calls" "swiftlint lint" "the recorded calls"; then
    pass
fi

run_script "lint rejects a trailing operand" "$lint" --fix Sources
if expect_status 2 && expect_contains "$output" "unknown option 'Sources'" "the error"; then
    pass
fi

run_script "lint rejects a single unknown option" "$lint" --strict
if expect_status 2 && expect_contains "$output" "unknown option '--strict'" "the error"; then
    pass
fi

echo "Periphery configuration"

periphery="$repository_root/Scripts/periphery.sh"
export STUB_PERIPHERY_VERSION="$(cat "$repository_root/.periphery-version")"
unset STUB_PERIPHERY_STATUS STUB_PERIPHERY_OUTPUT || true

run_script "periphery scans at the pinned version" "$periphery"
if expect_status 0 \
    && expect_contains "$calls" "periphery scan --quiet --disable-update-check" \
        "the recorded calls" \
    && expect_absent "$calls" "--exclude-tests" "the recorded calls" \
    && expect_contains "$output" "No unused code detected" "the output"; then
    pass
fi

run_script "periphery --exclude-tests reaches the scan" "$periphery" --exclude-tests
if expect_status 0 \
    && expect_contains "$calls" "--exclude-tests" "the recorded calls"; then
    pass
fi

# The one the suite is here for. A Periphery that did not understand the
# configuration says so in a line above an otherwise ordinary result, and
# "* No unused code detected." underneath it is what a scan that indexed
# nothing prints too.
export STUB_PERIPHERY_OUTPUT="warning: .periphery.yml: invalid key 'retain_hashable_properties'
* No unused code detected."
run_script "periphery fails a scan that did not read .periphery.yml" "$periphery"
if expect_status 1 \
    && expect_contains "$output" "did not read .periphery.yml as written" "the error"; then
    pass
fi

export STUB_PERIPHERY_OUTPUT="error: The '--targets' option is required."
export STUB_PERIPHERY_STATUS=1
run_script "periphery reports a missing option as a broken config, not a finding" "$periphery"
if expect_status 1 \
    && expect_contains "$output" "did not read .periphery.yml as written" "the error"; then
    pass
fi
unset STUB_PERIPHERY_OUTPUT STUB_PERIPHERY_STATUS

export STUB_PERIPHERY_STATUS=1
run_script "periphery reports a scan that could not complete" "$periphery"
if expect_status 1 \
    && expect_contains "$output" "nothing was analysed" "the error"; then
    pass
fi
unset STUB_PERIPHERY_STATUS

# An error rather than the warning Scripts/lint.sh settles for: 2.21.2 reads
# none of .periphery.yml and still prints a clean result, so a run that reached
# the scan would report the code was checked when it was not.
export STUB_PERIPHERY_VERSION="2.21.2"
run_script "periphery refuses a version older than the pin" "$periphery"
if expect_status 1 \
    && expect_contains "$output" "2.21.2 installed" "the error" \
    && expect_absent "$calls" "periphery scan" "the recorded calls"; then
    pass
fi

export STUB_PERIPHERY_VERSION="3.9.0"
run_script "periphery warns about a version newer than the pin and scans on" "$periphery"
if expect_status 0 \
    && expect_contains "$output" "3.9.0 installed" "the warning" \
    && expect_contains "$calls" "periphery scan" "the recorded calls"; then
    pass
fi
export STUB_PERIPHERY_VERSION="$(cat "$repository_root/.periphery-version")"

run_script "periphery --help prints the options without scanning" "$periphery" --help
if expect_status 0 \
    && expect_contains "$output" "Usage: Scripts/periphery.sh" "the help" \
    && expect_absent "$calls" "periphery scan" "the recorded calls"; then
    pass
fi

run_script "periphery rejects an unknown option after --exclude-tests" \
    "$periphery" --exclude-tests --not-a-real-option
if expect_status 2 \
    && expect_contains "$output" "unknown option '--not-a-real-option'" "the error" \
    && expect_absent "$calls" "periphery scan" "the recorded calls"; then
    pass
fi

echo
if (( failures > 0 )); then
    echo "$failures case(s) failed." >&2
    exit 1
fi
echo "All script smoke tests passed."
