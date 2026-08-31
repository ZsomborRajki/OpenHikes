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
#
# `xcrun`, `xcodebuild`, `python3` and `swiftlint` are replaced with recording
# stubs on PATH and the scripts are run for real against them. Nothing is built,
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

Runs the repository's shell scripts against stubbed xcrun/xcodebuild/swiftlint
and asserts what they sent where.

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

echo
if (( failures > 0 )); then
    echo "$failures case(s) failed." >&2
    exit 1
fi
echo "All script smoke tests passed."
