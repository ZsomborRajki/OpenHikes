#!/usr/bin/env bash
#
# Runs the performance UI automation and turns it into a report.
#
# The measurement itself lives in OpenHikesUITests/PerformanceUITests.swift.
# This script exists for the two halves of it that cannot happen inside a test
# process: booting a clean simulator with no leftover simulated location, and
# retrieving the event files the app wrote into its own container afterwards.
#
# A Debug build is mandatory, not incidental: RenderSignpost, PerformanceLog
# and MainThreadWatchdog all compile away in Release, so a Release run would
# report an app that does nothing at all.

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/xcodebuild-output.sh
source "$repository_root/Scripts/lib/xcodebuild-output.sh"
# shellcheck source=lib/simulator.sh
source "$repository_root/Scripts/lib/simulator.sh"
project="$repository_root/OpenHikes.xcodeproj"
scheme="OpenHikesUI"
bundle="OpenHikesUITests"
suite="PerformanceUITests"
app_bundle_id="tappium.com.OpenHikes"

device="${OPENHIKES_SIMULATOR_NAME:-iPhone 17 Pro}"
test_name=""
output_root="$repository_root/PerformanceReports"
keep_going=false
# Each run keeps its own .xcresult, which is tens of megabytes, so the
# directory grows without bound and reached 1.6 GB before anything trimmed it.
# Ten is enough to compare a change against the runs around it and still notice
# a drift over an afternoon; older than that, the build it measured has moved
# on. Rename a run directory to keep it forever — pruning only ever considers
# the bare `YYYYMMDD-HHMMSS` names this script creates itself.
retained_runs="${OPENHIKES_PERFORMANCE_RETAINED_RUNS:-10}"
# Tracked, unlike the reports themselves: PerformanceReports/ is gitignored
# because it holds a machine's own measurements, whereas the baseline is the
# number the repository agrees on. It is absent until someone records one.
baseline="$repository_root/Scripts/performance-baseline.json"
update_baseline=false

usage() {
    cat <<EOF
Usage: Scripts/run-performance-tests.sh [options]

Runs $bundle/$suite against a simulator, pulls the app's
performance event files out of its container, and writes a markdown report.

Options:
  --device <name|udid> Simulator name or UDID (default: $device)
  --test <name>       Run one test method instead of the whole suite
  --output <dir>      Where reports are written (default: PerformanceReports)
  --keep <n>          Run directories to retain (default: $retained_runs)
  --baseline <file>   Counters to compare against (default: Scripts/performance-baseline.json)
  --update-baseline   Overwrite that file with this run's counters
  --keep-going        Still write a report when a test fails
  --list              List the available test methods
  -h, --help          Show this help

A baseline turns the report from a set of upper bounds into a diff, which is
the only way it notices a counter that *fell* — work that stopped happening
scores perfectly against every budget in the suite. Record one on a machine
that is otherwise idle, and re-record it deliberately rather than to make a
red report go away.

Examples:
  Scripts/run-performance-tests.sh
  Scripts/run-performance-tests.sh --test testLiveRecordingCostPerFix
  Scripts/run-performance-tests.sh --update-baseline
EOF
}

list_tests() {
    # Every PerformanceUITests file, not just the one named after the suite.
    # The scenarios have lived in extensions since the photo gallery landed,
    # so reading only `$suite.swift` made `--list` under-report and `--test`
    # reject the name of a test that exists.
    cat "$repository_root/$bundle/$suite"*.swift \
        | sed -nE 's/^[[:space:]]*func (test[A-Za-z0-9_]+)\(\).*/\1/p' \
        | sort -u
}

require_value() {
    if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "Missing value for $1." >&2
        exit 2
    fi
}

# Deletes the oldest runs so a directory of .xcresult bundles cannot grow
# without limit.
#
# Two deliberate limits on what it will touch. It reads only the immediate
# children of the output directory, so nothing outside the directory this
# script writes to is ever a candidate; and it matches only the bare
# `YYYYMMDD-HHMMSS` names the script produces, so a run somebody renamed —
# `20260814-171100-manual-memory`, say — is kept for good. Renaming is the way
# to say "keep this one".
prune_old_runs() {
    local root="$1"
    [[ -d "$root" ]] || return 0

    local -a runs=()
    local directory
    while IFS= read -r directory; do
        runs+=("$directory")
    done < <(
        find "$root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
            | grep -E '^[0-9]{8}-[0-9]{6}$' \
            | sort -r
    )

    (( ${#runs[@]} > retained_runs )) || return 0

    local removed=0
    for directory in "${runs[@]:$retained_runs}"; do
        rm -rf "${root:?}/${directory:?}"
        removed=$(( removed + 1 ))
    done
    echo "Pruned:    $removed older run(s), keeping the newest $retained_runs."
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
        --keep)
            require_value "$1" "${2:-}"
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "--keep takes a non-negative whole number, not '$2'." >&2
                exit 2
            fi
            retained_runs="$2"
            shift 2
            ;;
        --keep-going)
            keep_going=true
            shift
            ;;
        --baseline)
            require_value "$1" "${2:-}"
            baseline="$2"
            shift 2
            ;;
        --update-baseline)
            update_baseline=true
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

command -v xcrun >/dev/null 2>&1 || {
    echo "xcrun is required. Install the Xcode command-line tools first." >&2
    exit 1
}

# Resolved once, and used for the destination and for every simctl call below.
# `name=` plus `simctl booted` let the run, the location it clears, the
# permission it grants and the container it reads back belong to four
# different devices whenever more than one simulator is up — which is how a
# report gets assembled out of a device that ran nothing.
if ! device_udid="$(resolve_simulator_udid "$device")"; then
    exit 2
fi

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
# Before the new directory exists, so this run is never a candidate and the
# disk is freed before the .xcresult that needs it is written.
prune_old_runs "$output_root"
mkdir -p "$run_directory/events"
build_log="$run_directory/xcodebuild.log"

echo "Simulator: $device ($device_udid)"
echo "Running:   $only_testing"
echo "Report:    $run_directory"

# Booted here rather than left to xcodebuild, because the two simctl calls
# below need the device up: a privacy grant against a shut-down simulator does
# nothing, and the run would then measure an app that was never given location.
xcrun simctl boot "$device_udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$device_udid" -b >/dev/null 2>&1 || true

# UI automation drives Core Location, so a location left over from
# Scripts/simulate-hike.sh would fight the test for the simulator's position.
xcrun simctl location "$device_udid" clear >/dev/null 2>&1 || true

# Granted out-of-band rather than through the permission dialog. A measurement
# run that silently collects nothing because an alert went unhandled is worse
# than one that fails, and the recording scenario has no fixes to measure
# without this — the test keeps its interruption monitor as a fallback for a
# simulator where the grant does not take.
xcrun simctl privacy "$device_udid" grant location-always "$app_bundle_id" >/dev/null 2>&1 || true

# Emptied before the run, because a scenario log the app did not write this
# time is indistinguishable from one it did once the files are copied out.
# `perf-report.py` turns every .tsv in the events directory into a scenario,
# so anything an earlier run left behind is reported — with its own findings
# and its own "worst" number — as though this run had measured it. The
# container outlives a branch as well as a run: a `--test` of one scenario
# reported findings from eight it never drove, and a run on a branch without
# the walk scenario named `walk` as the worst of three. The app truncates its
# own file at launch, which covers a scenario that runs again and nothing else.
stale_logs="$(xcrun simctl get_app_container "$device_udid" "$app_bundle_id" data 2>/dev/null || true)"
if [[ -n "$stale_logs" && -d "$stale_logs/Documents/PerformanceLogs" ]]; then
    cleared="$(find "$stale_logs/Documents/PerformanceLogs" -maxdepth 1 -name '*.tsv' -print -delete | wc -l | tr -d ' ')"
    if (( cleared > 0 )); then
        echo "Cleared:   $cleared stale scenario log(s) left in the app container."
    fi
fi

status=0
set +e
# A machine that has not trusted SwiftLintPlugins' fingerprint — any fresh
# checkout that has never been opened in Xcode — cannot build the app target
# without -skipPackagePluginValidation. Same reason Scripts/run-ui-tests.sh and
# every xcodebuild call in .github/workflows/ci.yml carry it.
xcodebuild test \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$device_udid" \
    -only-testing:"$only_testing" \
    -resultBundlePath "$run_directory/result.xcresult" \
    -skipPackagePluginValidation \
    2>&1 | format_xcodebuild_stream "$build_log"
statuses=("${PIPESTATUS[@]}")
set -e
status="${statuses[0]}"

# The raw log is this script's product, not a side effect of printing one:
# print_measurement_lines re-emits from it and perf-report.py parses it, so a
# run that could not write it has no report to build and no measurements to
# show. xcodebuild's own status still comes first when both went wrong — it is
# the more useful of the two answers.
if (( statuses[1] != 0 )); then
    if (( status != 0 )); then
        echo "Performance tests failed, and $build_log could not be written." >&2
        exit "$status"
    fi
    echo "Performance tests ran, but $build_log could not be written, so this run measured nothing." >&2
    exit 1
fi

# xcbeautify does not emit `measured [...]` or the suite's PERF- markers, and
# those are what this script exists to produce. $build_log holds the raw
# stream either way, which is also what perf-report.py parses below.
print_measurement_lines "$build_log"

# Pulled after the run rather than streamed during it: the app writes into its
# own container, which only exists on the simulator, and reading it while the
# app is up would catch a partially flushed batch.
collected=0
container="$(xcrun simctl get_app_container "$device_udid" "$app_bundle_id" data 2>/dev/null || true)"
if [[ -z "$container" ]]; then
    echo "No container for $app_bundle_id on $device ($device_udid)." >&2
elif [[ ! -d "$container/Documents/PerformanceLogs" ]]; then
    echo "No PerformanceLogs directory in $container/Documents." >&2
else
    cp "$container/Documents/PerformanceLogs"/*.tsv "$run_directory/events/" 2>/dev/null || true
    collected="$(find "$run_directory/events" -maxdepth 1 -name '*.tsv' | wc -l | tr -d ' ')"
    echo "Collected $collected event file(s)."
fi

if (( status != 0 )) && [[ "$keep_going" == false ]]; then
    python3 "$repository_root/Scripts/perf-report.py" \
        --log "$build_log" \
        --events "$run_directory/events" \
        --out "$run_directory/report.md" || true
    echo "Performance tests failed. See $build_log and $run_directory/report.md." >&2
    exit "$status"
fi

report_arguments=(
    --log "$build_log"
    --events "$run_directory/events"
    --out "$run_directory/report.md"
)
# A single-method run measures a fraction of the counters, so every baseline
# entry it did not reach would be reported as having vanished. Comparing only
# a whole-suite run keeps "this counter was not reported" meaning what it says.
if [[ -z "$test_name" && -f "$baseline" ]]; then
    report_arguments+=(--baseline "$baseline")
fi
if [[ "$update_baseline" == true ]]; then
    report_arguments+=(--write-baseline "$baseline")
fi

python3 "$repository_root/Scripts/perf-report.py" "${report_arguments[@]}"

echo "Report written to $run_directory/report.md"

# A suite that measured nothing passes every budget in it, so a run with no
# scenario logs used to print one informational line and exit 0 — the shape of
# a green run, from a report with no measurements in it. --keep-going relaxes a
# failing test into a written report; it does not make an empty run a passing
# one.
if (( collected == 0 )); then
    echo "No scenario logs were collected, so this run measured nothing." >&2
    echo "Check that the suite ran against $device ($device_udid) and wrote to Documents/PerformanceLogs." >&2
    exit 1
fi

if [[ -z "$test_name" && ! -f "$baseline" && "$update_baseline" == false ]]; then
    echo "No baseline at $baseline — run again with --update-baseline to record one."
fi
