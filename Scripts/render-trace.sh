#!/usr/bin/env bash
#
# Runs UI tests under Instruments and reports which of the app's SwiftUI
# bodies each step of each test made it evaluate, and why.
#
# The render-isolation rules in .github/copilot-instructions.md were each
# measured once, by a harness that needed a signpost compiled into every body
# it counted. That harness is gone, and a rule nobody can re-measure is a rule
# that drifts. This measures the same thing without touching the app: the
# *View Body* instrument records every body SwiftUI evaluates, with its view
# type and duration, and *View Properties* records every `@State`,
# `@Environment`, `@Binding` and other dynamic property that changed, with the
# value it changed from and to. Both are Instruments' legacy SwiftUI
# instruments, and they are used rather than the current *SwiftUI* instrument
# because that one records nothing at all on a simulator — measured on Xcode
# 27.0: "Trace file had no SwiftUI data".
#
# The recording spans every process, because XCUITest launches the app — once
# per test, and a second time for the run's first test — and an attached
# recording would only ever see one of them. It spans more than that: SwiftUI's
# tracepoints are collected from every simulator on the machine, so the report
# keeps only the app processes this simulator ran, which are watched for while
# it records — see `watch_app_processes`. The app's own views are told apart
# from SwiftUI's by their module. Every body is then attributed to the UI-test
# step that was under way when it ran, using the wall-clock start of each
# activity in the result bundle; Scripts/lib/render-trace-report.swift does
# that and writes the report.
#
# A count is not a verdict. A step that pushes a screen evaluates every view on
# it, and should; a step that taps a toggle and re-evaluates the map screen's
# root has found something. The report says which properties changed to make
# each body run, and calls the rest *unexplained* — an `@Observable` it read,
# or a new value from its parent — which is where `Self._logChanges()` goes
# next. Compare a branch against main with --baseline rather than reading a
# number in isolation.
#
# Exit status:
#   0  the tests passed and the report was written
#   1  the recording or the report could not be made
#   2  bad arguments
#   anything else: the tests' own status, with the report written anyway

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/simulator.sh
source "$repository_root/Scripts/lib/simulator.sh"

device="${OPENHIKES_SIMULATOR_NAME:-iPhone 18 Pro}"
derived_data="${OPENHIKES_DERIVED_DATA:-}"
output=""
baseline=""
reanalyse=""
selection=()
# Empty means the app's own views only. See --all-modules.
module_filter=()
# Seconds to wait for Instruments to say it is recording. Its first start on a
# machine loads the instruments' packages and has been seen taking ten.
start_timeout=60

usage() {
    cat <<'EOF'
Usage: Scripts/render-trace.sh [options] (--test <name> | --suite <class> [--all] | --all)

Runs UI tests through Scripts/run-ui-tests.sh while Instruments records every
SwiftUI body the app evaluates, then writes report.md and bodies.tsv: per test,
per step, which of the app's views ran their body, how often, for how long, and
which dynamic property made them.

Options:
  --test <name>           One test method (as Scripts/run-ui-tests.sh --test)
  --suite <class>         One class; add --all to run all of it
  --all                   Every functional class, serially on one simulator
  --device <name|udid>    Simulator name or UDID (default: iPhone 18 Pro)
  --derived-data <path>   Build here instead of Xcode's shared derived data
  --output <dir>          Where the trace, result bundle and report go
                          (default: TestResults/render-trace/<timestamp>)
  --baseline <tsv>        Compare against an earlier run's bodies.tsv
  --all-modules           Report SwiftUI's and UIKit's own views as well,
                          which is where a closure SwiftUI runs for you — a
                          ScrollViewReader's, a GeometryReader's — is counted
  --report <dir>          Re-read an earlier run's trace and result bundle
                          instead of running anything; takes --baseline and
                          --all-modules
  -h, --help              Show this help

Examples:
  Scripts/render-trace.sh --test testImportsBundledGPXAndOpensItsDetails
  Scripts/render-trace.sh --suite PlaceUITests --all --device "$udid"
  Scripts/render-trace.sh --report TestResults/render-trace/branch \
    --baseline TestResults/render-trace/main/bodies.tsv
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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test|--suite)
            require_value "$1" "${2:-}"
            selection+=("$1" "$2")
            shift 2
            ;;
        --all)
            selection+=(--all)
            shift
            ;;
        --device)
            require_value "$1" "${2:-}"
            device="$2"
            shift 2
            ;;
        --derived-data)
            require_value "$1" "${2:-}"
            derived_data="$2"
            shift 2
            ;;
        --output)
            require_value "$1" "${2:-}"
            output="$2"
            shift 2
            ;;
        --baseline)
            require_value "$1" "${2:-}"
            baseline="$2"
            shift 2
            ;;
        --report)
            require_value "$1" "${2:-}"
            reanalyse="$2"
            shift 2
            ;;
        --all-modules)
            module_filter=(--module "")
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

if [[ -n "$baseline" && ! -f "$baseline" ]]; then
    echo "No baseline at $baseline." >&2
    exit 2
fi

analyse() {
    local directory="$1"
    local -a arguments=(
        --trace "$directory/render.trace"
        --result-bundle "$directory/run.xcresult"
        --output "$directory"
    )
    if [[ -n "$baseline" ]]; then
        arguments+=(--baseline "$baseline")
    fi
    if [[ -s "$directory/processes.txt" ]]; then
        arguments+=(--processes "$directory/processes.txt")
    fi
    arguments+=("${module_filter[@]+"${module_filter[@]}"}")
    swift "$repository_root/Scripts/lib/render-trace-report.swift" "${arguments[@]}" >/dev/null
    echo "Report: $directory/report.md"
    # The table every test shares, so a run says something without opening
    # the file: its heading, then its rows up to the first line that is not
    # one.
    awk '/^## Every test, by view/ { print; table = 1; next }
         table && /^\|/ { print; rows++; next }
         table && rows > 0 { exit }' "$directory/report.md" | head -n 24
}

if [[ -n "$reanalyse" ]]; then
    if (( ${#selection[@]} > 0 )); then
        echo "--report reads an earlier run; it does not take a test selection." >&2
        exit 2
    fi
    if [[ ! -d "$reanalyse/render.trace" || ! -d "$reanalyse/run.xcresult" ]]; then
        echo "$reanalyse holds no render.trace and run.xcresult to read." >&2
        exit 2
    fi
    analyse "$reanalyse"
    exit 0
fi

if (( ${#selection[@]} == 0 )); then
    echo "Name what to run: --test <name>, --suite <class> --all, or --all." >&2
    usage >&2
    exit 2
fi

for tool in xcrun notifyutil swift; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "$tool is required." >&2
        exit 1
    }
done

if ! device_udid="$(resolve_simulator_udid "$device")"; then
    exit 2
fi

if [[ -z "$output" ]]; then
    output="$repository_root/TestResults/render-trace/$(date +%Y%m%d-%H%M%S)"
fi
# xctrace will not write over a trace, and xcodebuild will not write over a
# result bundle; a directory holding either is an earlier run, not a target.
if [[ -e "$output/render.trace" || -e "$output/run.xcresult" ]]; then
    echo "$output already holds a recording. Name another --output." >&2
    exit 2
fi

# One recording a machine: the kernel trace facility these instruments read is
# a single lock, and a second `xctrace record` started while another holds it
# fails with "could not lock kperf" — after posting the notice this script
# waits for, so without this the tests would run for nothing and the report
# would say no body ran. Another session's recording is the usual holder.
#
# Anchored to the executable, because `-f` matches the whole command line: a
# shell whose command merely mentions the words — a `pgrep` for them, a loop
# that waits on a sweep — would otherwise read as a recording and refuse.
if holder="$(pgrep -f '(^|/)xctrace record' | head -n 1)" && [[ -n "$holder" ]]; then
    echo "Another Instruments recording is running (pid $holder)." >&2
    echo "Only one can hold the kernel's trace facility at a time; wait for it to finish." >&2
    exit 1
fi

mkdir -p "$output"

# Instruments records nothing from a simulator that is not up, and says so
# only by writing an empty trace.
xcrun simctl bootstatus "$device_udid" -b >/dev/null

xctrace_pid=""
waiter_pid=""
watcher_pid=""
stop_recording() {
    if [[ -n "$waiter_pid" ]]; then
        kill "$waiter_pid" 2>/dev/null || true
        waiter_pid=""
    fi
    if [[ -n "$xctrace_pid" ]]; then
        # SIGINT is Instruments' "stop and save"; anything harder loses the
        # trace.
        kill -INT "$xctrace_pid" 2>/dev/null || true
        wait "$xctrace_pid" 2>/dev/null || true
        xctrace_pid=""
    fi
    # It stops on its own once Instruments has, which is what it watches.
    if [[ -n "$watcher_pid" ]]; then
        wait "$watcher_pid" 2>/dev/null || true
        watcher_pid=""
    fi
}
trap stop_recording EXIT

# The process ids of this simulator's apps, for as long as the recording
# lasts. Instruments records SwiftUI's tracepoints from every simulator on the
# machine at once, so a second simulator running the app — another session's
# UI tests — would otherwise add its bodies to this report under the same
# names; the report keeps only the processes listed here. A simulator's apps
# are host processes started from under its own device directory, so the path
# says which simulator a process belongs to. Twice a second is enough: the
# shortest-lived app a test starts, the throwaway launch that absorbs the
# install, lives for seconds.
watch_app_processes() {
    # Through the environment rather than as an argument: `awk` is itself in
    # the process list it reads, and an argument holding the path would match
    # the very `awk` doing the matching.
    local marker="/Devices/$device_udid/data/Containers/Bundle/Application/"
    while kill -0 "$xctrace_pid" 2>/dev/null; do
        ps -axo pid=,command= \
            | MARKER="$marker" awk 'index($0, ENVIRON["MARKER"]) { print $1 }' \
            >> "$output/processes.txt"
        sleep 0.5
    done
}

# Started before Instruments so that it cannot miss the notice, which
# Instruments posts once and does not repeat.
notification="com.openhikes.render-trace.$$"
notifyutil -1 "$notification" >/dev/null &
waiter_pid=$!

xcrun xctrace record \
    --instrument 'View Body (Legacy)' \
    --instrument 'View Properties (Legacy)' \
    --device "$device_udid" \
    --all-processes \
    --no-prompt \
    --notify-tracing-started "$notification" \
    --output "$output/render.trace" \
    > "$output/xctrace.log" 2>&1 &
xctrace_pid=$!

waited=0
while kill -0 "$waiter_pid" 2>/dev/null; do
    if ! kill -0 "$xctrace_pid" 2>/dev/null; then
        echo "Instruments stopped before it began recording:" >&2
        cat "$output/xctrace.log" >&2
        xctrace_pid=""
        exit 1
    fi
    if (( waited >= start_timeout * 4 )); then
        echo "Instruments did not start recording within ${start_timeout}s:" >&2
        cat "$output/xctrace.log" >&2
        exit 1
    fi
    sleep 0.25
    waited=$((waited + 1))
done
waiter_pid=""

: > "$output/processes.txt"
watch_app_processes &
watcher_pid=$!

# Serial whatever the selection, because the recording is of this one device:
# a parallel run's clones are simulators Instruments is not watching.
#
# And retried, because under the recording a class's first launch after its
# fresh install occasionally fails before the app has a process at all —
# "Simulator device failed to launch … did not return a process handle nor
# launch error" — which four of 34 class runs did on 2026-10-08, every one the
# class's first test, and every one of those tests passing when run again. A
# retry re-runs failures only; the report names an earlier attempt apart, so
# it and a baseline read the attempt that counted.
ui_tests=(
    "$repository_root/Scripts/run-ui-tests.sh"
    --device "$device_udid"
    --serial
    --retry
    --result-bundle "$output/run.xcresult"
)
if [[ -n "$derived_data" ]]; then
    ui_tests+=(--derived-data "$derived_data")
fi
ui_tests+=("${selection[@]}")

test_status=0
"${ui_tests[@]}" || test_status=$?

stop_recording
sort -un -o "$output/processes.txt" "$output/processes.txt"

# A recording that failed still saves a trace, an empty one, and still exits
# 0. Its log is the only place that says so.
if grep -q 'Recording failed' "$output/xctrace.log"; then
    echo "Instruments did not record, so there is nothing to report:" >&2
    cat "$output/xctrace.log" >&2
    exit 1
fi

if [[ ! -d "$output/run.xcresult" ]]; then
    echo "The tests left no result bundle, so nothing can be attributed." >&2
    exit "$(( test_status == 0 ? 1 : test_status ))"
fi

analyse "$output"
exit "$test_status"
