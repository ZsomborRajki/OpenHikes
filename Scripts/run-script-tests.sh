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
# check-coverage-floor.sh can fail the workflow, and Scripts/
# check-sanitized-selection.sh is the only thing that would notice a sanitized
# suite that silently did not run — `xcodebuild` drops an `-only-testing:`
# identifier that resolves to nothing without a warning and still exits 0.
# Scripts/check-release-secrets.sh is the archive checklist's second step, and
# the mistake it catches is the silent one: a template copied into place and
# not filled in parses, resolves to nothing, and reads exactly like a working
# file. They run against fixtures written here rather than against a stub.
# So does Scripts/lib/sort-string-catalogs.swift, which rewrites every String
# Catalog in the repository on each sync and must only ever reorder one, and
# Scripts/lib/fit-screenshot.swift, which rewrites every App Store frame and
# must never write one back on its side.
# Scripts/sim-pool.sh is here because what it decides — which device a session
# lands on, and whether that device is erased first — is invisible until two
# sessions' tests collide on one simulator or somebody's device is wiped.
# Scripts/render-trace.sh is here for what its report concludes: Scripts/lib/
# render-trace-report.swift turns Instruments' tables into claims about which
# view ran its body in which step of which test, and why, and a table misread
# is a confident wrong answer about the render path rather than an error.
#
# `xcrun`, `xcodebuild`, `swiftlint`, `periphery` and `hinge` are replaced
# with recording stubs on PATH and the scripts are run for real against them.
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
xcrun/xcodebuild/swiftlint/periphery/hinge and asserts what they sent where.

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
# STUB_CREATED_UDID, when set, is what `simctl create` answers, and the device
# it made is appended to the fixture — under its last runtime, so a fixture
# that should grow ends with an iOS one. STUB_CLONED_UDID is the same for
# `simctl clone`. `delete` and `rename` edit the fixture as the real ones edit
# the machine, and `list runtimes` answers from STUB_RUNTIMES.
export STUB_REAL_SWIFT="$(xcrun --find swift)"
export STUB_REAL_MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
cat > "$stub_bin/xcrun" <<'STUB'
#!/usr/bin/env bash
printf 'xcrun %s\n' "$*" >> "$STUB_CALL_LOG"
if [[ "${1:-} ${2:-}" == "--find swift" ]]; then
    printf '%s\n' "$STUB_REAL_SWIFT"
    exit 0
fi
if [[ "${1:-} ${2:-} ${3:-}" == "--sdk macosx --show-sdk-path" ]]; then
    printf '%s\n' "$STUB_REAL_MACOS_SDK"
    exit 0
fi
if [[ "${1:-}" == "swiftc" ]]; then
    [[ -z "${STUB_SHARED_EXTRACTION_FAIL:-}" ]] || exit 17
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "-emit-localized-strings-path" ]]; then
            : > "$2/SharedTargetStrings.stringsdata"
            break
        fi
        shift
    done
    exit 0
fi
if [[ -n "${STUB_SCREENSHOT_RESULTS:-}" ]]; then
    case "$*" in
        "xcresulttool get test-results tests"*) cat "$STUB_SCREENSHOT_RESULTS"; exit 0 ;;
        "xcresulttool export attachments"*)
            while [[ $# -gt 0 ]]; do
                if [[ "$1" == --output-path ]]; then
                    mkdir -p "$2"
                    cp "$STUB_SCREENSHOT_ATTACHMENTS"/* "$2/"
                    exit 0
                fi
                shift
            done
            ;;
    esac
fi
# A recording, read back: `xctrace export` and `xcresulttool` answer from the
# fixture files in STUB_TRACE_DIR, the table of contents or whichever table
# the export names.
if [[ -n "${STUB_TRACE_DIR:-}" ]]; then
    case "$*" in
        "xctrace export"*"--toc"*) cat "$STUB_TRACE_DIR/toc.xml" ;;
        "xctrace export"*"swiftui-body-interval"*) cat "$STUB_TRACE_DIR/bodies.xml" ;;
        "xctrace export"*"swiftui-link-event"*) cat "$STUB_TRACE_DIR/properties.xml" ;;
        "xctrace export"*"kdebug"*) cat "$STUB_TRACE_DIR/kdebug.xml" ;;
        "xctrace export"*"os-signpost"*) cat "$STUB_TRACE_DIR/os-signpost.xml" ;;
        "xcresulttool get test-results tests"*) cat "$STUB_TRACE_DIR/tests.json" ;;
        "xcresulttool get test-results activities"*) cat "$STUB_TRACE_DIR/activities.json" ;;
    esac
fi
# `xcstringstool sync <catalog> …` leaves the catalog as it found it, the way a
# sync of one already current does; with STUB_CATALOG_BEHIND set it adds an
# entry the source would have extracted, the way a sync of one that is behind
# does.
if [[ "${1:-}" == "xcstringstool" && "${2:-}" == "sync" && -n "${STUB_CATALOG_BEHIND:-}" ]]; then
    sed -i '' '/^  "strings" : {$/a\
    "A string the catalog lacks" : {\
\
    },
' "$3"
fi
# `devicectl device info displays` answers from STUB_DISPLAYS, the state of an
# iPhone Duo's two displays; unset, it answers nothing, the way a device with
# no display list does.
if [[ "${1:-} ${2:-} ${3:-} ${4:-}" == "devicectl device info displays" && -n "${STUB_DISPLAYS:-}" ]]; then
    cat "$STUB_DISPLAYS"
fi
[[ "${1:-}" == "simctl" ]] || exit 0
shift
case "${1:-}" in
    list)
        if [[ "${2:-}" == "runtimes" ]]; then
            cat "${STUB_RUNTIMES:-/dev/null}"
        else
            cat "$STUB_DEVICES"
        fi
        ;;
    create)
        if [[ -n "${STUB_CREATED_UDID:-}" ]]; then
            printf '    %s (%s) (Shutdown) \n' "$2" "$STUB_CREATED_UDID" >> "$STUB_DEVICES"
            printf '%s\n' "$STUB_CREATED_UDID"
        fi
        ;;
    clone)
        if [[ -n "${STUB_CLONED_UDID:-}" ]]; then
            printf '    %s (%s) (Shutdown) \n' "$3" "$STUB_CLONED_UDID" >> "$STUB_DEVICES"
            printf '%s\n' "$STUB_CLONED_UDID"
        fi
        ;;
    delete)
        grep -vF "($2)" "$STUB_DEVICES" > "$STUB_DEVICES.next" || true
        mv "$STUB_DEVICES.next" "$STUB_DEVICES"
        ;;
    rename)
        while IFS= read -r line; do
            if [[ "$line" == *"($2)"* ]]; then
                state="${line##*(}"
                printf '    %s (%s) (%s \n' "$3" "$2" "$state"
            else
                printf '%s\n' "$line"
            fi
        done < "$STUB_DEVICES" > "$STUB_DEVICES.next"
        mv "$STUB_DEVICES.next" "$STUB_DEVICES"
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
if [[ "${1:-}" == test-without-building ]]; then
    if [[ -n "${STUB_SCREENSHOT_RESULTS:-}" ]]; then
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == -resultBundlePath ]]; then mkdir -p "$2"; break; fi
            shift
        done
    fi
    exit "${STUB_XCODEBUILD_TEST_STATUS:-${STUB_XCODEBUILD_STATUS:-0}}"
fi
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

# Records every hinge invocation. `hinge -v` answers with STUB_HINGE_VERSION,
# the oldest release Scripts/lib/hinge.sh accepts unless a case says otherwise. With
# STUB_HINGE_ANGLE_FAILS set, a `set` that waits for the angle fails the way
# hinge's does when the angle never arrives, and one sent unconfirmed (`-t 0`)
# still goes out, as hinge's does. A machine without hinge is OPENHIKES_HINGE
# naming a path where there is none.
cat > "$stub_bin/hinge" <<'STUB'
#!/usr/bin/env bash
printf 'hinge %s\n' "$*" >> "$STUB_CALL_LOG"
if [[ "${1:-}" == "-v" ]]; then
    printf '%s\n' "$STUB_HINGE_VERSION"
    exit 0
fi
for degrees; do :; done
if [[ " $* " == *" set "* && " $* " != *" -t 0 "* && -n "${STUB_HINGE_ANGLE_FAILS:-}" ]]; then
    echo "hinge_helper: the hinge angle did not reach $degrees.0 within 1.0 s" >&2
    exit 1
fi
STUB

chmod +x "$stub_bin"/*
export STUB_HINGE_VERSION="$(source "$repository_root/Scripts/lib/hinge.sh" && printf '%s\n' "$oldest_hinge")"

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
    # a machine that has it and one that does not. SIGPIPE is ignored, as in
    # every step a GitHub runner starts: the runner is a .NET process, .NET
    # ignores the signal, and a child keeps an ignored signal across exec. So a
    # script that hangs there once a reader leaves a pipe early hangs here too,
    # rather than in CI alone, as Scripts/duo-pose.sh's display list did.
    output="$(trap '' PIPE; PATH="$stub_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$@" 2>&1)" || status=$?
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
# The same for simulator templates: their settled markers and lock, and the
# device directories whose asset tables Scripts/lib/simulator-templates.sh
# reads to decide that a template has settled.
export OPENHIKES_SIM_TEMPLATE_DIR="$work/sim-templates"
export OPENHIKES_SIM_DEVICES_DIR="$work/sim-devices"
export OPENHIKES_SIM_POOL_DIR="$work/sim-pool"
# A template with nothing to download counts as settled at once, rather than
# after the minute of quiet a real one is given.
export OPENHIKES_SIM_TEMPLATE_IDLE_SECONDS=0
cat > "$work/runtimes.json" <<'EOF'
{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0"},{"identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-27-0"}]}
EOF
export STUB_RUNTIMES="$work/runtimes.json"

# Writes the table `mobileassetd` keeps of its download jobs under way, with
# that many jobs in it, for the device with this UDID.
asset_jobs_table() {
    local directory="$OPENHIKES_SIM_DEVICES_DIR/$1/data/private/var/MobileAsset/AssetsV2/persisted/AutoSetActiveJobDescriptors"
    local entries="" job
    for (( job = 0; job < $2; job++ )); do entries+="<string>job $job</string>"; done
    mkdir -p "$directory"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>SUCorePersistedStatePolicyFields</key><dict><key>currentEntries</key><array>%s</array></dict></dict></plist>\n' \
        "$entries" > "$directory/AutoSetActiveJobDescriptors_TableOfContents.state"
}

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
    && expect_contains "$output" "-parallel-testing-worker-count 4" "the printed invocation" \
    && expect_contains "$output" "Workers: 4 simulator clones" "the printed summary"; then
    pass
fi

# Every invocation skips the end-of-run sysdiagnose, which hangs to its 600s
# timeout on Xcode 27. Both passes of a parallel --all, and the --suite shape CI
# runs: a pass left out keeps paying ten minutes for nothing.
run_script "run-ui-tests skips test diagnostics in both passes" \
    "$ui_tests" --device "iPhone 17 Pro" --all --dry-run
printed_diagnostics="$(printf '%s\n' "$output" | grep -c -- "-collect-test-diagnostics never" || true)"
if expect_status 0; then
    if [[ "$printed_diagnostics" == 2 ]]; then
        pass
    else
        fail "printed -collect-test-diagnostics never $printed_diagnostics times, expected 2" "$output"
    fi
fi

run_script "run-ui-tests skips test diagnostics for a CI suite run" \
    "$ui_tests" --device "iPhone 17 Pro" --suite AccessibilityUITests --all --retry --dry-run
if expect_status 0 \
    && expect_contains "$output" "-collect-test-diagnostics never" "the printed invocation"; then
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
    && expect_contains "$output" "-parallel-testing-worker-count 4" "the printed invocation" \
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
# The pin, asked of the script that reads it out of Package.resolved.
export STUB_SWIFTLINT_VERSION="$("$lint" --pinned-version)"
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

# The version comes out of Package.resolved, from SwiftLintPlugins' pin among
# the others, and CI's install step asks for it this way before any SwiftLint
# is installed. The project's own file is the fixture: it is the one Dependabot
# edits, and it pins four packages besides the plugin. The answer expected of
# it is read here by a second route, a text scan rather than a key path, so the
# case holds whichever versions the file pins today.
swiftlint_resolved="$repository_root/OpenHikes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
expected_pin="$(awk '/"identity" *: *"swiftlintplugins"/ { found = 1 }
    found && /"version" *:/ { gsub(/[^0-9.]/, ""); print; exit }' "$swiftlint_resolved")"
run_script "lint --pinned-version reads SwiftLintPlugins' pin out of Package.resolved" \
    "$lint" --pinned-version
if expect_status 0 && expect_absent "$calls" "swiftlint" "the recorded calls"; then
    if [[ -n "$expected_pin" && "$output" == "$expected_pin" ]]; then
        pass
    else
        fail "expected SwiftLintPlugins' pin, ${expected_pin:-which Package.resolved does not name}" \
            "$output"
    fi
fi

# Without a SwiftLintPlugins pin there is no version to lint at, and that is a
# lint that could not run rather than a clean one. The fixture is the same file
# with the plugin's identity renamed, so every other pin is still in it.
sed 's/"swiftlintplugins"/"renamed-plugin"/' "$swiftlint_resolved" \
    > "$work/resolved-without-swiftlint.json"
OPENHIKES_SWIFTLINT_RESOLVED="$work/resolved-without-swiftlint.json" \
    run_script "lint refuses to run without a SwiftLintPlugins pin" "$lint"
if expect_status 1 \
    && expect_contains "$output" "pins no version of SwiftLintPlugins" "the error" \
    && expect_absent "$calls" "swiftlint lint" "the recorded calls"; then
    pass
fi

run_script "lint --pinned-version takes no --fix" "$lint" --pinned-version --fix
if expect_status 2 && expect_absent "$calls" "swiftlint" "the recorded calls"; then
    pass
fi

# The verdict has to name the version that ran. Crediting it to the pin tells a
# reader a clean run happened at the version CI will use when it did not, and
# the drift warning printed just above says in so many words that the two
# versions do not agree on the rules.
pinned_version="$("$lint" --pinned-version)"
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
# The pin, read out of the script that holds it.
periphery_pin="$(sed -n 's/^pinned="\(.*\)"$/\1/p' "$periphery")"
export STUB_PERIPHERY_VERSION="$periphery_pin"
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
export STUB_PERIPHERY_VERSION="$periphery_pin"

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

# --all runs the classes named in the script's `suites` list and no others, so
# a class written and never added to it is a class --all never runs — with a
# green summary, since nothing it did not select can fail. Three sat outside it
# unnoticed. Every `XCTestCase` in the bundle has to be in the invocation --all
# prints, bar `ScreenshotUITests`, which the screenshot scripts run instead.
run_script "run-ui-tests --all selects every UI test class" \
    "$ui_tests" --device "iPhone 17 Pro" --all --serial --dry-run
if expect_status 0; then
    unselected=()
    while read -r class; do
        [[ "$class" == "ScreenshotUITests" ]] && continue
        [[ "$output" == *"-only-testing:$ui_bundle/$class "* ]] || unselected+=("$class")
    done < <(grep -rhoE 'class [A-Za-z0-9_]+: XCTestCase' "$repository_root/$ui_bundle" \
        | sed -E 's/^class ([A-Za-z0-9_]+):.*/\1/' | sort -u)
    if (( ${#unselected[@]} == 0 )); then
        pass
    else
        fail "--all does not select ${unselected[*]}; add them to \`suites\` in Scripts/run-ui-tests.sh" "$output"
    fi
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
# because the clones make the machine slow, so with one simulator those
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

echo "String catalog check"

# Scripts/sync-string-catalogs.sh --check checks the compiler's extraction,
# and CI runs it after the build: a catalog that is
# behind the source must be the exit status, not a message nobody reads. The
# stubbed xcstringstool stands in for the sync; the derived data is a folder of
# empty .stringsdata files, one per target, because the script only needs to
# find them.
catalog_check="$repository_root/Scripts/sync-string-catalogs.sh"
catalog_dd="$work/catalog-dd"
for target in OpenHikes OpenWidgetExtension OpenHikesWatch OpenHikesWatchWidgets; do
    target_dir="$catalog_dd/Build/Intermediates.noindex/OpenHikes.build/Debug-iphonesimulator/$target.build"
    mkdir -p "$target_dir"
    : > "$target_dir/Example.stringsdata"
done

unset STUB_CATALOG_BEHIND || true
catalog_hashes_before="$(shasum -a 256 \
    "$repository_root"/{OpenHikes,OpenWidget,OpenHikesWatch,OpenHikesWatchWidgets}/Localizable.xcstrings)"
run_script "sync-string-catalogs --check passes when every catalog is current" \
    "$catalog_check" --check "$catalog_dd"
if expect_status 0 \
    && expect_contains "$output" "current OpenHikes/Localizable.xcstrings" "the output" \
    && expect_contains "$calls" "swiftc -c -emit-localized-strings" "the shared extraction" \
    && expect_contains "$calls" "SharedTargetStrings.stringsdata" "the shared strings passed to sync"; then
    pass
fi

STUB_CATALOG_BEHIND=1 run_script "sync-string-catalogs --check exits 2 and names a catalog that is behind" \
    "$catalog_check" --check "$catalog_dd"
if expect_status 2 && expect_contains "$output" "OpenHikes/Localizable.xcstrings is out of date" "the output"; then
    pass
fi

run_script "sync-string-catalogs --check changes no catalog in the checkout" \
    shasum -a 256 \
    "$repository_root"/{OpenHikes,OpenWidget,OpenHikesWatch,OpenHikesWatchWidgets}/Localizable.xcstrings
if expect_status 0; then
    if [[ "$output" == "$catalog_hashes_before" ]]; then pass
    else fail "a catalog changed during --check"; fi
fi

STUB_SHARED_EXTRACTION_FAIL=1 run_script "sync refuses a failed shared extraction" \
    "$catalog_check" --check "$catalog_dd"
if expect_status 1 \
    && expect_contains "$output" "shared localized strings could not be extracted" "the error" \
    && expect_absent "$calls" "xcstringstool sync" "the rejected sync"; then
    pass
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
    "$screenshots_light" --frame 7 --frame 3 --no-photos --device "$pro_udid" \
    --derived-data "$screens_dd" --output "$work/screens-out"
reset_at="$(call_line "simctl privacy $pro_udid reset location")"
plain_at="$(call_line "testCapturesWalkHistory")"
grant_at="$(call_line "simctl privacy $pro_udid grant location-always")"
located_at="$(call_line "testCapturesNearbyTrails")"
runs="$(printf '%s\n' "$calls" | grep -c "xcodebuild test-without-building" || true)"
if expect_status 1 \
    && expect_contains "$output" "not shot: 07 03 — retrying those once" "the output" \
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

run_script "screenshots refuses unsupported dimensions before preparing or building" \
    "$screenshots_dark" --frame 3 --device-type 'iPhone 18 Pro'
if expect_status 2 \
    && expect_contains "$output" "Unsupported screenshot device type" "the error" \
    && expect_absent "$calls" "simctl" "the recorded calls" \
    && expect_absent "$calls" "xcodebuild" "the recorded calls"; then
    pass
fi

screens_prepared="$work/devices-screens-prepared.txt"
screens_template_udid="EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
cat > "$screens_prepared" <<EOF
== Devices ==
-- iOS 27.0 --
    OpenHikes Pool 1 ($pro_udid) (Booted)
    OpenHikes Template (iPhone 18 Pro Max, iOS 27.0) ($screens_template_udid) (Shutdown)
EOF
mkdir -p "$OPENHIKES_SIM_POOL_DIR" "$OPENHIKES_SIM_DEVICES_DIR/$pro_udid"
printf 'owner=screenshot-tests\npid=\nstarted=\nclaimed=0\n' > "$OPENHIKES_SIM_POOL_DIR/$pro_udid.claim"
printf '{"deviceType":"com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max"}' \
    > "$OPENHIKES_SIM_DEVICES_DIR/$pro_udid/device.plist"
export STUB_DEVICES="$screens_prepared"

run_script "screenshots uses an acquired pool device without erasing it" \
    "$screenshots_light" --frame 7 --no-photos --no-retry --prepared-device "$pro_udid" \
    --pool-owner screenshot-tests --derived-data "$screens_dd" --output "$work/screens-out"
if expect_status 1 \
    && expect_contains "$calls" "simctl bootstatus $pro_udid -b" "the recorded calls" \
    && expect_contains "$calls" "simctl ui $pro_udid appearance light" "the recorded calls" \
    && expect_contains "$calls" "-skipPackagePluginValidation" "the recorded calls" \
    && expect_absent "$calls" "simctl erase" "the recorded calls" \
    && expect_absent "$calls" "simctl shutdown" "the recorded calls" \
    && expect_absent "$calls" "simctl clone" "the recorded calls"; then
    pass
fi

run_script "screenshots refuses a template as a prepared device" \
    "$screenshots_light" --prepared-device "$screens_template_udid" --pool-owner screenshot-tests
if expect_status 2 \
    && expect_contains "$output" "is not a device in the" "the error" \
    && expect_absent "$calls" "simctl bootstatus" "the recorded calls"; then pass; fi

run_script "screenshots refuses another owner's prepared device" \
    "$screenshots_light" --prepared-device "$pro_udid" --pool-owner another-session
if expect_status 2 \
    && expect_contains "$output" "needs an active pool claim" "the error" \
    && expect_absent "$calls" "simctl bootstatus" "the recorded calls"; then pass; fi

run_script "screenshots refuses a prepared device with the wrong type" \
    "$screenshots_light" --prepared-device "$pro_udid" --device-type 'iPhone Duo' --pool-owner screenshot-tests
if expect_status 2 \
    && expect_contains "$output" "expected iPhone Duo" "the error" \
    && expect_absent "$calls" "simctl bootstatus" "the recorded calls"; then pass; fi

printf 'owner=screenshot-tests\nreleased=1\n' > "$OPENHIKES_SIM_POOL_DIR/$pro_udid.claim"
run_script "screenshots refuses a released pool claim" \
    "$screenshots_light" --prepared-device "$pro_udid" --pool-owner screenshot-tests
if expect_status 2 \
    && expect_contains "$output" "needs an active pool claim" "the error" \
    && expect_absent "$calls" "simctl bootstatus" "the recorded calls"; then pass; fi
printf 'owner=screenshot-tests\npid=\nstarted=\nclaimed=0\n' > "$OPENHIKES_SIM_POOL_DIR/$pro_udid.claim"

run_script "screenshots refuses a prepared device that is not a UDID" \
    "$screenshots_light" --prepared-device 'OpenHikes Pool 1'
if expect_status 2 \
    && expect_contains "$output" "--prepared-device needs a pool device’s UDID" "the error"; then
    pass
fi

run_script "screenshots requires separate prepared libraries for the two appearances" \
    "$repository_root/Scripts/screenshots.sh" --prepared-device "$pro_udid"
if expect_status 2 \
    && expect_contains "$output" "separate fresh pool claims" "the error" \
    && expect_absent "$calls" "simctl" "the recorded calls"; then
    pass
fi

run_script "screenshots refuses an unavailable prepared device before changing a simulator" \
    "$screenshots_light" --prepared-device FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF
if expect_status 2 \
    && expect_contains "$output" "No available prepared iOS simulator" "the error" \
    && expect_absent "$calls" "simctl bootstatus" "the recorded calls" \
    && expect_absent "$calls" "simctl erase" "the recorded calls"; then
    pass
fi

run_script "screenshots selects a repeated frame only once" \
    "$screenshots_light" --frame 7 --frame 07 --no-photos --no-retry --prepared-device "$pro_udid" \
    --pool-owner screenshot-tests --derived-data "$screens_dd" --output "$work/screens-out"
selections="$(printf '%s\n' "$calls" | grep -o 'only-testing:OpenHikesUITests/ScreenshotUITests/testCapturesWalkHistory' \
    | wc -l | tr -d ' ')"
if expect_status 1; then
    if [[ "$selections" == 1 ]]; then pass; else fail "selected the repeated frame $selections times" "$calls"; fi
fi

STUB_XCODEBUILD_TEST_STATUS=65 \
    run_script "screenshots rejects a failed process even when its summary says passed" \
    "$screenshots_light" --frame 7 --no-photos --no-retry --prepared-device "$pro_udid" \
    --pool-owner screenshot-tests --derived-data "$screens_dd" --output "$work/screens-out"
if expect_status 1 \
    && expect_contains "$output" "failed (xcodebuild 65, log 0)" "the error" \
    && expect_absent "$calls" "xcresulttool export attachments" "the recorded calls"; then
    pass
fi
export STUB_DEVICES="$work/devices-two-booted.txt"

# A device named rather than given by UDID is the harness's own, and it starts
# clean as a clone of a settled template instead of an erase, which would
# download its models again on the next boot. The template does not exist
# yet, so the run settles one first; the cases above, which pass a UDID, are
# the ones that still erase.
screens_old="C0000000-0000-4000-8000-000000000001"
screens_template="C0000000-0000-4000-8000-000000000002"
screens_clone="C0000000-0000-4000-8000-000000000003"
cat > "$work/devices-screens.txt" <<EOF
== Devices ==
-- iOS 27.0 --
    OpenHikes Screenshots Test ($screens_old) (Shutdown)
EOF
asset_jobs_table "$screens_template" 0
STUB_DEVICES="$work/devices-screens.txt" \
STUB_CREATED_UDID="$screens_template" STUB_CLONED_UDID="$screens_clone" \
    run_script "screenshots starts a named device clean as a clone of its template" \
    "$screenshots_light" --frame 1 --no-photos --device "OpenHikes Screenshots Test" \
    --derived-data "$screens_dd" --output "$work/screens-out"
template_name="OpenHikes Template (iPhone 18 Pro Max, iOS 27.0)"
if expect_status 0 \
    && expect_contains "$calls" \
        "simctl create $template_name iPhone 18 Pro Max com.apple.CoreSimulator.SimRuntime.iOS-27-0" \
        "the recorded calls" \
    && expect_contains "$calls" "simctl clone $screens_template OpenHikes Screenshots Test (replacing)" \
        "the recorded calls" \
    && expect_contains "$calls" "simctl delete $screens_old" "the recorded calls" \
    && expect_contains "$calls" "simctl rename $screens_clone OpenHikes Screenshots Test" "the recorded calls" \
    && expect_contains "$calls" "simctl ui $screens_clone appearance light" "the recorded calls" \
    && expect_contains "$output" "Simulator: OpenHikes Screenshots Test ($screens_clone)" "the output" \
    && expect_absent "$calls" "simctl erase" "the recorded calls"; then
    pass
fi

# Xcode 27.1 installs an iOS 27.1 runtime that runs the iPhone Duo and
# nothing else, beside the 27.0 that runs the iPhone 18s. The newest runtime
# is therefore the wrong one for the 6.9" device, and building its template on
# it failed — and fell back to an erase. Each device type gets the newest
# runtime that lists it.
cat > "$work/runtimes-duo.json" <<'EOF'
{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","supportedDeviceTypes":[{"name":"iPhone 18 Pro"},{"name":"iPhone 18 Pro Max"}]},{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-1","supportedDeviceTypes":[{"name":"iPhone Duo"}]},{"identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-27-0","supportedDeviceTypes":[{"name":"Apple Watch Ultra 4 (49mm)"}]}]}
EOF
cat > "$work/devices-screens.txt" <<EOF
== Devices ==
-- iOS 27.0 --
    OpenHikes Screenshots Test ($screens_old) (Shutdown)
EOF
rm -rf "$OPENHIKES_SIM_TEMPLATE_DIR"
STUB_RUNTIMES="$work/runtimes-duo.json" STUB_DEVICES="$work/devices-screens.txt" \
STUB_CREATED_UDID="$screens_template" STUB_CLONED_UDID="$screens_clone" \
    run_script "screenshots builds its template on the newest runtime that runs the device" \
    "$screenshots_light" --frame 1 --no-photos --device "OpenHikes Screenshots Test" \
    --derived-data "$screens_dd" --output "$work/screens-out"
if expect_status 0 \
    && expect_contains "$calls" \
        "simctl create $template_name iPhone 18 Pro Max com.apple.CoreSimulator.SimRuntime.iOS-27-0" \
        "the recorded calls" \
    && expect_absent "$calls" "iOS-27-1" "the recorded calls"; then
    pass
fi

cat > "$work/devices-screens.txt" <<EOF
== Devices ==
-- iOS 27.1 --
    OpenHikes Screenshots Test ($screens_old) (Shutdown)
EOF
rm -rf "$OPENHIKES_SIM_TEMPLATE_DIR"
STUB_RUNTIMES="$work/runtimes-duo.json" STUB_DEVICES="$work/devices-screens.txt" \
STUB_CREATED_UDID="$screens_template" STUB_CLONED_UDID="$screens_clone" \
    run_script "screenshots builds an iPhone Duo's template on the runtime that runs one" \
    "$screenshots_light" --frame 1 --no-photos --device "OpenHikes Screenshots Test" \
    --device-type "iPhone Duo" --derived-data "$screens_dd" --output "$work/screens-out"
if expect_status 0 \
    && expect_contains "$calls" \
        "simctl create OpenHikes Template (iPhone Duo, iOS 27.1) iPhone Duo com.apple.CoreSimulator.SimRuntime.iOS-27-1" \
        "the recorded calls"; then
    pass
fi

run_script "screenshots refuses a pose it does not know, before touching a device" \
    "$screenshots_light" --pose ajar --device "$pro_udid"
if expect_status 2 \
    && expect_contains "$output" "Unknown pose: ajar" "the error" \
    && expect_absent "$calls" "simctl erase" "the recorded calls"; then
    pass
fi

run_script "screenshots refuses an orientation for any pose but open, before touching a device" \
    "$screenshots_light" --pose closed --orientation landscape --device "$pro_udid"
if expect_status 2 \
    && expect_contains "$output" "--orientation needs --pose open" "the error" \
    && expect_absent "$calls" "simctl erase" "the recorded calls"; then
    pass
fi

# The stubbed devicectl lists no displays unless a case gives it some, which is
# what a phone looks like to Scripts/duo-pose.sh — and a pose that cannot be
# taken must stop the run before a set is shot on the wrong display.
run_script "screenshots stops before building when the device cannot take the pose" \
    "$screenshots_light" --frame 7 --pose open --no-photos --device "$pro_udid" \
    --derived-data "$screens_dd" --output "$work/screens-out"
if expect_status 1 \
    && expect_contains "$output" "it is not an iPhone Duo" "the output" \
    && expect_absent "$calls" "xcodebuild" "the recorded calls"; then
    pass
fi

echo
echo "iPhone Duo pose"

# Scripts/duo-pose.sh has hinge post a private HID event from inside the
# simulator and reads the display state back, and the second half is what
# these pin: a fold that did not happen must be an error, and the error must
# say whether the angle or the display is what failed. The stubbed hinge
# records what it is asked, so nothing here builds or spawns anything real.
duo_pose="$repository_root/Scripts/duo-pose.sh"
export OPENHIKES_DUO_POSE_SETTLE_SECONDS=1
export OPENHIKES_DUO_POSE_TURN_SECONDS=1
export STUB_DEVICES="$work/devices-two-booted.txt"
duo_displays() {
    printf '{"result":{"displays":[%s,%s]}}\n' \
        "{\"name\":\"LCD\",\"displayId\":1,\"primary\":true,\"active\":$1,\"currentOrientation\":\"$3\"}" \
        "{\"name\":\"LCD-1\",\"displayId\":3,\"primary\":false,\"active\":$2,\"currentOrientation\":\"$3\"}"
}

run_script "duo-pose refuses to guess a device" "$duo_pose" open
if expect_status 2 && expect_contains "$output" "--device is required" "the error"; then
    pass
fi

run_script "duo-pose refuses an orientation it does not know" \
    "$duo_pose" open --device "$pro_udid" --orientation sideways
if expect_status 2 \
    && expect_contains "$output" "Unknown orientation: sideways" "the error" \
    && expect_absent "$calls" "hinge -d" "the recorded calls"; then
    pass
fi

run_script "duo-pose refuses a device with one display" "$duo_pose" open --device "$pro_udid"
if expect_status 1 \
    && expect_contains "$output" "it is not an iPhone Duo" "the error" \
    && expect_absent "$calls" "hinge -d" "the recorded calls"; then
    pass
fi

duo_displays false true rot0 > "$work/displays-open.json"
STUB_DISPLAYS="$work/displays-open.json" \
    run_script "duo-pose opens the hinge to 180° and reads the inner display back" \
    "$duo_pose" open --device "$pro_udid"
if expect_status 0 \
    && expect_contains "$calls" "hinge -d $pro_udid -t 1 set 180" "the recorded calls" \
    && expect_absent "$calls" " orient " "the recorded calls" \
    && expect_absent "$output" "could not confirm" "the output" \
    && expect_contains "$output" "open, the inner display showing, portrait" "the output"; then
    pass
fi

# A post that does not take is tried again by way of half-open, which is a
# change from any angle; only when that does not take either is it an error.
# hinge confirmed every angle, so the error blames the display, not the event.
duo_displays true false rot0 > "$work/displays-closed.json"
STUB_DISPLAYS="$work/displays-closed.json" \
    run_script "duo-pose tries half-open, then says the simulator stopped following the hinge" \
    "$duo_pose" open --device "$pro_udid"
unfolds="$(printf '%s\n' "$calls" | grep -c "set 180" || true)"
if expect_status 1 \
    && expect_contains "$output" "The hinge reached 180°, but the inner display did not become active" \
        "the error" \
    && expect_contains "$output" "stopped following the hinge" "the error"; then
    if [[ "$unfolds" == 2 && "$(call_line "set 90")" -gt "$(call_line "set 180")" ]]; then
        pass
    else
        fail "expected 180°, then 90°, then 180° again" "$calls"
    fi
fi

# An angle hinge could not set, and a display that never changed: the event is
# what failed, so the error carries hinge's own word and says where a newer
# hinge would come from, rather than blaming the simulator.
STUB_HINGE_ANGLE_FAILS=1 STUB_DISPLAYS="$work/displays-closed.json" \
    run_script "duo-pose blames the event when the angle never arrives" \
    "$duo_pose" open --device "$pro_udid"
if expect_status 1 \
    && expect_contains "$output" "hinge failed to set the angle to 180°" "the error" \
    && expect_contains "$output" "did not reach 180.0" "the error" \
    && expect_contains "$output" "brew upgrade hinge" "the error" \
    && expect_absent "$output" "stopped following" "the error"; then
    pass
fi

# The other way round, as when only hinge's reading of the angle breaks. hinge
# posts nothing where CoreMotion cannot report, so the angle goes out once more
# unconfirmed; the display took over, and a frame is shot on the display, so
# the pose stands — with a word about the angle.
STUB_HINGE_ANGLE_FAILS=1 STUB_DISPLAYS="$work/displays-open.json" \
    run_script "duo-pose takes a fold the display shows, warning that the angle went unconfirmed" \
    "$duo_pose" open --device "$pro_udid"
if expect_status 0 \
    && expect_contains "$calls" "hinge -d $pro_udid -t 0 set 180" "the recorded calls" \
    && expect_contains "$output" "could not confirm the angle" "the warning" \
    && expect_contains "$output" "did not reach 180.0" "the warning" \
    && expect_contains "$output" "open, the inner display showing, portrait" "the output"; then
    pass
fi

# hinge is installed rather than kept here, and only opening needs it. Without
# it a Duo cannot be opened, and the error says what to install rather than
# posting nothing and waiting.
OPENHIKES_HINGE="$work/no-hinge" STUB_DISPLAYS="$work/displays-closed.json" \
    run_script "duo-pose says what to install when it has to open a Duo without hinge" \
    "$duo_pose" open --device "$pro_udid"
if expect_status 1 \
    && expect_contains "$output" "cannot be opened: hinge is not installed" "the error" \
    && expect_contains "$output" "brew install artemnovichkov/tap/hinge" "the error" \
    && expect_absent "$calls" "hinge -" "the recorded calls"; then
    pass
fi

# A simulator boots closed, so a closed pose needs no fold: without hinge it is
# read back, and holds when the cover is already showing, upright.
OPENHIKES_HINGE="$work/no-hinge" STUB_DISPLAYS="$work/displays-closed.json" \
    run_script "duo-pose reads a closed Duo back without hinge" \
    "$duo_pose" closed --device "$pro_udid"
if expect_status 0 \
    && expect_contains "$output" "closed, the cover display showing, portrait" "the output"; then
    pass
fi

OPENHIKES_HINGE="$work/no-hinge" STUB_DISPLAYS="$work/displays-open.json" \
    run_script "duo-pose says what to install when a closed pose needs a fold after all" \
    "$duo_pose" closed --device "$pro_udid"
if expect_status 1 \
    && expect_contains "$output" "The cover display is not active, and closing the Duo needs hinge" \
        "the error" \
    && expect_contains "$output" "brew install artemnovichkov/tap/hinge" "the error"; then
    pass
fi

# The oldest hinge Scripts/lib/hinge.sh accepts is a floor, not a pin: an older
# hinge is refused before it is asked to fold anything, and a newer one is used
# as it is — compared as versions, so 0.10.0 is the newer of it and 0.3.0.
STUB_HINGE_VERSION=0.2.0 STUB_DISPLAYS="$work/displays-closed.json" \
    run_script "duo-pose refuses a hinge older than the oldest it accepts" \
    "$duo_pose" open --device "$pro_udid"
if expect_status 1 \
    && expect_contains "$output" "hinge 0.2.0 is older than $STUB_HINGE_VERSION" "the error" \
    && expect_contains "$output" "brew upgrade hinge" "the error" \
    && expect_absent "$calls" "hinge -d" "the recorded calls"; then
    pass
fi

STUB_HINGE_VERSION=0.10.0 STUB_DISPLAYS="$work/displays-open.json" \
    run_script "duo-pose uses a hinge newer than the oldest it accepts as it is" \
    "$duo_pose" open --device "$pro_udid"
if expect_status 0 \
    && expect_contains "$calls" "hinge -d $pro_udid -t 1 set 180" "the recorded calls" \
    && expect_contains "$output" "open, the inner display showing, portrait" "the output"; then
    pass
fi

# Open, but on its side: every device orientation is tried, and the run fails
# when none of them stands the interface upright, rather than reporting the
# pose it asked for.
duo_displays false true rot90 > "$work/displays-sideways.json"
STUB_DISPLAYS="$work/displays-sideways.json" \
    run_script "duo-pose fails when the display never turns the way it was asked" \
    "$duo_pose" open --device "$pro_udid"
turns="$(printf '%s\n' "$calls" | grep -c " orient " || true)"
if expect_status 1 \
    && expect_contains "$output" "The inner display did not turn to portrait" "the error"; then
    if [[ "$turns" == 4 ]]; then
        pass
    else
        fail "expected every device orientation to be tried once — got $turns" "$calls"
    fi
fi

# The same state is the pose asked for when landscape is: the inner display
# opens on its side, so nothing is turned.
STUB_DISPLAYS="$work/displays-sideways.json" \
    run_script "duo-pose takes the inner display in landscape the way it opens" \
    "$duo_pose" open --device "$pro_udid" --orientation landscape
if expect_status 0 \
    && expect_absent "$calls" " orient " "the recorded calls" \
    && expect_contains "$output" "open, the inner display showing, landscape" "the output"; then
    pass
fi

# Open and upright, where the run asked for landscape: the orientation has to
# reach Scripts/duo-pose.sh, whose read-back then stops the run before it
# builds, rather than a landscape set coming out upright.
STUB_DISPLAYS="$work/displays-open.json" \
    run_script "screenshots asks for the orientation it was given, and stops when it is not taken" \
    "$screenshots_light" --frame 7 --pose open --orientation landscape --no-photos --device "$pro_udid" \
    --derived-data "$screens_dd" --output "$work/screens-out"
if expect_status 1 \
    && expect_contains "$output" "The inner display did not turn to landscape" "the output" \
    && expect_absent "$calls" "xcodebuild" "the recorded calls"; then
    pass
fi

# Opening needs hinge, and a machine without it skips an open set: saying so,
# and before a device is erased or anything is built.
OPENHIKES_HINGE="$work/no-hinge" \
    run_script "screenshots skips an open Duo set without hinge, before touching a device" \
    "$screenshots_light" --frame 7 --pose open --no-photos --device "$pro_udid" \
    --derived-data "$screens_dd" --output "$work/screens-out"
if expect_status 0 \
    && expect_contains "$output" "skipped, the open iPhone Duo needs hinge: hinge is not installed" \
        "the output" \
    && expect_absent "$calls" "simctl erase" "the recorded calls" \
    && expect_absent "$calls" "simctl create" "the recorded calls" \
    && expect_absent "$calls" "xcodebuild" "the recorded calls"; then
    pass
fi
unset OPENHIKES_DUO_POSE_SETTLE_SECONDS OPENHIKES_DUO_POSE_TURN_SECONDS

echo
echo "App Store frame fitting"

# Scripts/lib/fit-screenshot.swift rewrites every frame the screenshot scripts
# export. A landscape capture is stored as its display's portrait pixels with
# an EXIF orientation, and a frame written back without turning it would lie
# on its side wherever the tag is not read. The fixtures are white with their
# first stored pixel red, so where that pixel ends up says which way a frame
# was turned; the probe reads stored pixels and never applies a tag.
frame_fitter="$repository_root/Scripts/lib/fit-screenshot.swift"
fit_work="$work/fit"
mkdir -p "$fit_work"
cat > "$fit_work/make.swift" <<'SWIFT'
import AppKit
import ImageIO
import UniformTypeIdentifiers

// `<name>:<width>x<height>:<EXIF orientation>`, written into the first argument.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let space = CGColorSpace(name: CGColorSpace.sRGB)!
for spec in CommandLine.arguments.dropFirst(2) {
    let parts = spec.split(separator: ":")
    let size = parts[1].split(separator: "x").compactMap { Int($0) }
    let orientation = Int(parts[2])!
    let context = CGContext(
        data: nil, width: size[0], height: size[1], bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size[0], height: size[1]))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: size[1] - 1, width: 1, height: 1))
    let url = directory.appendingPathComponent("\(parts[0]).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    let properties: [String: Any] = orientation == 1 ? [:] : [kCGImagePropertyOrientation as String: orientation]
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(url.path)") }
}
SWIFT
cat > "$fit_work/probe.swift" <<'SWIFT'
import AppKit
import ImageIO

// `<file> <width>x<height> <orientation or none> <corners>`: the stored pixels,
// each corner R where it is red, clockwise from the top left.
for path in CommandLine.arguments.dropFirst() {
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    let orientation = (properties[kCGImagePropertyOrientation as String] as? Int).map(String.init) ?? "none"
    let width = image.width
    let height = image.height
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    let corners = [(0, 0), (width - 1, 0), (width - 1, height - 1), (0, height - 1)].map { x, y in
        let offset = (y * width + x) * 4
        return pixels[offset] > 200 && pixels[offset + 1] < 60 ? "R" : "W"
    }
    print("\((path as NSString).lastPathComponent) \(width)x\(height) \(orientation) \(corners.joined())")
}
SWIFT
swift "$fit_work/make.swift" "$fit_work" right:3x5:6 left:3x5:8 \
    inner-landscape:2006x2852:6 inner-portrait:2006x2852:1 phone:1206x2622:1
for frame in right left inner-landscape inner-portrait phone; do
    cp "$fit_work/$frame.png" "$fit_work/$frame-before.png"
done
run_script "fit-screenshot turns a frame stored on its side upright, either way round, and drops the tag" \
    swift "$frame_fitter" 2007x2853 2853x2007 -- "$fit_work/right.png" "$fit_work/left.png" \
    "$fit_work/inner-landscape.png" "$fit_work/inner-portrait.png" "$fit_work/phone.png"
fit_status="$status"
fit_output="$output"
probe="$(swift "$fit_work/probe.swift" "$fit_work"/*.png)"
if expect_status 0 \
    && expect_contains "$probe" "right-before.png 3x5 6 RWWW" "the fixtures" \
    && expect_contains "$probe" "left-before.png 3x5 8 RWWW" "the fixtures" \
    && expect_contains "$probe" "right.png 5x3 none WRWW" "the fitted frames" \
    && expect_contains "$probe" "left.png 5x3 none WWWR" "the fitted frames"; then
    pass
fi

current="fit-screenshot turns a landscape capture of the open iPhone Duo upright, then fills the pixel it is short"
status="$fit_status"
if expect_status 0 \
    && expect_contains "$probe" "inner-landscape.png 2853x2007 none WRWW" "the fitted frames" \
    && expect_contains "$fit_output" "inner-landscape.png: 2006 × 2852 → 2853 × 2007, turned upright" "the output"; then
    pass
fi

current="fit-screenshot puts back the pixel a capture of the inner display is short"
if expect_contains "$probe" "inner-portrait.png 2007x2853 none RWWW" "the fitted frames"; then
    pass
fi

current="fit-screenshot leaves an upright frame of any other size as it was"
if expect_absent "$fit_output" "phone.png" "the output"; then
    if cmp -s "$fit_work/phone.png" "$fit_work/phone-before.png"; then
        pass
    else
        fail "phone.png was rewritten"
    fi
fi

run_script "screenshots accepts a fitted App Store frame" \
    bash -c 'source "$1"; fit_screenshot_frame "$2"' _ \
    "$repository_root/Scripts/lib/screenshots.sh" "$fit_work/inner-portrait.png"
if expect_status 0; then pass; fi

run_script "screenshots rejects a capture from a device with the wrong dimensions" \
    bash -c 'source "$1"; fit_screenshot_frame "$2"' _ \
    "$repository_root/Scripts/lib/screenshots.sh" "$fit_work/phone.png"
if expect_status 1 \
    && expect_contains "$output" "is not an App Store screenshot size" "the error"; then
    pass
fi

mkdir -p "$fit_work/pixel captures"
cp "$fit_work/inner-portrait.png" "$fit_work/pixel captures/frame.png"
run_script "screenshots reads dimensions when the image path contains pixel and spaces" \
    bash -c 'source "$1"; fit_screenshot_frame "$2"' _ \
    "$repository_root/Scripts/lib/screenshots.sh" "$fit_work/pixel captures/frame.png"
if expect_status 0; then pass; fi

screens_attachments="$work/screens-attachments"
mkdir -p "$screens_attachments"
cp "$fit_work/inner-portrait.png" "$screens_attachments/passed.png"
cp "$fit_work/inner-portrait.png" "$screens_attachments/failed.png"
cat > "$screens_attachments/manifest.json" <<'EOF'
[
  {"testIdentifier":"ScreenshotUITests/testCapturesNearbyTrails()","attachments":[
    {"exportedFileName":"passed.png","suggestedHumanReadableName":"03-nearby-trails_0_uuid.png"}]},
  {"testIdentifier":"ScreenshotUITests/testCapturesRecordingAHike()","attachments":[
    {"exportedFileName":"failed.png","suggestedHumanReadableName":"05-recording-a-hike_0_uuid.png"}]}
]
EOF
cat > "$work/screens-results.json" <<'EOF'
{"testNodes":[{"nodeType":"Test Plan","children":[{"nodeType":"Test Suite","children":[
  {"nodeType":"Test Case","nodeIdentifier":"ScreenshotUITests/testCapturesNearbyTrails()","result":"Passed"},
  {"nodeType":"Test Case","nodeIdentifier":"ScreenshotUITests/testCapturesRecordingAHike()","result":"Failed"}
]}]}]}
EOF
STUB_DEVICES="$screens_prepared" STUB_SCREENSHOT_RESULTS="$work/screens-results.json" \
STUB_SCREENSHOT_ATTACHMENTS="$screens_attachments" STUB_XCODEBUILD_TEST_STATUS=65 \
    run_script "screenshots keeps passing frames from a failing group and retries only the failed frame" \
    "$screenshots_light" --frame 3 --frame 5 --no-photos --prepared-device "$pro_udid" \
    --pool-owner screenshot-tests --derived-data "$screens_dd" --output "$work/screens-out"
passed_selections="$(printf '%s\n' "$calls" | grep -o 'only-testing:OpenHikesUITests/ScreenshotUITests/testCapturesNearbyTrails' \
    | wc -l | tr -d ' ')"
failed_selections="$(printf '%s\n' "$calls" | grep -o 'only-testing:OpenHikesUITests/ScreenshotUITests/testCapturesRecordingAHike' \
    | wc -l | tr -d ' ')"
if expect_status 1 \
    && expect_contains "$output" "FAILED — not shot: 05" "the output" \
    && expect_absent "$output" "not shot: 03" "the output"; then
    if [[ "$passed_selections" == 1 && "$failed_selections" == 2 \
        && -f "$work/screens-out/03-nearby-trails.png" && ! -f "$work/screens-out/05-recording-a-hike.png" ]]; then
        pass
    else
        fail "expected one passing-frame selection and two failed-frame selections; got $passed_selections/$failed_selections" \
            "$output"
    fi
fi

# A frame attached before a test fails or crashes is never an upload frame,
# even if xcodebuild's printed summary is green and its exit status is zero.
sed 's/"Passed"/"Failed"/g' "$work/screens-results.json" > "$work/screens-crashed.json"
STUB_DEVICES="$screens_prepared" STUB_SCREENSHOT_RESULTS="$work/screens-crashed.json" \
STUB_SCREENSHOT_ATTACHMENTS="$screens_attachments" \
    run_script "screenshots rejects attachments from tests that did not pass despite a green process" \
    "$screenshots_light" --frame 3 --no-photos --no-retry --prepared-device "$pro_udid" \
    --pool-owner screenshot-tests --derived-data "$screens_dd" --output "$work/screens-out"
if expect_status 1 \
    && expect_contains "$output" "FAILED — not shot: 03" "the output" \
    && expect_absent "$calls" "xcresulttool export attachments" "the recorded calls"; then pass; fi

printf 'not a test result' > "$work/screens-invalid.json"
run_script "screenshots refuses unreadable structured test results" \
    bash -c 'swift "$1" < "$2"' _ \
    "$repository_root/Scripts/lib/screenshot-passed-tests.swift" "$work/screens-invalid.json"
if expect_status 1 && expect_contains "$output" "Could not read screenshot test results" "the error"; then pass; fi

screens_runs="$work/screens-retention"
for run_number in 01 02 03 04 05 06 07; do
    mkdir -p "$screens_runs/$run_number"
    touch "$screens_runs/$run_number/.complete"
done
mkdir -p "$screens_runs/08" "$screens_runs/active"
run_script "screenshots retains five completed runs and leaves active evidence alone" \
    bash -c 'source "$1"; screenshot_runs_dir="$2"; screenshot_log_dir="$2/08"; finish_screenshot_run' _ \
    "$repository_root/Scripts/lib/screenshots.sh" "$screens_runs"
if expect_status 0; then
    retained="$(find "$screens_runs" -name .complete | wc -l | tr -d ' ')"
    if [[ "$retained" == 5 && ! -d "$screens_runs/03" && -d "$screens_runs/04" \
        && -d "$screens_runs/08" && -d "$screens_runs/active" ]]; then
        pass
    else
        fail "expected only the five newest completed runs and the active run"
    fi
fi

echo
echo "Simulator pool"

# Scripts/sim-pool.sh decides which device a session's tests land on and
# whether it starts clean. Every case names its owner, so nothing here reads
# the Claude Code session this suite may itself be running in, and the claims
# go into the work directory rather than the ones this machine's sessions hold.
#
# Starting clean is a clone of the pool's template, settled by the first case
# below, and an erase only when no template can be settled — see
# Scripts/lib/simulator-templates.sh for what an erase costs. A clone has a new
# UDID, so a case that replaces Pool 1 moves `pool_one` on to the clone.
sim_pool="$repository_root/Scripts/sim-pool.sh"
export OPENHIKES_SIM_POOL_DIR="$work/sim-pool"
pool_fixture="$work/devices-pool.txt"
pool_one="A0000000-0000-4000-8000-000000000001"
pool_two="A0000000-0000-4000-8000-000000000002"
pool_template="A0000000-0000-4000-8000-0000000000f0"
pool_template_name="OpenHikes Template (iPhone 18 Pro, iOS 27.0)"
cat > "$pool_fixture" <<'EOF'
== Devices ==
-- watchOS 27.0 --
    Apple Watch SE 3 (40mm) (33333333-3333-3333-3333-333333333333) (Shutdown)
-- iOS 27.0 --
    iPhone 18 Pro (77777777-7777-7777-7777-777777777777) (Booted)
EOF
export STUB_DEVICES="$pool_fixture"
asset_jobs_table "$pool_template" 0

# The stubs on PATH, for a step between cases that is not itself a case.
pool_step() {
    PATH="$stub_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$sim_pool" "$@" >/dev/null 2>&1
}

STUB_CREATED_UDID="$pool_template" STUB_CLONED_UDID="$pool_one" \
    run_script "sim-pool settles a template and clones the first device from it" \
    "$sim_pool" acquire --owner alpha
settled_at="$(call_line "simctl shutdown $pool_template")"
cloned_at="$(call_line "simctl clone $pool_template OpenHikes Pool 1")"
if expect_status 0 \
    && expect_contains "$calls" \
        "simctl create $pool_template_name iPhone 18 Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0" \
        "the recorded calls" \
    && expect_contains "$calls" "simctl bootstatus $pool_template -b" "the recorded calls" \
    && expect_contains "$calls" "simctl bootstatus $pool_one -b" "the recorded calls" \
    && expect_contains "$calls" "simctl privacy $pool_one grant photos tappium.com.OpenHikes" "the recorded calls" \
    && expect_absent "$calls" "simctl create OpenHikes Pool" "the recorded calls" \
    && expect_absent "$calls" "simctl erase" "the recorded calls" \
    && expect_absent "$calls" "77777777" "the recorded calls"; then
    if [[ "$(printf '%s\n' "$output" | tail -n 1)" != "$pool_one" ]]; then
        fail "did not end its output with the device's UDID" "$output"
    elif (( settled_at == 0 || settled_at > cloned_at )); then
        fail "cloned the template before shutting it down — lines $settled_at, $cloned_at" "$calls"
    else
        pass
    fi
fi

run_script "sim-pool gives an owner back its own device, data and all" \
    "$sim_pool" acquire --owner alpha
if expect_status 0 \
    && expect_contains "$output" "$pool_one" "the output" \
    && expect_absent "$calls" "simctl create" "the recorded calls" \
    && expect_absent "$calls" "simctl clone" "the recorded calls" \
    && expect_absent "$calls" "simctl erase" "the recorded calls" \
    && expect_contains "$calls" "simctl privacy $pool_one grant photos tappium.com.OpenHikes" "the recorded calls"; then
    pass
fi

STUB_CLONED_UDID="$pool_two" \
    run_script "sim-pool clones the next number from the settled template" \
    "$sim_pool" acquire --owner beta
if expect_status 0 \
    && expect_contains "$calls" "simctl clone $pool_template OpenHikes Pool 2" "the recorded calls" \
    && expect_contains "$output" "$pool_two" "the output" \
    && expect_absent "$calls" "simctl create" "the recorded calls" \
    && expect_absent "$calls" "simctl bootstatus $pool_template" "the recorded calls"; then
    pass
fi

OPENHIKES_SIM_POOL_MAX=2 \
    run_script "sim-pool refuses to grow past its cap" \
    "$sim_pool" acquire --owner gamma
if expect_status 1 \
    && expect_contains "$output" "at its cap of 2" "the error" \
    && expect_contains "$output" "$pool_template_name  $pool_template  Shutdown settled 0d ago" \
        "the status it printed" \
    && expect_absent "$calls" "simctl create" "the recorded calls" \
    && expect_absent "$calls" "simctl clone" "the recorded calls"; then
    pass
fi

run_script "sim-pool release gives the device back" \
    "$sim_pool" release --owner alpha
if expect_status 0 \
    && expect_contains "$output" "Released OpenHikes Pool 1" "the output" \
    && expect_contains "$(cat "$OPENHIKES_SIM_POOL_DIR/$pool_one.claim")" "released=" "the claim"; then
    pass
fi

# Nobody has had it since, so there is nothing to clean: the same device, as
# its owner left it.
run_script "sim-pool gives a released device back to its last owner untouched" \
    "$sim_pool" acquire --owner alpha
if expect_status 0 \
    && expect_contains "$output" "$pool_one" "the output" \
    && expect_absent "$calls" "simctl clone" "the recorded calls" \
    && expect_absent "$calls" "simctl delete" "the recorded calls" \
    && expect_absent "$calls" "simctl erase" "the recorded calls"; then
    pass
fi
pool_step release --owner alpha || true

pool_one_clone="A0000000-0000-4000-8000-000000000003"
STUB_CLONED_UDID="$pool_one_clone" \
    run_script "sim-pool hands a released device to the next owner as a clean clone" \
    "$sim_pool" acquire --owner gamma
if expect_status 0 \
    && expect_contains "$output" "$pool_one_clone" "the output" \
    && expect_contains "$calls" "simctl clone $pool_template OpenHikes Pool 1 (replacing)" "the recorded calls" \
    && expect_contains "$calls" "simctl delete $pool_one" "the recorded calls" \
    && expect_contains "$calls" "simctl rename $pool_one_clone OpenHikes Pool 1" "the recorded calls" \
    && expect_absent "$calls" "simctl erase" "the recorded calls" \
    && expect_absent "$calls" "simctl create" "the recorded calls"; then
    # The grant on the clone, after it has taken Pool 1's name.
    renamed_at="$(call_line "simctl rename $pool_one_clone")"
    grant_at="$(call_line "simctl privacy $pool_one_clone grant photos")"
    if (( renamed_at > 0 && grant_at > renamed_at )); then
        pass
    else
        fail "granted the photo library before the clone took over, or not at all" "$calls"
    fi
fi
pool_one="$pool_one_clone"

# A claim whose process has exited is one nobody holds. The PID is a process
# this suite started and waited for, so it is certainly gone.
true & dead_pid=$!
wait "$dead_pid"
printf 'owner=gamma\npid=%s\nstarted=\nclaimed=0\n' "$dead_pid" > "$OPENHIKES_SIM_POOL_DIR/$pool_one.claim"
run_script "sim-pool takes over a claim whose process has exited" \
    "$sim_pool" acquire --owner delta --keep-data
if expect_status 0 \
    && expect_contains "$output" "$pool_one" "the output" \
    && expect_absent "$calls" "simctl clone" "the recorded calls" \
    && expect_absent "$calls" "simctl erase" "the recorded calls"; then
    pass
fi

pool_one_clone="A0000000-0000-4000-8000-000000000004"
OPENHIKES_SIM_POOL_TTL_MINUTES=0 STUB_CLONED_UDID="$pool_one_clone" \
    run_script "sim-pool takes over a claim left idle past its lease" \
    "$sim_pool" acquire --owner epsilon
if expect_status 0 \
    && expect_contains "$output" "$pool_one_clone" "the output" \
    && expect_contains "$calls" "simctl delete $pool_one" "the recorded calls"; then
    pass
fi
pool_one="$pool_one_clone"

# Neither device has a claim, but each has a run on it: a process naming Pool
# 1's UDID — `bash -c` puts it on its own command line as `$0`, and it waits on
# a pipe this suite closes rather than on a duration — and a live
# Scripts/run-ui-tests.sh lock on Pool 2.
holder_fifo="$work/holder.fifo"
mkfifo "$holder_fifo"
bash -c 'read -r _ < "$1"' "$pool_one" "$holder_fifo" & holder_pid=$!
rm -f "$OPENHIKES_SIM_POOL_DIR"/*.claim
mkdir -p "$OPENHIKES_UI_TEST_LOCK_DIR/$pool_two.lock"
printf '%s\n' "$$" > "$OPENHIKES_UI_TEST_LOCK_DIR/$pool_two.lock/pid"
OPENHIKES_SIM_POOL_MAX=2 \
    run_script "sim-pool never hands out a device a run is using" \
    "$sim_pool" acquire --owner zeta
echo > "$holder_fifo"
wait "$holder_pid" 2>/dev/null || true
rm -rf "$OPENHIKES_UI_TEST_LOCK_DIR/$pool_two.lock"
if expect_status 1 \
    && expect_contains "$output" "busy" "the status it printed" \
    && expect_absent "$calls" "simctl clone" "the recorded calls" \
    && expect_absent "$calls" "simctl delete" "the recorded calls" \
    && expect_absent "$calls" "simctl erase" "the recorded calls"; then
    pass
fi

run_script "sim-pool prune keeps the lowest free devices and deletes the rest" \
    "$sim_pool" prune --keep 1
if expect_status 0 \
    && expect_contains "$calls" "simctl delete $pool_two" "the recorded calls" \
    && expect_absent "$calls" "simctl delete $pool_one" "the recorded calls" \
    && expect_absent "$calls" "simctl delete $pool_template" "the recorded calls"; then
    pass
fi

run_script "sim-pool refuses to adopt a booted simulator" \
    "$sim_pool" adopt "iPhone 18 Pro"
if expect_status 1 \
    && expect_contains "$output" "only an idle, shut-down simulator" "the error" \
    && expect_absent "$calls" "simctl rename" "the recorded calls"; then
    pass
fi

# Idle and shut down, which is everything adopt asks of a device — and the one
# simulator whose loss would cost the next hand-off its download again.
run_script "sim-pool refuses to adopt a template" \
    "$sim_pool" adopt "$pool_template_name"
if expect_status 1 \
    && expect_contains "$output" "is a template the pool clones from" "the error" \
    && expect_absent "$calls" "simctl rename" "the recorded calls"; then
    pass
fi

# A refresh age of no days makes the template due, which a week does for real.
pool_one_clone="A0000000-0000-4000-8000-000000000005"
OPENHIKES_SIM_TEMPLATE_REFRESH_DAYS=0 STUB_CLONED_UDID="$pool_one_clone" \
    run_script "sim-pool refreshes a template that is due before cloning it" \
    "$sim_pool" acquire --owner eta
refreshed_at="$(call_line "simctl bootstatus $pool_template -b")"
settled_at="$(call_line "simctl shutdown $pool_template")"
cloned_at="$(call_line "simctl clone $pool_template OpenHikes Pool 1 (replacing)")"
if expect_status 0 \
    && expect_contains "$output" "Refreshing $pool_template_name" "the output" \
    && expect_contains "$output" "$pool_one_clone" "the output" \
    && expect_absent "$calls" "simctl create" "the recorded calls"; then
    if (( refreshed_at > 0 && refreshed_at < settled_at && settled_at < cloned_at )); then
        pass
    else
        fail "expected boot, shutdown, then clone — got lines $refreshed_at, $settled_at, $cloned_at" "$calls"
    fi
fi
pool_one="$pool_one_clone"
pool_step release --owner eta || true

# A refresh still downloading at its deadline leaves the template it started
# from, which has settled before: the device is cloned from it as it is, not
# erased into the download the template exists to save.
asset_jobs_table "$pool_template" 2
pool_one_clone="A0000000-0000-4000-8000-000000000006"
OPENHIKES_SIM_TEMPLATE_REFRESH_DAYS=0 OPENHIKES_SIM_TEMPLATE_SETTLE_SECONDS=0 \
STUB_CLONED_UDID="$pool_one_clone" \
    run_script "sim-pool clones a template whose refresh runs out of time" \
    "$sim_pool" acquire --owner theta
if expect_status 0 \
    && expect_contains "$output" "still catching up" "the output" \
    && expect_contains "$output" "$pool_one_clone" "the output" \
    && expect_contains "$calls" "simctl shutdown $pool_template" "the recorded calls" \
    && expect_contains "$calls" "simctl clone $pool_template OpenHikes Pool 1 (replacing)" "the recorded calls" \
    && expect_absent "$calls" "simctl erase" "the recorded calls"; then
    pass
fi
pool_one="$pool_one_clone"
pool_step release --owner theta || true

# A template that has never settled and is still downloading at its deadline
# is no template: the device is erased, as it was before there were templates,
# rather than not handed out.
rm -f "$OPENHIKES_SIM_TEMPLATE_DIR/$pool_template.settled"
OPENHIKES_SIM_TEMPLATE_SETTLE_SECONDS=0 \
    run_script "sim-pool erases as before when no template settles" \
    "$sim_pool" acquire --owner iota
if expect_status 0 \
    && expect_contains "$output" "still downloading" "the output" \
    && expect_contains "$output" "Without a template" "the output" \
    && expect_contains "$calls" "simctl shutdown $pool_template" "the recorded calls" \
    && expect_contains "$calls" "simctl erase $pool_one" "the recorded calls" \
    && expect_absent "$calls" "simctl clone" "the recorded calls"; then
    pass
fi

# A pool on the deployment floor: an older runtime pinned, which the newest
# that runs the same device type must not displace, under a prefix of its own.
floor_template="A0000000-0000-4000-8000-0000000000f1"
floor_one="A0000000-0000-4000-8000-000000000101"
cat > "$work/runtimes-floor.json" <<'EOF'
{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-6","supportedDeviceTypes":[{"name":"iPhone 16 Pro"}]},{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","supportedDeviceTypes":[{"name":"iPhone 16 Pro"},{"name":"iPhone 18 Pro"}]}]}
EOF
cat > "$work/devices-floor.txt" <<'EOF'
== Devices ==
-- iOS 18.6 --
EOF
asset_jobs_table "$floor_template" 0
STUB_RUNTIMES="$work/runtimes-floor.json" STUB_DEVICES="$work/devices-floor.txt" \
OPENHIKES_SIM_POOL_PREFIX="OpenHikes Floor" OPENHIKES_SIM_POOL_DEVICE_TYPE="iPhone 16 Pro" \
OPENHIKES_SIM_POOL_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-18-6" \
STUB_CREATED_UDID="$floor_template" STUB_CLONED_UDID="$floor_one" \
    run_script "sim-pool builds a pinned runtime's template rather than the newest one's" \
    "$sim_pool" acquire --owner floor
if expect_status 0 \
    && expect_contains "$calls" \
        "simctl create OpenHikes Template (iPhone 16 Pro, iOS 18.6) iPhone 16 Pro com.apple.CoreSimulator.SimRuntime.iOS-18-6" \
        "the recorded calls" \
    && expect_contains "$calls" "simctl clone $floor_template OpenHikes Floor 1" "the recorded calls" \
    && expect_absent "$calls" "iOS-27-0" "the recorded calls"; then
    if [[ "$(printf '%s\n' "$output" | tail -n 1)" != "$floor_one" ]]; then
        fail "did not end its output with the device's UDID" "$output"
    else
        pass
    fi
fi

echo "Render trace"

# Scripts/render-trace.sh records with Instruments and cannot record here, but
# what it concludes is all in Scripts/lib/render-trace-report.swift, and that
# is where a wrong answer would come from: a `ref` resolved to the wrong value
# names the wrong view, a body credited to the wrong step points a reader at
# the wrong tap, and a view's first value read as an update reports every
# screen as rebuilt for a reason. So --report is run against tables written
# here, in the shape `xctrace export` writes them — every value after its
# first a `ref`, each word of a narrative its own element, and one generic
# view name cut off mid-parameter the way Instruments cuts a long one.
render_trace="$repository_root/Scripts/render-trace.sh"
trace_fixture="$work/render-trace"
mkdir -p "$trace_fixture/run/render.trace" "$trace_fixture/run/run.xcresult"

# Recording began at 1791484382.817; the steps below begin at 383, 384 and
# 386, so a body at 1.5s is the launch's and one at 3.5s is the tap's.
cat > "$trace_fixture/toc.xml" <<'XML'
<?xml version="1.0"?>
<trace-toc><run number="1"><info><summary><start-date>2026-10-08T20:33:02.817+02:00</start-date></summary></info></run></trace-toc>
XML

cat > "$trace_fixture/bodies.xml" <<'XML'
<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[8]'><schema name="swiftui-body-interval"><col><mnemonic>start</mnemonic><name>Start</name></col><col><mnemonic>duration</mnemonic><name>Duration</name></col><col><mnemonic>view-type</mnemonic><name>View Type</name></col><col><mnemonic>view-module</mnemonic><name>Module</name></col><col><mnemonic>severity</mnemonic><name>Classification</name></col></schema><row><start-time id="1" fmt="00:01.500.000">1500000000</start-time><duration id="2" fmt="1.00 ms">1000000</duration><string id="3" fmt="OpenHikesView">OpenHikesView</string><string id="4" fmt="OpenHikes.debug.dylib">OpenHikes.debug.dylib</string><event-concept id="5" fmt="Low">Low</event-concept></row>
<row><start-time id="6" fmt="00:01.600.000">1600000000</start-time><duration ref="2"/><string id="7" fmt="MapScreenAlerts">MapScreenAlerts</string><string ref="4"/><event-concept ref="5"/></row>
<row><start-time id="8" fmt="00:01.700.000">1700000000</start-time><duration ref="2"/><string id="9" fmt="GlassStack&lt;HStack&lt;TupleContent&lt;Pack{Image, Text">GlassStack&lt;HStack&lt;TupleContent&lt;Pack{Image, Text</string><string ref="4"/><event-concept ref="5"/></row>
<row><start-time id="10" fmt="00:01.800.000">1800000000</start-time><duration ref="2"/><string id="11" fmt="MainMenuItemHost.RootView">MainMenuItemHost.RootView</string><string id="12" fmt="SwiftUI">SwiftUI</string><event-concept ref="5"/></row>
<row><start-time id="13" fmt="00:03.500.000">3500000000</start-time><duration ref="2"/><string ref="7"/><string ref="4"/><event-concept ref="5"/></row>
<row><start-time id="14" fmt="00:03.600.000">3600000000</start-time><duration ref="2"/><string ref="7"/><string ref="4"/><event-concept ref="5"/></row>
<row><start-time id="15" fmt="00:03.700.000">3700000000</start-time><duration ref="2"/><string ref="7"/><string ref="4"/><event-concept ref="5"/></row>
<row><start-time id="16" fmt="00:03.800.000">3800000000</start-time><duration ref="2"/><string ref="3"/><string ref="4"/><event-concept ref="5"/></row>
</node></trace-query-result>
XML

cat > "$trace_fixture/properties.xml" <<'XML'
<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[2]'><schema name="swiftui-link-event"><col><mnemonic>time</mnemonic><name>Time</name></col><col><mnemonic>link-type</mnemonic><name>Property Type</name></col><col><mnemonic>view-type</mnemonic><name>View Type</name></col><col><mnemonic>view-module</mnemonic><name>Module</name></col><col><mnemonic>value</mnemonic><name>Value</name></col><col><mnemonic>event</mnemonic><name>Event</name></col><col><mnemonic>narrative</mnemonic><name>Transition</name></col></schema><row><event-time id="1" fmt="00:01.400.000">1400000000</event-time><string id="2" fmt="State&lt;Bool&gt;">State&lt;Bool&gt;</string><string id="3" fmt="OpenHikesView">OpenHikesView</string><string id="4" fmt="OpenHikes.debug.dylib">OpenHikes.debug.dylib</string><string id="5" fmt="false">false</string><string id="6" fmt="Update">Update</string><narrative id="7" fmt="State&lt;Bool&gt; in OpenHikesView updated from &lt;initialState&gt; to false"><string ref="2"/><narrative-text id="8" fmt=" in "> in </narrative-text><string ref="3"/><narrative-text id="9" fmt=" updated from "> updated from </narrative-text><string id="10" fmt="&lt;initialState&gt;">&lt;initialState&gt;</string><narrative-text id="11" fmt=" to "> to </narrative-text><string ref="5"/></narrative></row>
<row><event-time id="12" fmt="00:03.450.000">3450000000</event-time><string id="13" fmt="Binding&lt;Bool&gt;">Binding&lt;Bool&gt;</string><string id="14" fmt="MapScreenAlerts">MapScreenAlerts</string><string ref="4"/><string ref="5"/><string ref="6"/><narrative id="15" fmt="Binding&lt;Bool&gt; in MapScreenAlerts updated from false to false"><string ref="13"/><narrative-text ref="8"/><string ref="14"/><narrative-text ref="9"/><string ref="5"/><narrative-text ref="11"/><string ref="5"/></narrative></row>
<row><event-time id="16" fmt="00:03.550.000">3550000000</event-time><string ref="13"/><string ref="14"/><string ref="4"/><string ref="5"/><string ref="6"/><narrative ref="15"/></row>
<row><event-time id="17" fmt="00:03.750.000">3750000000</event-time><string id="18" fmt="State&lt;Optional&lt;Hike&gt;&gt;">State&lt;Optional&lt;Hike&gt;&gt;</string><string ref="3"/><string ref="4"/><string id="19" fmt="Optional(OpenHikesData.Hike)">Optional(OpenHikesData.Hike)</string><string ref="6"/><narrative id="20" fmt="State&lt;Optional&lt;Hike&gt;&gt; in OpenHikesView updated from nil to Optional(OpenHikesData.Hike)"><string ref="18"/><narrative-text ref="8"/><string ref="3"/><narrative-text ref="9"/><string id="21" fmt="nil">nil</string><narrative-text ref="11"/><string ref="19"/></narrative></row>
</node></trace-query-result>
XML

cat > "$trace_fixture/tests.json" <<'JSON'
{"testNodes":[{"children":[{"children":[{"children":[{"name":"testOne()","nodeIdentifier":"OpenHikesUITests/testOne()","nodeType":"Test Case","result":"Passed"}],"name":"OpenHikesUITests","nodeType":"Test Suite","result":"Passed"}],"name":"OpenHikesUITests","nodeType":"UI test bundle","result":"Passed"}],"name":"OpenHikes","nodeType":"Test Plan","result":"Passed"}]}
JSON

cat > "$trace_fixture/activities.json" <<'JSON'
{"testIdentifier":"OpenHikesUITests/testOne()","testRuns":[{"activities":[{"title":"Start Test at 2026-10-08 20:33:03.000","startTime":1791484383.0},{"title":"Open tappium.com.OpenHikes","startTime":1791484384.0,"childActivities":[{"title":"Wait for tappium.com.OpenHikes to idle","startTime":1791484384.5}]},{"title":"Tap \"Done\" Button","startTime":1791484386.0}]}]}
JSON

trace_run="$trace_fixture/run"
STUB_TRACE_DIR="$trace_fixture" \
    run_script "render-trace --report credits each body to its step and its cause" \
        "$render_trace" --report "$trace_run"
report="$(cat "$trace_run/report.md" 2>/dev/null || true)"
# The tap re-evaluated the alerts three times: twice after a binding that
# printed the same before and after, once with nothing named at all.
if expect_status 0 \
    && expect_contains "$output" "Report: $trace_run/report.md" "the output" \
    && expect_contains "$output" "| MapScreenAlerts | 4 | 4.0 |" "the summary printed" \
    && expect_contains "$report" '| 3 | MapScreenAlerts | OpenHikesUITests/testOne() | 2. Tap "Done" Button | Binding<Bool> (prints unchanged) ×2, unexplained ×1 |' "the hot spots" \
    && expect_contains "$report" "| OpenHikesView | 2 | 2.0 | State<Optional<Hike>> ×1, unexplained ×1 |" "the per-view table" \
    && expect_contains "$report" "| GlassStack<…> | 1 |" "the per-view table" \
    && expect_absent "$report" "MainMenuItemHost" "the report" \
    && expect_absent "$report" "State<Bool>" "the report"; then
    pass
fi

expected_tsv="test	step	view	bodies	nanoseconds	unexplained
OpenHikesUITests/testOne()	1. Open tappium.com.OpenHikes	GlassStack<…>	1	1000000	1
OpenHikesUITests/testOne()	1. Open tappium.com.OpenHikes	MapScreenAlerts	1	1000000	1
OpenHikesUITests/testOne()	1. Open tappium.com.OpenHikes	OpenHikesView	1	1000000	1
OpenHikesUITests/testOne()	2. Tap \"Done\" Button	MapScreenAlerts	3	3000000	1
OpenHikesUITests/testOne()	2. Tap \"Done\" Button	OpenHikesView	1	1000000	0"
current="render-trace --report writes one bodies.tsv row per test, step and view"
actual_tsv="$(cat "$trace_run/bodies.tsv" 2>/dev/null || true)"
if [[ "$actual_tsv" == "$expected_tsv" ]]; then
    pass
else
    fail "bodies.tsv is not what the fixture holds" "$(diff <(printf '%s\n' "$expected_tsv") <(printf '%s\n' "$actual_tsv") || true)"
fi

# The baseline is summed per test and view, so a body that moved from one
# step to another is not a change and a view that appeared is.
cat > "$trace_fixture/baseline.tsv" <<'TSV'
test	step	view	bodies	nanoseconds	unexplained
OpenHikesUITests/testOne()	1. Open tappium.com.OpenHikes	MapScreenAlerts	1	1000000	1
OpenHikesUITests/testOne()	2. Tap "Done" Button	MapScreenAlerts	1	1000000	1
OpenHikesUITests/testOne()	2. Tap "Done" Button	OpenHikesView	2	2000000	0
OpenHikesUITests/testGone()	2. Tap "Done" Button	OpenHikesView	9	9000000	0
TSV
STUB_TRACE_DIR="$trace_fixture" \
    run_script "render-trace --baseline reports each view whose count moved, and only those" \
        "$render_trace" --report "$trace_run" --baseline "$trace_fixture/baseline.tsv"
report="$(cat "$trace_run/report.md" 2>/dev/null || true)"
if expect_status 0 \
    && expect_contains "$report" "1 test(s) compared. Across the views that changed: 2 → 5 bodies." "the comparison" \
    && expect_contains "$report" "| OpenHikesUITests/testOne() | MapScreenAlerts | 2 | 4 | +2 |" "the comparison" \
    && expect_contains "$report" "| OpenHikesUITests/testOne() | GlassStack<…> | 0 | 1 | +1 |" "the comparison" \
    && expect_absent "$report" "| OpenHikesUITests/testOne() | OpenHikesView |" "the comparison" \
    && expect_absent "$report" "testGone" "the comparison"; then
    pass
fi

# Instruments collects SwiftUI's tracepoints from every simulator on the
# machine, so the third alert body in the tap — fired by process 5151, which
# is not one of the app's on the recorded simulator — is another session's and
# must not be counted, and neither is the second binding update before it,
# which the same process sent. The join is the instant, from a different table
# for each: a body starts exactly when a `kdebug` tracepoint fires, and a
# property update exactly when one of SwiftUI's signposts does, and both name
# their thread's process. The last update is in neither, and is kept and
# counted rather than guessed at.
cat > "$trace_fixture/kdebug.xml" <<'XML'
<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[1]'><schema name="kdebug"><col><mnemonic>time</mnemonic><name>Timestamp</name></col><col><mnemonic>thread</mnemonic><name>Thread</name></col></schema><row><event-time id="1" fmt="00:01.500.000">1500000000</event-time><thread id="2" fmt="Main Thread (0x1) (OpenHikes, pid: 4242)"><tid id="3" fmt="0x1">1</tid><process id="4" fmt="OpenHikes (4242)"><pid id="5" fmt="4242">4242</pid></process></thread></row>
<row><event-time id="6" fmt="00:01.600.000">1600000000</event-time><thread ref="2"/></row>
<row><event-time id="7" fmt="00:01.700.000">1700000000</event-time><thread ref="2"/></row>
<row><event-time id="8" fmt="00:03.500.000">3500000000</event-time><thread ref="2"/></row>
<row><event-time id="9" fmt="00:03.600.000">3600000000</event-time><thread ref="2"/></row>
<row><event-time id="10" fmt="00:03.700.000">3700000000</event-time><thread id="11" fmt="Main Thread (0x9) (OpenHikes, pid: 5151)"><tid id="12" fmt="0x9">9</tid><process id="13" fmt="OpenHikes (5151)"><pid id="14" fmt="5151">5151</pid></process></thread></row>
<row><event-time id="15" fmt="00:03.800.000">3800000000</event-time><thread ref="2"/></row>
</node></trace-query-result>
XML
cat > "$trace_fixture/os-signpost.xml" <<'XML'
<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[6]'><schema name="os-signpost"><col><mnemonic>time</mnemonic><name>Time</name></col><col><mnemonic>thread</mnemonic><name>Thread</name></col><col><mnemonic>process</mnemonic><name>Process</name></col><col><mnemonic>name</mnemonic><name>Name</name></col></schema><row><event-time id="1" fmt="00:01.400.000">1400000000</event-time><thread id="2" fmt="Main Thread (0x1) (OpenHikes, pid: 4242)"><tid id="3" fmt="0x1">1</tid><process id="4" fmt="OpenHikes (4242)"><pid id="5" fmt="4242">4242</pid></process></thread><process ref="4"/><signpost-name id="6" fmt="LinkUpdate">LinkUpdate</signpost-name></row>
<row><event-time id="7" fmt="00:03.450.000">3450000000</event-time><thread ref="2"/><process ref="4"/><signpost-name ref="6"/></row>
<row><event-time id="8" fmt="00:03.550.000">3550000000</event-time><thread id="9" fmt="Main Thread (0x9) (OpenHikes, pid: 5151)"><tid id="10" fmt="0x9">9</tid><process id="11" fmt="OpenHikes (5151)"><pid id="12" fmt="5151">5151</pid></process></thread><process ref="11"/><signpost-name ref="6"/></row>
</node></trace-query-result>
XML
filtered_run="$trace_fixture/filtered"
mkdir -p "$filtered_run/render.trace" "$filtered_run/run.xcresult"
printf '4242\n' > "$filtered_run/processes.txt"
STUB_TRACE_DIR="$trace_fixture" \
    run_script "render-trace leaves out another simulator's bodies" \
        "$render_trace" --report "$filtered_run"
report="$(cat "$filtered_run/report.md" 2>/dev/null || true)"
if expect_status 0 \
    && expect_contains "$report" "**1 bodies and 1 property updates from 1 other process(es) were left out**" "the report" \
    && expect_contains "$report" "1 event(s) could not be placed in a process and were kept." "the report" \
    && expect_contains "$report" "| MapScreenAlerts | 3 | 3.0 | Binding<Bool> (prints unchanged) ×1, unexplained ×2 |" "the per-view table" \
    && expect_contains "$report" "| OpenHikesView | 2 | 2.0 | State<Optional<Hike>> ×1, unexplained ×1 |" "the per-view table" \
    && expect_absent "$report" "| 3 | MapScreenAlerts |" "the hot spots"; then
    pass
fi

# A closure SwiftUI runs for the app — a ScrollViewReader's — is counted
# against SwiftUI's own view, so the one way to see it is to keep them.
STUB_TRACE_DIR="$trace_fixture" \
    run_script "render-trace --all-modules keeps SwiftUI's own views in the report" \
        "$render_trace" --report "$trace_run" --all-modules
report="$(cat "$trace_run/report.md" 2>/dev/null || true)"
if expect_status 0 \
    && expect_contains "$report" "8 bodies of every view" "the report" \
    && expect_contains "$report" "| MainMenuItemHost.RootView | 1 |" "the per-view table"; then
    pass
fi

run_script "render-trace refuses to run without being told what to run" \
    "$render_trace" --device "iPhone 17 Pro"
if expect_status 2 \
    && expect_contains "$output" "Name what to run" "the error" \
    && expect_absent "$calls" "xctrace" "the recorded calls"; then
    pass
fi

run_script "render-trace --report refuses a test selection it would ignore" \
    "$render_trace" --report "$trace_run" --test testOne
if expect_status 2 && expect_contains "$output" "does not take a test selection" "the error"; then
    pass
fi

run_script "render-trace --report refuses a directory that holds no recording" \
    "$render_trace" --report "$work"
if expect_status 2 && expect_contains "$output" "holds no render.trace and run.xcresult" "the error"; then
    pass
fi

run_script "render-trace refuses a baseline that is not there" \
    "$render_trace" --report "$trace_run" --baseline "$work/no-such.tsv"
if expect_status 2 && expect_contains "$output" "No baseline at" "the error"; then
    pass
fi

# The kernel trace facility is one lock per machine: a second recording fails
# to start, but only after posting the notice the script waits for, and would
# have the tests run for nothing. A process that reads as a recording — this
# stand-in, or another session's real one — is refused before anything runs.
(exec -a "xctrace record --stand-in" sleep 60) &
stand_in=$!
STUB_DEVICES="$work/devices-two-booted.txt" \
    run_script "render-trace refuses to start while another recording holds the machine" \
        "$render_trace" --test "$recording_test" --device "iPhone 17 Pro" --output "$work/second-recording"
kill "$stand_in" 2>/dev/null || true
wait "$stand_in" 2>/dev/null || true
if expect_status 1 \
    && expect_contains "$output" "Another Instruments recording is running" "the error" \
    && expect_absent "$calls" "xcodebuild" "the recorded calls"; then
    pass
fi

# xctrace will not write over a trace and xcodebuild will not write over a
# result bundle, so an earlier run's directory is refused before Instruments
# is started rather than failing half-way through a run.
STUB_DEVICES="$work/devices-two-booted.txt" \
    run_script "render-trace refuses an output that already holds a recording" \
        "$render_trace" --test "$recording_test" --device "iPhone 17 Pro" --output "$trace_run"
if expect_status 2 \
    && expect_contains "$output" "already holds a recording" "the error" \
    && expect_absent "$calls" "xctrace record" "the recorded calls" \
    && expect_absent "$calls" "xcodebuild" "the recorded calls"; then
    pass
fi

echo
if (( failures > 0 )); then
    echo "$failures case(s) failed." >&2
    exit 1
fi
echo "String extraction guard"
current="the source extraction guard rejects hidden copy and accepts localized helpers"
if "$repository_root/Scripts/check-string-extraction.sh" --self-test; then
    pass
else
    fail "the source extraction fixtures failed"
    exit 1
fi

echo "All script smoke tests passed."
