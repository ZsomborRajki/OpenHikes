#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/xcodebuild-output.sh
source "$repository_root/Scripts/lib/xcodebuild-output.sh"
# shellcheck source=lib/simulator.sh
source "$repository_root/Scripts/lib/simulator.sh"
project="$repository_root/OpenHikes.xcodeproj"
scheme="OpenHikesUI"
bundle="OpenHikesUITests"
# Every functional class in the bundle. PerformanceUITests is deliberately
# absent: it lives here too, but it is measurement rather than automation and
# is run through Scripts/run-performance-tests.sh.
suites=(
  OpenHikesUITests
  RecordingUITests
  PhotoUITests
  SettingsUITests
  AccessibilityUITests
  AccessibilityLabelUITests
)
# Measurement rather than automation, so --all leaves them out: they assert
# nothing and only cost launches. Naming one explicitly still runs it.
measurement_tests=(OpenHikesUITests/testLaunchPerformance)
default_suite="RecordingUITests"
default_test="testReviewsSnappedRouteAfterStopping"

device="${OPENHIKES_SIMULATOR_NAME:-iPhone 17 Pro}"
test_name="$default_test"
suite=""
run_all=false
verbose=false
dry_run=false
retry=false
result_bundle=""

usage() {
    cat <<EOF
Usage: Scripts/run-ui-tests.sh [options]

Runs the simulator UI automation in $bundle. With no options it runs
$default_suite/$default_test, which records a short
simulated hike, reviews the snapped route, and saves it.

Functional classes: ${suites[*]}

PerformanceUITests lives in the same bundle but is measurement rather than
automation; run it through Scripts/run-performance-tests.sh instead.

Options:
  --device <name|udid>    Simulator name or UDID (default: $device)
  --suite <name>          Test class to run (default: $default_suite)
  --test <name>           Test method to run (default: $default_test)
  --all                   Run every functional test in every class
  --retry                 Re-run a failing test once (for CI)
  --result-bundle <path>  Write an .xcresult bundle for inspection
  --verbose               Show the full xcodebuild output
  --list                  List the available test methods
  --dry-run               Print the xcodebuild invocation and exit
  -h, --help              Show this help

Examples:
  Scripts/run-ui-tests.sh
  Scripts/run-ui-tests.sh --test testImportsBundledGPXAndOpensItsDetails
  Scripts/run-ui-tests.sh --suite AccessibilityUITests --all
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

# Test methods in one class, or in every functional class when given none.
list_tests() {
    local target_suites=("$@")
    if [[ ${#target_suites[@]} -eq 0 ]]; then
        target_suites=("${suites[@]}")
    fi
    local name
    for name in "${target_suites[@]}"; do
        # Every file the class is written across, not just the one named after
        # it: a suite that outgrows the type-body limit is split into
        # `Suite+Something.swift` extensions, and reading only `$name.swift`
        # made --list under-report and --test reject the name of a test that
        # exists. Scripts/run-performance-tests.sh reads its own suite the same
        # way, for the same reason.
        cat "$repository_root/$bundle/$name"*.swift \
            | sed -nE "s/^[[:space:]]*func (test[A-Za-z0-9_]+)\(\).*/$name\/\1/p" \
            | sort -u
    done
}

# The class a test method belongs to, so --test alone still works.
suite_for_test() {
    local wanted="$1"
    local entry
    while read -r entry; do
        if [[ "${entry#*/}" == "$wanted" ]]; then
            echo "${entry%%/*}"
            return 0
        fi
    done < <(list_tests)
    return 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            require_value "$1" "${2:-}"
            device="$2"
            shift 2
            ;;
        --suite)
            require_value "$1" "${2:-}"
            suite="$2"
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
        --retry)
            retry=true
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
            list_tests ${suite:+"$suite"}
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

if [[ -n "$suite" ]] && ! printf '%s\n' "${suites[@]}" | grep -qx "$suite"; then
    echo "Unknown suite: $suite" >&2
    echo "Available suites: ${suites[*]}" >&2
    exit 2
fi

command -v xcodebuild >/dev/null 2>&1 || {
    echo "xcodebuild is required. Install Xcode first." >&2
    exit 1
}

command -v xcrun >/dev/null 2>&1 || {
    echo "xcrun is required. Install the Xcode command-line tools first." >&2
    exit 1
}

if [[ ! -d "$project" ]]; then
    echo "Project not found: $project" >&2
    exit 1
fi

# Resolved once, and used for both the destination and the simctl call below.
# `name=` plus `simctl booted` let the test run and the location it clears
# belong to different devices whenever more than one simulator is up.
if ! device_udid="$(resolve_simulator_udid "$device")"; then
    exit 2
fi

# Scoped to the named classes rather than to the bundle, because the bundle
# also holds PerformanceUITests and the OpenHikesUI scheme autocreates its plan
# (so, unlike OpenHikes.xctestplan, it does not skip it).
only_testing=()
skip_testing=()
if [[ "$run_all" == true ]]; then
    if [[ -n "$suite" ]]; then
        only_testing=(-only-testing:"$bundle/$suite")
    else
        for name in "${suites[@]}"; do
            only_testing+=(-only-testing:"$bundle/$name")
        done
    fi
    # Only the ones inside the scope above, so xcodebuild is never handed a
    # skip for a class it was not asked to run.
    for entry in "${measurement_tests[@]}"; do
        if [[ -z "$suite" || "${entry%%/*}" == "$suite" ]]; then
            skip_testing+=(-skip-testing:"$bundle/$entry")
        fi
    done
else
    if [[ -z "$suite" ]]; then
        if ! suite="$(suite_for_test "$test_name")"; then
            echo "Unknown test: $test_name" >&2
            echo "Available tests:" >&2
            list_tests >&2
            exit 2
        fi
    elif ! list_tests "$suite" | grep -qx "$suite/$test_name"; then
        echo "Unknown test: $suite/$test_name" >&2
        echo "Available tests:" >&2
        list_tests "$suite" >&2
        exit 2
    fi
    only_testing=(-only-testing:"$bundle/$suite/$test_name")
fi

command=(
    xcodebuild test
    -project "$project"
    -scheme "$scheme"
    -destination "platform=iOS Simulator,id=$device_udid"
    # A machine that has not trusted SwiftLintPlugins' fingerprint — any fresh
    # CI runner — cannot build the app target without this.
    -skipPackagePluginValidation
    "${only_testing[@]}"
    "${skip_testing[@]+"${skip_testing[@]}"}"
)
if [[ "$retry" == true ]]; then
    command+=(-retry-tests-on-failure -test-iterations 2)
fi
if [[ -n "$result_bundle" ]]; then
    rm -rf "$result_bundle"
    command+=(-resultBundlePath "$result_bundle")
fi

echo "Scheme: $scheme"
echo "Simulator: $device ($device_udid)"
echo "Running: ${only_testing[*]#-only-testing:}"

if [[ "$dry_run" == true ]]; then
    printf '%q ' "${command[@]}"
    printf '\n'
    exit 0
fi

# UI automation drives Core Location, so a location left over from
# Scripts/simulate-hike.sh would fight the test for the simulator's position.
xcrun simctl location "$device_udid" clear >/dev/null 2>&1 || true

status=0
if [[ "$verbose" == true ]]; then
    "${command[@]}" || status=$?
else
    # The raw stream is kept because the formatter is allowed to drop lines:
    # --test testLaunchPerformance reports through `measured [Time, s]`, which
    # xcbeautify does not emit. See Scripts/lib/xcodebuild-output.sh.
    raw_log="$(mktemp -t openhikes-ui-tests)"
    trap 'rm -f "$raw_log"' EXIT

    set +e
    "${command[@]}" 2>&1 | format_xcodebuild_stream "$raw_log"
    status="${PIPESTATUS[0]}"
    set -e

    print_measurement_lines "$raw_log"
fi

if (( status != 0 )); then
    echo "UI tests failed. Re-run with --verbose for the full log." >&2
    exit "$status"
fi

echo "UI tests passed."
