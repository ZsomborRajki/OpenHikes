#!/usr/bin/env bash
#
# Smoke tests for the shell scripts no Swift suite can reach.
#
# Scripts/run-ui-tests.sh cannot be exercised by any suite in this repository:
# it *is* the thing that runs the suites. What it decides — which device the
# run lands on, which tests it selects — is invisible until a developer reads a
# result that came from the wrong machine, so it is asserted here instead.
# Scripts/lint.sh is here for the same reason: it is what decides whether a
# change is clean, and a run that accepted an option it did not understand
# reports "clean" about a lint it never configured the way it was asked to.
# Scripts/periphery.sh is the third, and for the same reason: a Periphery that
# read none of .periphery.yml scans on anyway and prints a result, and on this
# project the result it prints is a clean one. Scripts/simulate-hike.sh is the
# fourth: it is the other program that drives a simulator, CI only parse-checks
# it, and its validators are what stand between a typo and a playback loop that
# divides by zero — an untested flag rots into a no-op that still exits 0.
#
# The two CI gate programs are here for a plainer reason. Scripts/
# check-coverage-floor.sh can fail a merge, and Scripts/
# check-sanitized-selection.sh is the only thing that would notice a sanitized
# suite that silently did not run — `xcodebuild` drops an `-only-testing:`
# identifier that resolves to nothing without a warning and still exits 0.
# Scripts/check-release-secrets.sh is the archive checklist's second step, and
# the mistake it catches is the silent one: a template copied into place and
# not filled in parses, resolves to nothing, and reads exactly like a working
# file. They run against fixtures written here rather than against a stub.
# So does Scripts/lib/sort-string-catalogs.swift, which rewrites every String
# Catalog in the repository on each sync and must only ever reorder one.
#
# `xcrun`, `xcodebuild`, `swiftlint` and `periphery` are replaced with
# recording stubs on PATH and the scripts are run for real against them.
# Nothing is built, nothing is booted, no simulator on this machine is touched,
# and no file in the working tree is rewritten.
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
    location)
        # The playback form ends in a lone `-` and has its waypoints piped in.
        # Read them: a stub that exits without draining leaves the `printf`
        # upstream to take a SIGPIPE, which `set -o pipefail` would report as
        # simulate-hike.sh having failed.
        if [[ "${!#}" == "-" ]]; then
            cat > /dev/null
        fi
        ;;
esac
STUB

# Records every xcodebuild invocation so a case can assert which device and
# which selection the run addressed, and reports whatever outcome it asks for.
# STUB_XCODEBUILD_OUTPUT stands in for a run's own console output, which is what
# run-ui-tests.sh reads its failed-test summary back out of; unset, it is the
# one line every case written before that existed was written against.
cat > "$stub_bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
printf 'xcodebuild %s\n' "$*" >> "$STUB_CALL_LOG"
printf '%s\n' "${STUB_XCODEBUILD_OUTPUT:-Test Suite 'All tests' passed at 2026-08-30 12:00:00.000.}"
exit "${STUB_XCODEBUILD_STATUS:-0}"
STUB

# Records every swiftlint invocation and reports whatever outcome a case asks
# for. `swiftlint version` answers with STUB_SWIFTLINT_VERSION, which most
# cases set to the pin so the version-drift warning stays out of the output
# they read; the drift cases set it to something else on purpose.
# STUB_SWIFTLINT_STATUS and STUB_SWIFTLINT_OUTPUT stand in for the lint's own
# verdict.
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
ui_bundle="OpenHikesUITests"
# One real test, and deliberately one of the three run-ui-tests.sh pins to its
# serial pass: the cases below use it for both the selection checks and the
# second pass, so a rename breaks them together rather than one at a time.
pinned_test="RecordingUITests/testDiscardingARecordingSavesNothing"
recording_test="${pinned_test#*/}"

# The cases below include real runs, and a real run claims the simulator it
# resolved. Pointed into the work directory so this suite never writes into the
# lock directory a developer's own runs use — and never refuses one of them
# either.
device_lock_dir="$work/device-locks"
export OPENHIKES_UI_TEST_LOCK_DIR="$device_lock_dir"
pro_lock="$device_lock_dir/$pro_udid.lock"

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

# A bare --all parallelises without being asked, which is the whole point: the
# PR template, CONTRIBUTING.md and AGENTS.md all tell a contributor to run that
# exact line, and a flag they have to remember is a flag they will not use. What
# these cases pin is that the fan-out reaches xcodebuild there and *only* there
# — anything narrower has nothing to spread, and CI must stay serial, since the
# accessibility job's only protection is that it always passes --suite.
run_script "run-ui-tests --all parallelises by default" \
    "$ui_tests" --device "iPhone 17 Pro" --all --dry-run
if expect_status 0 \
    && expect_contains "$output" "-parallel-testing-enabled YES" "the printed invocation" \
    && expect_contains "$output" "-parallel-testing-worker-count 3" "the printed invocation" \
    && expect_contains "$output" "Workers: 3 simulator clones" "the printed summary"; then
    pass
fi

run_script "run-ui-tests --serial is the way back to one simulator" \
    "$ui_tests" --device "iPhone 17 Pro" --all --serial --dry-run
if expect_status 0 \
    && expect_absent "$output" "-parallel-testing-enabled" "the printed invocation" \
    && expect_absent "$output" "Workers:" "the printed summary"; then
    pass
fi

# The CI case. `accessibility-ui-tests` runs `--suite <class> --all`, and a
# runner that started cloning simulators is the one regression here that would
# not be noticed locally.
run_script "run-ui-tests keeps a single class serial, as CI runs it" \
    "$ui_tests" --device "iPhone 17 Pro" --suite AccessibilityUITests --all --retry --dry-run
if expect_status 0 \
    && expect_absent "$output" "-parallel-testing-enabled" "the printed invocation"; then
    pass
fi

run_script "run-ui-tests keeps a single test serial" \
    "$ui_tests" --device "iPhone 17 Pro" --test testShowsTheWeatherBadge --dry-run
if expect_status 0 \
    && expect_absent "$output" "-parallel-testing-enabled" "the printed invocation"; then
    pass
fi

run_script "run-ui-tests --parallel overrides the default count" \
    "$ui_tests" --device "iPhone 17 Pro" --all --parallel 5 --dry-run
if expect_status 0 \
    && expect_contains "$output" "-parallel-testing-worker-count 5" "the printed invocation"; then
    pass
fi

# The count is optional, which is the part that can go wrong quietly: a parser
# that consumed the next argument regardless would read `--parallel --all` as a
# worker count of "--all" and drop the flag that makes parallelism legal here.
run_script "run-ui-tests --parallel does not swallow the flag after it" \
    "$ui_tests" --device "iPhone 17 Pro" --parallel --all --dry-run
if expect_status 0 \
    && expect_contains "$output" "-parallel-testing-worker-count 3" "the printed invocation" \
    && expect_contains "$output" "RecordingUITests" "the selected tests"; then
    pass
fi

# An explicit --parallel that cannot be honoured is refused rather than quietly
# downgraded: xcodebuild spreads classes, never the methods in one, so these
# would boot clones that install the app and then sit idle.
run_script "run-ui-tests refuses --parallel for a single test" \
    "$ui_tests" --device "iPhone 17 Pro" --parallel --dry-run
if expect_status 2 \
    && expect_contains "$output" "needs --all without --suite" "the error" \
    && expect_absent "$calls" "xcodebuild" "the recorded calls"; then
    pass
fi

run_script "run-ui-tests refuses --parallel for a single class" \
    "$ui_tests" --device "iPhone 17 Pro" --suite SettingsUITests --all --parallel --dry-run
if expect_status 2 \
    && expect_contains "$output" "needs --all without --suite" "the error"; then
    pass
fi

run_script "run-ui-tests refuses --serial and --parallel together" \
    "$ui_tests" --device "iPhone 17 Pro" --all --serial --parallel 3 --dry-run
if expect_status 2 \
    && expect_contains "$output" "contradict each other" "the error"; then
    pass
fi

run_script "run-ui-tests rejects a worker count that cannot parallelise" \
    "$ui_tests" --device "iPhone 17 Pro" --all --parallel 1 --dry-run
if expect_status 2 \
    && expect_contains "$output" "worker count of 2 or more" "the error"; then
    pass
fi

run_script "run-ui-tests rejects a worker count that is not a number" \
    "$ui_tests" --device "iPhone 17 Pro" --all --parallel two --dry-run
if expect_status 2 \
    && expect_contains "$output" "worker count of 2 or more" "the error"; then
    pass
fi

echo "Derived data"

# The shared derived-data directory is the other thing two runs cannot have at
# once: the second xcodebuild waits on the first one's build lock, prints
# nothing while it waits, and reads as a hang. Both passes have to carry the
# path, not just the first — the pinned serial pass is a second xcodebuild, and
# a run that built its clones' bundle in one place and its pinned tests' in
# another would pay for two builds and say nothing about it.
run_script "run-ui-tests --derived-data reaches both passes" \
    "$ui_tests" --device "iPhone 17 Pro" --all --derived-data "$work/dd" --dry-run
if expect_status 0 \
    && expect_contains "$output" "-derivedDataPath $work/dd" "the printed invocation" \
    && expect_contains "$output" "Derived data: $work/dd" "the printed summary"; then
    if [[ "$(grep -c -- "-derivedDataPath" <<< "$output")" == 2 ]]; then
        pass
    else
        fail "only one of the two passes was given -derivedDataPath" "$output"
    fi
fi

# Through the environment as well as the flag, for the reason
# OPENHIKES_SIMULATOR_NAME is: a second session sets both once and then runs the
# documented line, rather than remembering two flags every time.
run_script "run-ui-tests takes the derived-data path from the environment" \
    env OPENHIKES_DERIVED_DATA="$work/dd-env" \
    "$ui_tests" --device "iPhone 17 Pro" --dry-run
if expect_status 0 \
    && expect_contains "$output" "-derivedDataPath $work/dd-env" "the printed invocation"; then
    pass
fi

# And nothing at all when nobody asked, which is what keeps every existing
# machine building where it has always built.
run_script "run-ui-tests leaves derived data alone when nobody asked" \
    "$ui_tests" --device "iPhone 17 Pro" --dry-run
if expect_status 0 \
    && expect_absent "$output" "-derivedDataPath" "the printed invocation" \
    && expect_absent "$output" "Derived data:" "the printed summary"; then
    pass
fi

echo "Device locking"

# A run claims the simulator it resolved and gives it back, so the next run on
# this machine is not refused by a ghost.
rm -rf "$device_lock_dir"
run_script "run-ui-tests releases the device it claimed" \
    "$ui_tests" --device "iPhone 17 Pro"
if expect_status 0 && expect_contains "$calls" "xcodebuild" "the recorded calls"; then
    if [[ -e "$pro_lock" ]]; then
        fail "the claim at $pro_lock outlived the run"
    else
        pass
    fi
fi

# A second run against a device somebody already has is told so. This is the
# case the whole mechanism exists for: without it the second install tears the
# first run's app out from under it and the failure lands on whichever test was
# executing, with nothing in the report naming the cause.
#
# The holder is this suite's own PID, which is alive by definition — a case
# that invented a number would be asserting on whatever process happened to own
# it.
rm -rf "$device_lock_dir"
mkdir -p "$pro_lock"
printf '%s\n' "$$" > "$pro_lock/pid"
run_script "run-ui-tests refuses a simulator another run holds" \
    "$ui_tests" --device "iPhone 17 Pro"
if expect_status 2 \
    && expect_contains "$output" "pid $$" "the refusal" \
    && expect_absent "$calls" "xcodebuild" "the recorded calls"; then
    pass
fi

# And the same claim left behind by a run that is gone is not a claim at all. A
# killed run must not make a simulator permanently unusable, which is the
# failure this half prevents and the reason the PID is written down rather than
# the lock being a bare directory.
#
# The dead PID is a real one, reaped: a made-up number can be a process this
# machine is running.
rm -rf "$device_lock_dir"
mkdir -p "$pro_lock"
( exit 0 ) &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
printf '%s\n' "$dead_pid" > "$pro_lock/pid"
run_script "run-ui-tests takes over a claim whose run is gone" \
    "$ui_tests" --device "iPhone 17 Pro"
if expect_status 0 && expect_contains "$calls" "xcodebuild" "the recorded calls"; then
    pass
fi

# The escape hatch runs, and — the half that matters — leaves the other run's
# claim where it found it. A flag that let one run release another run's lock
# would be worse than no flag at all.
rm -rf "$device_lock_dir"
mkdir -p "$pro_lock"
printf '%s\n' "$$" > "$pro_lock/pid"
run_script "run-ui-tests --no-device-lock starts without taking the claim" \
    "$ui_tests" --device "iPhone 17 Pro" --no-device-lock
if expect_status 0 && expect_contains "$calls" "xcodebuild" "the recorded calls"; then
    if [[ -f "$pro_lock/pid" ]]; then
        pass
    else
        fail "--no-device-lock released a claim it never took"
    fi
fi

# --dry-run claims nothing, for the same reason it leaves a result bundle
# alone: a mode whose whole job is to print what would happen must not take
# anything away from a run that is actually happening.
rm -rf "$device_lock_dir"
run_script "run-ui-tests --dry-run claims no device" \
    "$ui_tests" --device "iPhone 17 Pro" --dry-run
if expect_status 0; then
    if [[ -e "$pro_lock" ]]; then
        fail "--dry-run left a claim at $pro_lock"
    else
        pass
    fi
fi

echo "Test outcome summary"

# What a run failed, named at the end of it. The console shows a tick per test
# and one mark for a failure, so a red run reads as a green one with a trailing
# sentence — which is how two failing tests sat on main for days.
#
# The fixture is the three shapes that matter: a test that passed, one that
# failed both attempts, and one that failed and then passed the way a retry
# does. The retried one carries the *parallel* spelling, copied from a real
# run rather than invented, because the two are disjoint — a serial run of
# this bundle printed six `Test Case '-[Bundle.Class method]'` lines and no
# other kind, and a parallel one fifteen `Test case 'Class.method()' … on
# 'Clone N of …'` lines and no other kind. A summary that read only the first
# would say nothing at all in a parallel run, which is the run it is for.
export STUB_XCODEBUILD_OUTPUT="Test Case '-[OpenHikesUITests.RecordingUITests testGreen]' passed (12.0 seconds).
Test Case '-[OpenHikesUITests.CommunityUITests testBroken]' failed (3.0 seconds).
Test Case '-[OpenHikesUITests.CommunityUITests testBroken]' failed (3.1 seconds).
Test case 'WalkUITests.testFlaky()' failed on 'Clone 1 of iPhone 17 Pro - OpenHikesUITests-Runner (1234)' (9.0 seconds).
Test case 'WalkUITests.testFlaky()' passed on 'Clone 2 of iPhone 17 Pro - OpenHikesUITests-Runner (1235)' (4.0 seconds)."
export STUB_XCODEBUILD_STATUS=65

rm -rf "$device_lock_dir"
run_script "run-ui-tests names what a red run failed" \
    "$ui_tests" --device "iPhone 17 Pro"
if expect_status 65 \
    && expect_contains "$output" "Failed:" "the summary" \
    && expect_contains "$output" "CommunityUITests/testBroken" "the failed list" \
    && expect_absent "$output" "RecordingUITests/testGreen" "the summary"; then
    pass
fi

run_script "run-ui-tests separates what failed twice from what was retried" \
    "$ui_tests" --device "iPhone 17 Pro"
if expect_status 65 \
    && expect_contains "$output" "Passed on a retry:" "the summary" \
    && expect_contains "$output" "WalkUITests/testFlaky" "the retried list"; then
    pass
fi

# The retried ones are named on a green run too, and over time that is the half
# that earns its keep: -retry-tests-on-failure makes a test that failed once and
# passed once look exactly like one that always passes. Nothing here failed, so
# nothing may be reported as having failed.
export STUB_XCODEBUILD_OUTPUT="Test Case '-[OpenHikesUITests.RecordingUITests testGreen]' passed (12.0 seconds).
Test case 'WalkUITests.testFlaky()' failed on 'Clone 1 of iPhone 17 Pro - OpenHikesUITests-Runner (1234)' (9.0 seconds).
Test case 'WalkUITests.testFlaky()' passed on 'Clone 2 of iPhone 17 Pro - OpenHikesUITests-Runner (1235)' (4.0 seconds)."
export STUB_XCODEBUILD_STATUS=0

rm -rf "$device_lock_dir"
run_script "run-ui-tests names a retry a green run absorbed" \
    "$ui_tests" --device "iPhone 17 Pro"
if expect_status 0 \
    && expect_contains "$output" "Passed on a retry:" "the summary" \
    && expect_contains "$output" "WalkUITests/testFlaky" "the retried list" \
    && expect_absent "$output" "Failed:" "the summary"; then
    pass
fi

unset STUB_XCODEBUILD_OUTPUT STUB_XCODEBUILD_STATUS

# And an ordinary run says neither, rather than printing two empty headings at
# the foot of every green run anybody ever makes.
rm -rf "$device_lock_dir"
run_script "run-ui-tests stays quiet when there is nothing to report" \
    "$ui_tests" --device "iPhone 17 Pro"
if expect_status 0 \
    && expect_absent "$output" "Failed:" "the summary" \
    && expect_absent "$output" "Passed on a retry:" "the summary"; then
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

echo "Coverage floor gate"

# The gate that can fail a merge on a number nothing else checks. What is
# asserted is the decision it makes about a report produced by a tool this
# suite cannot run: which target it measured, what it publishes, and when it
# says no.
coverage_gate="$repository_root/Scripts/check-coverage-floor.sh"
gate_work="$work/gates"
mkdir -p "$gate_work"

# One target at a stated coverage, in the shape `xccov --report --json` writes.
write_coverage() {
    local path="$1" name="$2" fraction="$3" covered="$4" executable="$5"
    printf '{"targets":[{"name":"%s","lineCoverage":%s,"coveredLines":%s,"executableLines":%s}]}\n' \
        "$name" "$fraction" "$covered" "$executable" > "$path"
}

run_coverage() {
    local description="$1" report="$2" floor="${3:-55.0}"
    run_script "$description" env \
        COVERAGE_TARGET=OpenHikes.app \
        COVERAGE_FLOOR="$floor" \
        COVERAGE_SELECTION=OpenHikesTests \
        "$coverage_gate" "$report"
}

write_coverage "$gate_work/above.json" OpenHikes.app 0.5742 5742 10000
run_coverage "check-coverage-floor publishes what it measured over which selection" \
    "$gate_work/above.json"
if expect_status 0 \
    && expect_contains "$output" \
        '`OpenHikes.app` line coverage **57.42%**, at or above the 55.00% floor (5742/10000 lines), measured over `OpenHikesTests`.' \
        "the published line"; then
    pass
fi

# The floor is a floor. Equal to it is not under it.
write_coverage "$gate_work/exact.json" OpenHikes.app 0.55 110 200
run_coverage "check-coverage-floor passes coverage exactly at the floor" \
    "$gate_work/exact.json"
if expect_status 0 && expect_contains "$output" "at or above" "the published line"; then
    pass
fi

# The measured number is worth reading on a failing run too, which is why the
# line is printed beside the failure rather than instead of it.
write_coverage "$gate_work/under.json" OpenHikes.app 0.4999 100 200
run_coverage "check-coverage-floor fails under the floor and still says what it measured" \
    "$gate_work/under.json"
if expect_status 1 \
    && expect_contains "$output" "below the 55.00% floor" "the published line" \
    && expect_contains "$output" "::error::Coverage fell to 49.99%" "the annotation" \
    && expect_contains "$output" ".github/workflows/ci.yml" "the annotation"; then
    pass
fi

# A report with no such target is not zero coverage — it is a report about
# something else, and the names it did carry are what say which.
write_coverage "$gate_work/renamed.json" OpenHikesShared 0.9 90 100
run_coverage "check-coverage-floor does not read a renamed target as a fall" \
    "$gate_work/renamed.json"
if expect_status 1 \
    && expect_contains "$output" "saw OpenHikesShared" "the annotation" \
    && expect_absent "$output" "line coverage **" "the output"; then
    pass
fi

printf '{"targets":[]}\n' > "$gate_work/uninstrumented.json"
run_coverage "check-coverage-floor says it saw nothing on an uninstrumented build" \
    "$gate_work/uninstrumented.json"
if expect_status 1 && expect_contains "$output" "saw nothing" "the annotation"; then
    pass
fi

# The summary line goes on the job summary as well as into the log, and only
# when there is one to write to.
current="check-coverage-floor writes its line to the job summary"
summary_file="$gate_work/summary.md"
: > "$summary_file"
status=0
output="$(PATH="$stub_bin:/usr/bin:/bin:/usr/sbin:/sbin" env \
    COVERAGE_TARGET=OpenHikes.app COVERAGE_FLOOR=55.0 COVERAGE_SELECTION=OpenHikesTests \
    GITHUB_STEP_SUMMARY="$summary_file" \
    "$coverage_gate" "$gate_work/above.json" 2>&1)" || status=$?
if expect_status 0 \
    && expect_contains "$(cat "$summary_file")" "line coverage **57.42%**" "the job summary"; then
    pass
fi

# The exclusion list, which is the difference between measuring the code this
# job can reach and measuring the whole app. Four files at numbers chosen to
# put the two answers far apart: the views drag the whole target to 45%, and
# what is left without them reads 83%.
cat > "$gate_work/files.json" <<'FIXTURE'
{"targets":[{"name":"OpenHikes.app","lineCoverage":0.4545,"coveredLines":500,"executableLines":1100,"files":[
  {"name":"SettingsView.swift","path":"/Users/runner/work/OpenHikes/OpenHikes/Settings/SettingsView.swift","coveredLines":0,"executableLines":400},
  {"name":"HikeRow.swift","path":"/Users/runner/work/OpenHikes/OpenHikes/Hikes/HikeRow.swift","coveredLines":0,"executableLines":100},
  {"name":"HikeRecorder.swift","path":"/Users/runner/work/OpenHikes/OpenHikes/Recording/HikeRecorder.swift","coveredLines":400,"executableLines":500},
  {"name":"TileStore.swift","path":"/Users/runner/work/OpenHikes/OpenHikes/Tiles/TileStore.swift","coveredLines":100,"executableLines":100}]}]}
FIXTURE

run_coverage_excluding() {
    local description="$1" report="$2" list="$3" floor="${4:-80.0}"
    run_script "$description" env \
        COVERAGE_TARGET=OpenHikes.app \
        COVERAGE_FLOOR="$floor" \
        COVERAGE_SELECTION=OpenHikesTests \
        COVERAGE_EXCLUSIONS="$list" \
        "$coverage_gate" "$report"
}

# Blank lines and comments are stripped, because the list is a file people have
# to be willing to read before adding to and that means prose in it.
cat > "$gate_work/exclusions.txt" <<'FIXTURE'
# The screens only the UI suite evaluates.

OpenHikes/Settings/SettingsView.swift

OpenHikes/Hikes/HikeRow.swift
FIXTURE

run_coverage_excluding "check-coverage-floor measures what is left after the exclusions" \
    "$gate_work/files.json" "$gate_work/exclusions.txt"
if expect_status 0 \
    && expect_contains "$output" \
        'line coverage **83.33%**, at or above the 80.00% floor (500/600 lines)' \
        "the gated number" \
    && expect_contains "$output" \
        'Excludes 2 view files and the 500 lines in them; the whole target reads **45.45%** (500/1100).' \
        "the whole-target figure"; then
    pass
fi

# The floor is about the filtered number, so a fall in the code this job can
# actually reach still fails — which is the whole point of filtering.
run_coverage_excluding "check-coverage-floor still fails on a fall in what it does measure" \
    "$gate_work/files.json" "$gate_work/exclusions.txt" 90.0
if expect_status 1 \
    && expect_contains "$output" "::error::Coverage fell to 83.33%" "the annotation"; then
    pass
fi

# A path naming no file is the list rotting into an exemption nobody granted.
cat > "$gate_work/stale.txt" <<'FIXTURE'
OpenHikes/Settings/SettingsView.swift
OpenHikes/Settings/SettingsScreen.swift
FIXTURE
run_coverage_excluding "check-coverage-floor refuses an exclusion that matches nothing" \
    "$gate_work/files.json" "$gate_work/stale.txt"
if expect_status 1 \
    && expect_contains "$output" "OpenHikes/Settings/SettingsScreen.swift" "the annotation" \
    && expect_absent "$output" "OpenHikes/Settings/SettingsView.swift" "the annotation"; then
    pass
fi

# Filtering needs the per-file breakdown. A report without one is refused
# rather than quietly measured whole, which would read as a pass at the wrong
# number.
run_coverage_excluding "check-coverage-floor refuses to filter a report with no files" \
    "$gate_work/above.json" "$gate_work/exclusions.txt"
if expect_status 1 && expect_contains "$output" "no per-file breakdown" "the annotation"; then
    pass
fi

run_coverage_excluding "check-coverage-floor says so when the exclusion list is missing" \
    "$gate_work/files.json" "$gate_work/never-written.txt"
if expect_status 2 && expect_contains "$output" "No exclusion list at" "the annotation"; then
    pass
fi

# Unset is the old behaviour exactly: the target's own totals, and no second
# sentence about files nobody excluded.
run_coverage "check-coverage-floor measures the whole target when nothing is excluded" \
    "$gate_work/files.json" 45.0
if expect_status 0 \
    && expect_contains "$output" "line coverage **45.45%**" "the published line" \
    && expect_absent "$output" "Excludes" "the published line"; then
    pass
fi

echo "Sanitized selection gate"

# `xcodebuild` never validates an `-only-testing:` identifier: one that
# resolves to nothing is dropped without a warning and the run still exits 0.
# The exit status cannot see that, so this gate counts what the result bundle
# says actually ran — and these cases assert it counts the right things and
# fails in both directions.
selection_gate="$repository_root/Scripts/check-sanitized-selection.sh"

# Two suites and three tests, nested under a plan and a bundle the way
# `xcresulttool get test-results tests` nests them.
cat > "$gate_work/nested.json" <<'FIXTURE'
{"testNodes":[{"nodeType":"Test Plan","name":"OpenHikes","children":[
  {"nodeType":"Unit test bundle","name":"OpenHikesTests.xctest","children":[
    {"nodeType":"Test Suite","name":"TileCacheTests","children":[
      {"nodeType":"Test Case","name":"testTrimKeepsClaimedTiles()"},
      {"nodeType":"Test Case","name":"testTrimRemovesOrphans()"}]},
    {"nodeType":"Test Suite","name":"HikeStoreTests","children":[
      {"nodeType":"Test Case","name":"testSaveIsAtomic()"}]}]}]}]}
FIXTURE

# Two suites in different bundles are allowed to share a name, and counting
# them as one would hide exactly the disappearance this gate is for.
cat > "$gate_work/shared-name.json" <<'FIXTURE'
{"testNodes":[
  {"nodeType":"Unit test bundle","name":"OpenHikesTests.xctest","children":[
    {"nodeType":"Test Suite","name":"StoreTests","children":[
      {"nodeType":"Test Case","name":"testSaves()"}]}]},
  {"nodeType":"Unit test bundle","name":"OpenWidgetTests.xctest","children":[
    {"nodeType":"Test Suite","name":"StoreTests","children":[
      {"nodeType":"Test Case","name":"testReads()"}]}]}]}
FIXTURE

run_selection() {
    local description="$1" results="$2" suites="$3" floor="$4"
    run_script "$description" env \
        EXPECTED_SUITES="$suites" TEST_FLOOR="$floor" \
        "$selection_gate" "$results"
}

run_selection "check-sanitized-selection counts suites and tests wherever they nest" \
    "$gate_work/nested.json" 2 3
if expect_status 0 \
    && expect_contains "$output" "**3 tests**" "the published line" \
    && expect_contains "$output" "**2 suites**" "the published line"; then
    pass
fi

run_selection "check-sanitized-selection counts two suites sharing a name as two" \
    "$gate_work/shared-name.json" 2 2
if expect_status 0 \
    && expect_contains "$output" "**2 suites**" "the published line" \
    && expect_contains "$output" "OpenHikesTests.xctest/StoreTests" "the listed suites" \
    && expect_contains "$output" "OpenWidgetTests.xctest/StoreTests" "the listed suites"; then
    pass
fi

# A fall means an identifier stopped matching and its suite was skipped
# without a word.
run_selection "check-sanitized-selection fails a suite that stopped resolving" \
    "$gate_work/nested.json" 3 3
if expect_status 1 && expect_contains "$output" "fell to 2" "the annotation"; then
    pass
fi

# A rise means the list grew and the pin did not, and the next fall would be
# measured against a stale number.
run_selection "check-sanitized-selection fails a suite added without the pin" \
    "$gate_work/nested.json" 1 3
if expect_status 1 && expect_contains "$output" "rose to 2" "the annotation"; then
    pass
fi

# Tests are a floor: a suite gaining one must not turn the build red.
run_selection "check-sanitized-selection lets the test count rise above its floor" \
    "$gate_work/nested.json" 2 2
if expect_status 0; then
    pass
fi

run_selection "check-sanitized-selection fails a suite emptied out under a name that resolves" \
    "$gate_work/nested.json" 2 9
if expect_status 1 && expect_contains "$output" "Only 3 tests ran" "the annotation"; then
    pass
fi

# Both, when both are wrong: a run that lost a suite and its tests should not
# have to be fixed twice to find out.
printf '{"testNodes":[]}\n' > "$gate_work/nothing-ran.json"
run_selection "check-sanitized-selection reports both pins when a run broke both" \
    "$gate_work/nothing-ran.json" 2 3
if expect_status 1 \
    && expect_contains "$output" "fell to 0" "the annotation" \
    && expect_contains "$output" "Only 0 tests ran" "the annotation"; then
    pass
fi

echo "Release secrets gate"

# The archive checklist's second step. `OpenHikes/Secrets.plist` is gitignored
# and exists on one laptop, and an archive cut without it ships an app whose
# two paid map styles cannot draw a tile — while building, signing and passing
# CI.
secrets_gate="$repository_root/Scripts/check-release-secrets.sh"

# A plist with whatever values a case wants, written the way a person's own
# file is written.
write_secrets() {
    local path="$1"
    shift
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        printf '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        printf '<plist version="1.0">\n<dict>\n'
        while (( $# > 0 )); do
            printf '  <key>%s</key>\n  <string>%s</string>\n' "$1" "$2"
            shift 2
        done
        printf '</dict>\n</plist>\n'
    } > "$path"
}

write_secrets "$gate_work/real.plist" \
    StadiaAPIKey "8f2b1c" ThunderforestAPIKey "4d9e7a"
run_script "check-release-secrets passes a file where both keys resolve" \
    "$secrets_gate" --plist "$gate_work/real.plist"
if expect_status 0 \
    && expect_contains "$output" "2 keys resolve" "the output" \
    && expect_contains "$output" "Safe to archive" "the output"; then
    pass
fi

run_script "check-release-secrets names the template when the file is absent" \
    "$secrets_gate" --plist "$gate_work/not-here.plist"
if expect_status 1 \
    && expect_contains "$output" "Secrets.example.plist" "the error" \
    && expect_contains "$output" "gitignored" "the error"; then
    pass
fi

write_secrets "$gate_work/one-key.plist" StadiaAPIKey "8f2b1c"
run_script "check-release-secrets names a missing key with its provider" \
    "$secrets_gate" --plist "$gate_work/one-key.plist"
if expect_status 1 \
    && expect_contains "$output" "ThunderforestAPIKey is missing" "the error" \
    && expect_contains "$output" "Thunderforest Outdoors" "the error" \
    && expect_absent "$output" "StadiaAPIKey" "the error"; then
    pass
fi

write_secrets "$gate_work/empty.plist" \
    StadiaAPIKey "" ThunderforestAPIKey "4d9e7a"
run_script "check-release-secrets refuses an emptied key" \
    "$secrets_gate" --plist "$gate_work/empty.plist"
if expect_status 1 && expect_contains "$output" "StadiaAPIKey is empty" "the error"; then
    pass
fi

# The likelier mistake than a missing file: the template copied into place and
# not filled in leaves a file that parses, resolves to nothing, and reads
# exactly like a working one.
run_script "check-release-secrets refuses the checked-in template unfilled" \
    "$secrets_gate" --plist "$repository_root/Secrets.example.plist"
if expect_status 1 \
    && expect_contains "$output" "template placeholder" "the error" \
    && expect_contains "$output" "StadiaAPIKey" "the error" \
    && expect_contains "$output" "ThunderforestAPIKey" "the error"; then
    pass
fi

# Both problems at once, so a person fixing one does not have to run it again
# to learn about the other.
write_secrets "$gate_work/both-wrong.plist" \
    StadiaAPIKey "" ThunderforestAPIKey "YOUR_THUNDERFOREST_API_KEY"
run_script "check-release-secrets reports every unusable key at once" \
    "$secrets_gate" --plist "$gate_work/both-wrong.plist"
if expect_status 1 \
    && expect_contains "$output" "StadiaAPIKey is empty" "the error" \
    && expect_contains "$output" "ThunderforestAPIKey is still the template placeholder" "the error"; then
    pass
fi

cat > "$gate_work/array.plist" <<'FIXTURE'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array><string>not a dictionary</string></array>
</plist>
FIXTURE
run_script "check-release-secrets refuses a plist that is not a dictionary" \
    "$secrets_gate" --plist "$gate_work/array.plist"
if expect_status 1 && expect_contains "$output" "not a dictionary" "the error"; then
    pass
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

# The verdict has to name the version that ran. Crediting it to the pin tells a
# reader a clean run happened at the version CI will use when it did not, and
# the drift warning printed just above says in so many words that the two
# versions do not agree on the rules.
pinned_version="$(cat "$repository_root/.swiftlint-version")"
export STUB_SWIFTLINT_VERSION="$pinned_version-drifted"

run_script "lint credits a clean verdict to the version that ran" "$lint"
if expect_status 0 \
    && expect_contains "$output" "swiftlint $STUB_SWIFTLINT_VERSION installed" "the warning" \
    && expect_contains "$output" \
        "SwiftLint clean ($STUB_SWIFTLINT_VERSION, --strict; CI pins $pinned_version)." \
        "the output"; then
    pass
fi

export STUB_SWIFTLINT_STATUS=2
run_script "lint credits a violation verdict to the version that ran" "$lint"
if expect_status 2 \
    && expect_contains "$output" \
        "found violations ($STUB_SWIFTLINT_VERSION, --strict; CI pins $pinned_version)." \
        "the error"; then
    pass
fi
unset STUB_SWIFTLINT_STATUS

export STUB_SWIFTLINT_VERSION="$pinned_version"

echo "Periphery configuration"

periphery="$repository_root/Scripts/periphery.sh"
export STUB_PERIPHERY_VERSION="$(cat "$repository_root/.periphery-version")"
unset STUB_PERIPHERY_STATUS STUB_PERIPHERY_OUTPUT STUB_XCODEBUILD_STATUS || true
# Every case that reaches the build names a folder under the suite's own
# scratch directory, because the script writes its build log into the folder
# and the default one is inside the working tree.
periphery_derived_data="$work/periphery-derived-data"

run_script "periphery scans at the pinned version" "$periphery" \
    --derived-data "$periphery_derived_data"
if expect_status 0 \
    && expect_contains "$calls" "periphery scan --quiet --disable-update-check" \
        "the recorded calls" \
    && expect_absent "$calls" "--exclude-tests" "the recorded calls" \
    && expect_contains "$output" "No unused code detected" "the output"; then
    pass
fi

# The fix this is here for: Periphery's own build shares one derived-data
# folder between every checkout on the machine, and its scan reads every unit
# in it. So the script builds into the folder it was given and scans exactly
# that folder's index, and Periphery builds nothing.
run_script "periphery scans the index it built, in the folder it was given" \
    "$periphery" --derived-data "$periphery_derived_data"
if expect_status 0 \
    && expect_contains "$calls" \
        "xcodebuild -project OpenHikes.xcodeproj -scheme OpenHikes -parallelizeTargets -derivedDataPath $periphery_derived_data -quiet build-for-testing" \
        "the recorded calls" \
    && expect_contains "$calls" "COMPILER_INDEX_STORE_ENABLE=YES" "the recorded calls" \
    && expect_contains "$calls" "-skipPackagePluginValidation -destination generic/platform=iOS Simulator" \
        "the recorded calls" \
    && expect_contains "$calls" \
        "--index-store-path $periphery_derived_data/Index.noindex/DataStore" \
        "the recorded calls"; then
    pass
fi

export STUB_XCODEBUILD_STATUS=65
run_script "periphery does not scan when its build failed" "$periphery" \
    --derived-data "$periphery_derived_data"
if expect_status 1 \
    && expect_contains "$output" "the build Periphery reads its index from failed" "the error" \
    && expect_absent "$calls" "periphery scan" "the recorded calls"; then
    pass
fi
unset STUB_XCODEBUILD_STATUS

run_script "periphery --derived-data needs a path" "$periphery" --derived-data
if expect_status 2 \
    && expect_contains "$output" "--derived-data needs a path" "the error" \
    && expect_absent "$calls" "xcodebuild" "the recorded calls"; then
    pass
fi

run_script "periphery --exclude-tests reaches the scan" "$periphery" --exclude-tests \
    --derived-data "$periphery_derived_data"
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
run_script "periphery fails a scan that did not read .periphery.yml" "$periphery" \
    --derived-data "$periphery_derived_data"
if expect_status 1 \
    && expect_contains "$output" "did not read .periphery.yml as written" "the error"; then
    pass
fi

export STUB_PERIPHERY_OUTPUT="error: The '--targets' option is required."
export STUB_PERIPHERY_STATUS=1
run_script "periphery reports a missing option as a broken config, not a finding" "$periphery" \
    --derived-data "$periphery_derived_data"
if expect_status 1 \
    && expect_contains "$output" "did not read .periphery.yml as written" "the error"; then
    pass
fi
unset STUB_PERIPHERY_OUTPUT STUB_PERIPHERY_STATUS

export STUB_PERIPHERY_STATUS=1
run_script "periphery reports a scan that could not complete" "$periphery" \
    --derived-data "$periphery_derived_data"
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
run_script "periphery warns about a version newer than the pin and scans on" "$periphery" \
    --derived-data "$periphery_derived_data"
if expect_status 0 \
    && expect_contains "$output" "3.9.0 installed" "the warning" \
    && expect_contains "$calls" "periphery scan" "the recorded calls"; then
    pass
fi
export STUB_PERIPHERY_VERSION="$(cat "$repository_root/.periphery-version")"

run_script "periphery --help prints the options without scanning" "$periphery" --help
if expect_status 0 \
    && expect_contains "$output" "Usage: Scripts/periphery.sh" "the help" \
    && expect_contains "$output" ".build/periphery" "the help" \
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

echo "Selection rejections"

# The two rejections nothing covered. A name that does not exist has to be
# refused with the list rather than handed to xcodebuild, which would drop an
# `-only-testing:` identifier that resolves to nothing and still exit 0 — the
# same silent pass `Scripts/check-sanitized-selection.sh` exists for over in
# the sanitizer job.
run_script "run-ui-tests rejects a test method no class declares" \
    "$ui_tests" --device "iPhone 17 Pro" --test testThisWasNeverWritten --dry-run
if expect_status 2 \
    && expect_contains "$output" "Unknown test: testThisWasNeverWritten" "the error" \
    && expect_contains "$output" "Available tests:" "the error" \
    && expect_absent "$calls" "xcodebuild" "the recorded calls"; then
    pass
fi

run_script "run-ui-tests rejects a class the functional list does not carry" \
    "$ui_tests" --device "iPhone 17 Pro" --suite LaunchPerformanceUITests --dry-run
if expect_status 2 \
    && expect_contains "$output" "Unknown suite: LaunchPerformanceUITests" "the error" \
    && expect_contains "$output" "Available suites:" "the error"; then
    pass
fi

# A real class and a real method, but the method belongs to another class. The
# pair is checked rather than each half, or `--suite SettingsUITests --test
# testDiscardingARecordingSavesNothing` would run nothing and say nothing.
run_script "run-ui-tests rejects a test that belongs to another class" \
    "$ui_tests" --device "iPhone 17 Pro" --suite SettingsUITests --test "$recording_test" --dry-run
if expect_status 2 \
    && expect_contains "$output" "Unknown test: SettingsUITests/$recording_test" "the error"; then
    pass
fi

echo "Listing"

# --list is how a contributor finds a name to pass to --test, so it has to
# answer from the same reader --test is checked against. Both read every
# `Suite+Something.swift` extension, not just `Suite.swift`.
run_script "run-ui-tests --list names tests without running anything" \
    "$ui_tests" --list
if expect_status 0 \
    && expect_contains "$output" "RecordingUITests/$recording_test" "the listing" \
    && expect_contains "$output" "SettingsUITests/" "the listing" \
    && expect_absent "$calls" "xcodebuild" "the recorded calls"; then
    pass
fi

run_script "run-ui-tests --list after --suite lists that class alone" \
    "$ui_tests" --suite SettingsUITests --list
if expect_status 0 \
    && expect_contains "$output" "SettingsUITests/" "the listing" \
    && expect_absent "$output" "RecordingUITests/" "the listing"; then
    pass
fi

echo "Second pass and verbose"

# A parallel --all runs twice: the classes across clones, then the pinned
# tests on this one simulator. --dry-run is the mode whose whole job is to say
# what will run, so the second invocation has to be printed too — and it is
# the one that carries the pinned names.
run_script "run-ui-tests --dry-run prints the pinned second pass as well" \
    "$ui_tests" --device "iPhone 17 Pro" --all --dry-run
if expect_status 0 \
    && expect_contains "$output" "-only-testing:$ui_bundle/$pinned_test" "the second invocation" \
    && expect_contains "$output" "-skip-testing:$ui_bundle/$pinned_test" "the first invocation"; then
    printed_invocations="$(printf '%s\n' "$output" | grep -c -- "-retry-tests-on-failure" || true)"
    if [[ "$printed_invocations" == "2" ]]; then
        pass
    else
        fail "printed $printed_invocations invocations, expected 2" "$output"
    fi
fi

# And a serial --all has no second pass to print: the pinned list exists
# because three clones make the machine slow, so with one simulator those
# tests run in the ordinary pass and must not be run twice.
run_script "run-ui-tests --serial --all prints one invocation" \
    "$ui_tests" --device "iPhone 17 Pro" --all --serial --dry-run
if expect_status 0 \
    && expect_absent "$output" "-skip-testing:$ui_bundle/$pinned_test" "the printed invocation" \
    && expect_absent "$output" "-only-testing:$ui_bundle/$pinned_test" "the printed invocation"; then
    pass
fi

# --verbose is what a contributor is told to re-run with when a run fails, so
# what it has to do is let xcodebuild's own output through: the default path
# pipes it into the formatter and keeps the unformatted copy in a temporary
# file nobody is shown.
run_script "run-ui-tests --verbose passes xcodebuild's own output through" \
    "$ui_tests" --device "iPhone 17 Pro" --verbose
if expect_status 0 \
    && expect_contains "$output" "Test Suite 'All tests' passed" "the run output" \
    && expect_contains "$output" "UI tests passed." "the run output"; then
    pass
fi

# The failure path's advice has to be true of the run that failed, not of a
# hypothetical one: a red run says "Re-run with --verbose", and that is only
# advice worth printing if the status it reports is xcodebuild's own.
STUB_XCODEBUILD_STATUS=65 \
    run_script "run-ui-tests --verbose keeps xcodebuild's failing status" \
        "$ui_tests" --device "iPhone 17 Pro" --verbose
if expect_status 65 && expect_contains "$output" "UI tests failed." "the error"; then
    pass
fi

echo "Simulated hike playback"

# Scripts/simulate-hike.sh is the other program that drives a simulator, and
# the only one CI never runs: `ci.yml` parse-checks it and stops there. Its
# validators are what stand between a typo and a playback loop that divides by
# zero, and its `--dry-run` is what a contributor is told to trust before
# touching a device.
simulate_hike="$repository_root/Scripts/simulate-hike.sh"
# Its own route rather than the app's, so these cases do not change answer when
# the bundled GPX is re-recorded. Four points, which is enough to be limited by
# --points and to survive the two-point floor.
route_gpx="$work/route.gpx"
cat > "$route_gpx" <<'GPX'
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="script-tests">
  <trk><trkseg>
    <trkpt lat="47.718420" lon="12.831774"><ele>533.50</ele></trkpt>
    <trkpt lat="47.718500" lon="12.831900"><ele>534.00</ele></trkpt>
    <trkpt lat="47.718600" lon="12.832100"><ele>535.00</ele></trkpt>
    <trkpt lat="47.718700" lon="12.832400"><ele>536.00</ele></trkpt>
  </trkseg></trk>
</gpx>
GPX
one_point_gpx="$work/one-point.gpx"
cat > "$one_point_gpx" <<'GPX'
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="script-tests">
  <trk><trkseg>
    <trkpt lat="47.718420" lon="12.831774"><ele>533.50</ele></trkpt>
  </trkseg></trk>
</gpx>
GPX

run_script "simulate-hike --dry-run summarises without moving the device" \
    "$simulate_hike" start --device "$pro_udid" --route "$route_gpx" --dry-run
if expect_status 0 \
    && expect_contains "$output" "Waypoints: 4" "the summary" \
    && expect_contains "$output" "Playback: 12 m/s, updates every 1 s" "the summary" \
    && expect_absent "$calls" "xcrun simctl location" "the recorded calls"; then
    pass
fi

run_script "simulate-hike --points replays only the first points" \
    "$simulate_hike" start --device "$pro_udid" --route "$route_gpx" --points 2 --dry-run
if expect_status 0 && expect_contains "$output" "Waypoints: 2" "the summary"; then
    pass
fi

# --full is `--points 0`, and the distinction matters: 0 is the only value that
# means the whole track, since 1 is refused and everything else is a ceiling.
run_script "simulate-hike --full replays the whole track" \
    "$simulate_hike" start --device "$pro_udid" --route "$route_gpx" --points 2 --full --dry-run
if expect_status 0 && expect_contains "$output" "Waypoints: 4" "the summary"; then
    pass
fi

run_script "simulate-hike hands the waypoints and the playback options to simctl" \
    "$simulate_hike" start --device "$pro_udid" --route "$route_gpx" --speed 4 --interval 2
if expect_status 0 \
    && expect_contains "$calls" "xcrun simctl location $pro_udid start --speed=4 --interval=2 -" \
        "the recorded calls"; then
    pass
fi

# The zero tests are numeric on purpose: a textual comparison lets "0.0" and
# "00" through, and both divide by zero when the playback loop derives its step.
run_script "simulate-hike refuses a speed of zero" \
    "$simulate_hike" start --device "$pro_udid" --route "$route_gpx" --speed 0.0
if expect_status 2 \
    && expect_contains "$output" "--speed must be a positive number" "the error" \
    && expect_absent "$calls" "xcrun simctl location" "the recorded calls"; then
    pass
fi

run_script "simulate-hike refuses a speed that is not a number" \
    "$simulate_hike" start --device "$pro_udid" --route "$route_gpx" --speed fast
if expect_status 2 && expect_contains "$output" "--speed must be a positive number" "the error"; then
    pass
fi

run_script "simulate-hike refuses an interval of zero" \
    "$simulate_hike" start --device "$pro_udid" --route "$route_gpx" --interval 00
if expect_status 2 && expect_contains "$output" "--interval must be a positive number" "the error"; then
    pass
fi

# One point is the value that reads like a request and cannot be served: the
# floor below is two, and 0 is the whole route.
run_script "simulate-hike refuses a single-point replay" \
    "$simulate_hike" start --device "$pro_udid" --route "$route_gpx" --points 1
if expect_status 2 && expect_contains "$output" "at least 2" "the error"; then
    pass
fi

run_script "simulate-hike refuses a fractional point count" \
    "$simulate_hike" start --device "$pro_udid" --route "$route_gpx" --points 2.5
if expect_status 2 && expect_contains "$output" "--points must be an integer" "the error"; then
    pass
fi

run_script "simulate-hike refuses an option with no value" \
    "$simulate_hike" start --device
if expect_status 2 && expect_contains "$output" "Missing value for --device" "the error"; then
    pass
fi

run_script "simulate-hike refuses an unknown option" \
    "$simulate_hike" start --device "$pro_udid" --backwards
if expect_status 2 && expect_contains "$output" "Unknown option: --backwards" "the error"; then
    pass
fi

run_script "simulate-hike refuses an action it does not have" \
    "$simulate_hike" rewind --device "$pro_udid"
if expect_status 2 && expect_contains "$output" "Unknown action: rewind" "the error"; then
    pass
fi

run_script "simulate-hike reports a route file that is not there" \
    "$simulate_hike" start --device "$pro_udid" --route "$work/no-such-route.gpx"
if expect_status 1 && expect_contains "$output" "GPX route not found" "the error"; then
    pass
fi

# A track with one point parses, summarises and would then ask simctl to
# interpolate between a place and itself.
run_script "simulate-hike refuses a track with one point" \
    "$simulate_hike" start --device "$pro_udid" --route "$one_point_gpx" --dry-run
if expect_status 1 \
    && expect_contains "$output" "at least two track points" "the error" \
    && expect_absent "$calls" "xcrun simctl location" "the recorded calls"; then
    pass
fi

run_script "simulate-hike stop clears the simulated location" \
    "$simulate_hike" stop --device "$pro_udid"
if expect_status 0 \
    && expect_contains "$calls" "xcrun simctl location $pro_udid clear" "the recorded calls" \
    && expect_contains "$output" "Cleared simulated location" "the output"; then
    pass
fi

# The stop path has its own --dry-run branch, above every check the start path
# makes, so it is the one case where a dry run must still say what it would do
# to a device it was never going to touch.
run_script "simulate-hike stop --dry-run touches nothing" \
    "$simulate_hike" stop --device "$pro_udid" --dry-run
if expect_status 0 \
    && expect_contains "$output" "Would clear simulated location on $pro_udid" "the output" \
    && expect_absent "$calls" "xcrun simctl location" "the recorded calls"; then
    pass
fi

run_script "simulate-hike --help prints the usage without touching a device" \
    "$simulate_hike" --help
if expect_status 0 \
    && expect_contains "$output" "Usage: Scripts/simulate-hike.sh" "the help" \
    && expect_absent "$calls" "xcrun simctl location" "the recorded calls"; then
    pass
fi

echo "String catalog order"

# Scripts/lib/sort-string-catalogs.swift rewrites every catalog in the
# repository on each sync, so what it must never do is change one: only whole
# entries move, and each keeps its own text — the IDE's blank line inside an
# empty entry, and the one comma that marks every entry but the last.
catalog_sorter="$repository_root/Scripts/lib/sort-string-catalogs.swift"
catalog_work="$work/catalogs"
mkdir -p "$catalog_work"

# The order `xcstringstool sync` writes: bytes, so both capitals come first
# and the straight apostrophe sorts away from the curly one.
cat > "$catalog_work/byte-order.xcstrings" <<'CATALOG'
{
  "sourceLanguage" : "en",
  "strings" : {
    "Add More Photos" : {

    },
    "Add a photo" : {

    },
    "Couldn't finish" : {

    },
    "Couldn’t Add Photo" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "new",
            "value" : "Couldn’t Add Photo"
          }
        }
      }
    },
    "Delete Photo" : {
      "comment" : "A button"
    },
    "Delete photo" : {

    }
  },
  "version" : "1.1"
}
CATALOG
# The order Xcode's IDE saves the same catalog in.
cat > "$catalog_work/ide-order.xcstrings" <<'CATALOG'
{
  "sourceLanguage" : "en",
  "strings" : {
    "Add a photo" : {

    },
    "Add More Photos" : {

    },
    "Couldn’t Add Photo" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "new",
            "value" : "Couldn’t Add Photo"
          }
        }
      }
    },
    "Couldn't finish" : {

    },
    "Delete photo" : {

    },
    "Delete Photo" : {
      "comment" : "A button"
    }
  },
  "version" : "1.1"
}
CATALOG

cp "$catalog_work/byte-order.xcstrings" "$catalog_work/sorted.xcstrings"
run_script "sort-string-catalogs writes the IDE's order and nothing else" \
    swift "$catalog_sorter" "$catalog_work/sorted.xcstrings"
if expect_status 0; then
    if cmp -s "$catalog_work/sorted.xcstrings" "$catalog_work/ide-order.xcstrings"; then
        pass
    else
        fail "the sorted catalog is not the IDE's" \
            "$(diff "$catalog_work/ide-order.xcstrings" "$catalog_work/sorted.xcstrings" || true)"
    fi
fi

cp "$catalog_work/ide-order.xcstrings" "$catalog_work/already.xcstrings"
run_script "sort-string-catalogs leaves a catalog in the IDE's order as it was" \
    swift "$catalog_sorter" "$catalog_work/already.xcstrings"
if expect_status 0; then
    if cmp -s "$catalog_work/already.xcstrings" "$catalog_work/ide-order.xcstrings"; then
        pass
    else
        fail "a sorted catalog was rewritten" \
            "$(diff "$catalog_work/ide-order.xcstrings" "$catalog_work/already.xcstrings" || true)"
    fi
fi

# Two spaces short on its entries, as a hand edit or another tool might leave
# it: not the layout this reads, so it must be refused rather than reshuffled.
sed 's/^    /  /' "$catalog_work/byte-order.xcstrings" > "$catalog_work/unexpected.xcstrings"
cp "$catalog_work/unexpected.xcstrings" "$catalog_work/unexpected-before.xcstrings"
run_script "sort-string-catalogs refuses a layout it does not read and writes nothing" \
    swift "$catalog_sorter" "$catalog_work/unexpected.xcstrings"
if expect_status 1 && expect_contains "$output" "error:" "the output"; then
    if cmp -s "$catalog_work/unexpected.xcstrings" "$catalog_work/unexpected-before.xcstrings"; then
        pass
    else
        fail "the refused catalog was rewritten anyway"
    fi
fi

echo "App Store screenshots"

# Scripts/screenshots-light.sh and -dark.sh are run by hand, never by CI, and
# what they decide is invisible until a frame comes out wrong: which frames
# get the location grant, and whether the grant lands after the install that
# would otherwise discard it. The stubbed xcodebuild writes no result bundle,
# so every frame a case asks for comes out "not shot" — which is also what
# exercises the retry.
screenshots_light="$repository_root/Scripts/screenshots-light.sh"
screenshots_dark="$repository_root/Scripts/screenshots-dark.sh"
screens_dd="$work/screens-dd"
mkdir -p "$screens_dd/Build/Products/Debug-iphonesimulator/OpenHikes.app" "$work/screens-out"
export STUB_DEVICES="$work/devices-two-booted.txt"

# The line of the first recorded call containing `needle`, or 0.
call_line() {
    local line
    line="$(printf '%s\n' "$calls" | grep -nF -- "$1" | head -1 | cut -d: -f1)"
    printf '%s\n' "${line:-0}"
}

run_script "screenshots refuses a frame it does not know, before touching a device" \
    "$screenshots_light" --frame 12 --device "$pro_udid"
if expect_status 2 \
    && expect_contains "$output" "Unknown frame: 12" "the error" \
    && expect_absent "$calls" "simctl erase" "the recorded calls"; then
    pass
fi

run_script "screenshots grants location to a location frame, after the install" \
    "$screenshots_dark" --frame 3 --no-photos --no-retry --device "$pro_udid" \
    --derived-data "$screens_dd" --output "$work/screens-out"
install_at="$(call_line "simctl install $pro_udid")"
grant_at="$(call_line "simctl privacy $pro_udid grant location-always")"
test_at="$(call_line "xcodebuild test-without-building")"
if expect_status 1 \
    && expect_contains "$output" "FAILED — not shot: 03" "the output" \
    && expect_contains "$calls" "simctl ui $pro_udid appearance dark" "the recorded calls" \
    && expect_contains "$calls" "-only-testing:OpenHikesUITests/ScreenshotUITests/testCapturesNearbyTrails" \
        "the recorded calls" \
    && expect_absent "$calls" "reset location" "the recorded calls"; then
    if (( install_at > 0 && install_at < grant_at && grant_at < test_at )); then
        pass
    else
        fail "expected install, then grant, then test — got lines $install_at, $grant_at, $test_at" "$calls"
    fi
fi

run_script "screenshots shoots map frames without location, and retries only what did not come out" \
    "$screenshots_light" --frame 4 --frame 3 --no-photos --device "$pro_udid" \
    --derived-data "$screens_dd" --output "$work/screens-out"
reset_at="$(call_line "simctl privacy $pro_udid reset location")"
plain_at="$(call_line "testCapturesStatisticsAndProfile")"
grant_at="$(call_line "simctl privacy $pro_udid grant location-always")"
located_at="$(call_line "testCapturesNearbyTrails")"
runs="$(printf '%s\n' "$calls" | grep -c "xcodebuild test-without-building" || true)"
if expect_status 1 \
    && expect_contains "$output" "not shot: 04 03 — retrying those once" "the output" \
    && expect_contains "$calls" "simctl ui $pro_udid appearance light" "the recorded calls"; then
    if (( reset_at > 0 && reset_at < plain_at && plain_at < grant_at && grant_at < located_at )) \
        && [[ "$runs" == 4 ]]; then
        pass
    else
        fail "expected reset, map frame, grant, location frame, and four runs — got lines" \
            "$reset_at $plain_at $grant_at $located_at, $runs run(s)"
    fi
fi

run_script "screenshots skips the library frames when there is no library" \
    "$screenshots_light" --frame 1 --no-photos --device "$pro_udid" \
    --derived-data "$screens_dd" --output "$work/screens-out"
if expect_status 0 \
    && expect_contains "$output" "nothing left to shoot" "the output" \
    && expect_absent "$calls" "xcodebuild" "the recorded calls"; then
    pass
fi

echo
if (( failures > 0 )); then
    echo "$failures case(s) failed." >&2
    exit 1
fi
echo "All script smoke tests passed."
