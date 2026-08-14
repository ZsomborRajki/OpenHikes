#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$repository_root/OpenTrails.xcodeproj"
scheme="OpenTrailsUI"
bundle="OpenTrailsUITests"
suite="OpenTrailsUITests"
default_test="testReviewsSnappedRouteAfterStopping"

device="${OPENTRAILS_SIMULATOR_NAME:-iPhone 17 Pro}"
test_name="$default_test"
run_all=false
verbose=false
dry_run=false
result_bundle=""

usage() {
    cat <<EOF
Usage: Scripts/run-ui-tests.sh [options]

Runs the simulator UI automation in $suite. With no options it runs
$default_test, which records a short simulated
hike, reviews the snapped route, and saves it.

PerformanceUITests lives in the same bundle but is measurement rather than
automation; run it through Scripts/run-performance-tests.sh instead.

Options:
  --device <name>         Simulator name (default: $device)
  --test <name>           Test method to run (default: $default_test)
  --all                   Run every functional test in $suite
  --result-bundle <path>  Write an .xcresult bundle for inspection
  --verbose               Show the full xcodebuild output
  --list                  List the available test methods
  --dry-run               Print the xcodebuild invocation and exit
  -h, --help              Show this help

Examples:
  Scripts/run-ui-tests.sh
  Scripts/run-ui-tests.sh --test testImportsBundledGPXAndOpensItsDetails
  Scripts/run-ui-tests.sh --all --device 'iPhone 17'
EOF
}

require_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        echo "Missing value for $option." >&2
        usage >&2
        exit 2
    fi
}

list_tests() {
    sed -nE 's/^[[:space:]]*func (test[A-Za-z0-9_]+)\(\).*/\1/p' \
        "$repository_root/$bundle/$suite.swift"
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
        --all)
            run_all=true
            shift
            ;;
        --result-bundle)
            require_value "$1" "${2:-}"
            result_bundle="$2"
            shift 2
            ;;
        --verbose)
            verbose=true
            shift
            ;;
        --list)
            list_tests
            exit 0
            ;;
        --dry-run)
            dry_run=true
            shift
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

if [[ ! -d "$project" ]]; then
    echo "Project not found: $project" >&2
    exit 1
fi

only_testing="$bundle/$suite"
if [[ "$run_all" == false ]]; then
    if ! list_tests | grep -qx "$test_name"; then
        echo "Unknown test: $test_name" >&2
        echo "Available tests:" >&2
        list_tests >&2
        exit 2
    fi
    only_testing="$bundle/$suite/$test_name"
fi

command=(
    xcodebuild test
    -project "$project"
    -scheme "$scheme"
    -destination "platform=iOS Simulator,name=$device"
    -only-testing:"$only_testing"
)
if [[ -n "$result_bundle" ]]; then
    rm -rf "$result_bundle"
    command+=(-resultBundlePath "$result_bundle")
fi

echo "Scheme: $scheme"
echo "Simulator: $device"
echo "Running: $only_testing"

if [[ "$dry_run" == true ]]; then
    printf '%q ' "${command[@]}"
    printf '\n'
    exit 0
fi

# UI automation drives Core Location, so a location left over from
# Scripts/simulate-hike.sh would fight the test for the simulator's position.
xcrun simctl location booted clear >/dev/null 2>&1 || true

status=0
if [[ "$verbose" == true ]]; then
    "${command[@]}" || status=$?
else
    set +e
    "${command[@]}" 2>&1 \
        | grep -E \
            "Test Case|Test Suite .* (passed|failed)|error:|TEST (SUCCEEDED|FAILED)|measured"
    status="${PIPESTATUS[0]}"
    set -e
fi

if (( status != 0 )); then
    echo "UI tests failed. Re-run with --verbose for the full log." >&2
    exit "$status"
fi

echo "UI tests passed."
