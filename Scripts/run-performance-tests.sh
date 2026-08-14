#!/usr/bin/env bash
#
# Runs the performance UI automation and turns it into a report.
#
# The measurement itself lives in OpenTrailsUITests/PerformanceUITests.swift.
# This script exists for the two halves of it that cannot happen inside a test
# process: booting a clean simulator with no leftover simulated location, and
# retrieving the event files the app wrote into its own container afterwards.
#
# A Debug build is mandatory, not incidental: RenderSignpost, PerformanceLog
# and MainThreadWatchdog all compile away in Release, so a Release run would
# report an app that does nothing at all.

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$repository_root/OpenTrails.xcodeproj"
scheme="OpenTrailsUI"
bundle="OpenTrailsUITests"
suite="PerformanceUITests"
app_bundle_id="tappium.com.OpenTrails"

device="${OPENTRAILS_SIMULATOR_NAME:-iPhone 17 Pro}"
test_name=""
output_root="$repository_root/PerformanceReports"
keep_going=false

usage() {
    cat <<EOF
Usage: Scripts/run-performance-tests.sh [options]

Runs $bundle/$suite against a simulator, pulls the app's
performance event files out of its container, and writes a markdown report.

Options:
  --device <name>     Simulator name (default: $device)
  --test <name>       Run one test method instead of the whole suite
  --output <dir>      Where reports are written (default: PerformanceReports)
  --keep-going        Still write a report when a test fails
  --list              List the available test methods
  -h, --help          Show this help

Examples:
  Scripts/run-performance-tests.sh
  Scripts/run-performance-tests.sh --test testLiveRecordingCostPerFix
EOF
}

list_tests() {
    sed -nE 's/^[[:space:]]*func (test[A-Za-z0-9_]+)\(\).*/\1/p' \
        "$repository_root/$bundle/$suite.swift"
}

require_value() {
    if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "Missing value for $1." >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            require_value "$1" "${2:-}"
            device="$2"
            shift 2
            ;;
        --test)
            require_value "$1" "${2:-}"
            test_name="$2"
            shift 2
            ;;
        --output)
            require_value "$1" "${2:-}"
            output_root="$2"
            shift 2
            ;;
        --keep-going)
            keep_going=true
            shift
            ;;
        --list)
            list_tests
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

command -v xcodebuild >/dev/null 2>&1 || {
    echo "xcodebuild is required. Install Xcode first." >&2
    exit 1
}

only_testing="$bundle/$suite"
if [[ -n "$test_name" ]]; then
    if ! list_tests | grep -qx "$test_name"; then
        echo "Unknown test: $test_name" >&2
        list_tests >&2
        exit 2
    fi
    only_testing="$bundle/$suite/$test_name"
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
run_directory="$output_root/$timestamp"
mkdir -p "$run_directory/events"
build_log="$run_directory/xcodebuild.log"

echo "Simulator: $device"
echo "Running:   $only_testing"
echo "Report:    $run_directory"

# UI automation drives Core Location, so a location left over from
# Scripts/simulate-hike.sh would fight the test for the simulator's position.
xcrun simctl location booted clear >/dev/null 2>&1 || true

# Granted out-of-band rather than through the permission dialog. A measurement
# run that silently collects nothing because an alert went unhandled is worse
# than one that fails, and the recording scenario has no fixes to measure
# without this — the test keeps its interruption monitor as a fallback for a
# simulator where the grant does not take.
xcrun simctl privacy booted grant location-always "$app_bundle_id" >/dev/null 2>&1 || true

status=0
set +e
xcodebuild test \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "platform=iOS Simulator,name=$device" \
    -only-testing:"$only_testing" \
    -resultBundlePath "$run_directory/result.xcresult" \
    2>&1 | tee "$build_log" \
    | grep -E "Test Case|PERF-|measured|error:|TEST (SUCCEEDED|FAILED)"
status="${PIPESTATUS[0]}"
set -e

# Pulled after the run rather than streamed during it: the app writes into its
# own container, which only exists on the simulator, and reading it while the
# app is up would catch a partially flushed batch.
container="$(xcrun simctl get_app_container booted "$app_bundle_id" data 2>/dev/null || true)"
if [[ -n "$container" && -d "$container/Documents/PerformanceLogs" ]]; then
    cp "$container/Documents/PerformanceLogs"/*.tsv "$run_directory/events/" 2>/dev/null || true
    echo "Collected $(ls -1 "$run_directory/events" | wc -l | tr -d ' ') event file(s)."
else
    echo "No event files found in the app container." >&2
fi

if (( status != 0 )) && [[ "$keep_going" == false ]]; then
    python3 "$repository_root/Scripts/perf-report.py" \
        --log "$build_log" \
        --events "$run_directory/events" \
        --out "$run_directory/report.md" || true
    echo "Performance tests failed. See $build_log and $run_directory/report.md." >&2
    exit "$status"
fi

python3 "$repository_root/Scripts/perf-report.py" \
    --log "$build_log" \
    --events "$run_directory/events" \
    --out "$run_directory/report.md"

echo "Report written to $run_directory/report.md"
