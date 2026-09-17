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
# Every functional class in the bundle.
suites=(
  OpenHikesUITests
  OrientationUITests
  RecordingUITests
  WalkUITests
  PhotoUITests
  SettingsUITests
  CommunityUITests
  CommunityCuratedUITests
  CommunityPhotoUITests
  CommunityReviewUITests
  AccessibilityUITests
  AccessibilityLabelUITests
)
# Measurement rather than automation, so --all leaves them out: they assert
# nothing and only cost launches. Naming one explicitly still runs it.
measurement_tests=(OpenHikesUITests/testLaunchPerformance)

# Tests that lose to a busy machine rather than to a bug, pinned to a run of
# their own on the one simulator.
#
# What put them here is a shape rather than a hunch. In a three-clone `--all`
# each of these failed on a *timeout* — 30s, 30s and 47.9s against 20.8s, 16.1s
# and 30.1s for the same tests serially — and every one of them was the first or
# second test its clone ran, while three simulators were booting, installing and
# first-launching the app at once. Run on their own they pass; run behind that
# stampede they wait too long for something and give up.
#
# So this list is about *when* a test runs, not about the test being wrong. Two
# consequences follow, and both matter more than the names below:
#
#   - **A test that fails serially does not belong here.** Pinning it would
#     convert a real failure into a slower real failure, and hide it behind a
#     mechanism labelled "flaky". Check with
#     `--suite <class> --test <name>` before adding anything.
#   - **The list cannot be complete, and chasing completeness is the wrong
#     instinct.** What flakes is whatever runs while the clones are cold, so a
#     name taken off the front of the queue is replaced by the next one along.
#     `--retry` is the general answer and this is the specific one; if a test
#     keeps failing the parallel pass even with a retry, pin it here.
#
# They run after the parallel pass, on the device this script resolved, in one
# serial `xcodebuild` of their own. Sequential runs against one simulator are
# fine — it is two *concurrent* ones that install over each other, which is why
# the fan-out below uses clones.
#
# **It is a mitigation and not a guarantee, and one of these has already shown
# why.** `testBlockedHikersSectionPassesAccessibilityAudit` failed its first
# attempt inside this very pass and passed on the retry, because the machine is
# still settling when the clones have only just gone. What actually rescues a
# run is the retry — a second attempt lands on a warm app and passes in half
# the time — so read this list as *spend fewer retries*, never as *these are
# handled*.
serial_tests=(
  AccessibilityUITests/testBlockedHikersSectionPassesAccessibilityAudit
  RecordingUITests/testDiscardingARecordingSavesNothing
  RecordingUITests/testPausingAndResumingARecording
)
default_suite="RecordingUITests"
default_test="testReviewsSnappedRouteAfterStopping"
# Three, not "one per core". xcodebuild spreads whole *classes*, so the floor of
# a parallel run is the longest single class, and RecordingUITests is 274s of a
# 787s serial `--all`. Three workers already reach that floor (787/3 = 262s);
# a fourth only adds a simulator to boot, install into and contend with. The
# shape holds wherever one class dominates, which is why the number is a
# considered default rather than a function of `sysctl hw.ncpu`. It is what a
# bare `--all` uses; `--parallel N` overrides it and `--serial` turns it off.
default_parallel_workers=3

device="${OPENHIKES_SIMULATOR_NAME:-iPhone 18 Pro}"
# Where the build lands. Empty means Xcode's shared derived-data
# directory, which is what one session wants and what every command in this
# repository has always used.
#
# It is an option because that directory is the one thing two runs cannot
# quietly share. A second `xcodebuild` against the same project and the same
# derived data waits on the first one's build lock, prints nothing while it
# waits, and cannot be told apart from a hang: one run here compiled the UI
# bundle and then produced no test result for the better part of an hour,
# with no error and no output. `--device` is that answer for the simulator;
# this is it for the build, and the pair is what makes a second session on
# this machine possible at all.
derived_data="${OPENHIKES_DERIVED_DATA:-}"
test_name="$default_test"
suite=""
run_all=false
verbose=false
dry_run=false
retry=false
# Whether the caller said either way, so the default below can tell "not asked"
# from "asked for off".
retry_set=false
result_bundle=""
parallel_workers=""
serial=false
# Whether this run claims the simulator it resolves. See
# `acquire_device_lock`.
device_lock=true
# Where those claims are recorded: outside the repository, because a lock
# file inside it is lintable material and would reach the working tree, and
# under a stable per-user path rather than $TMPDIR, because the run it has to
# be visible to is in another terminal. The variable exists so
# Scripts/run-script-tests.sh can exercise this without writing into the home
# directory of whoever runs it.
device_lock_root="${OPENHIKES_UI_TEST_LOCK_DIR:-${HOME:-/tmp}/Library/Caches/OpenHikes/ui-test-locks}"
# The lock this run holds, so the cleanup trap knows whether to release one.
held_device_lock=""

usage() {
    cat <<EOF
Usage: Scripts/run-ui-tests.sh [options]

Runs the simulator UI automation in $bundle. With no options it runs
$default_suite/$default_test, which records a short
simulated hike, reviews the snapped route, and saves it.

Functional classes: ${suites[*]}

A parallel --all runs in two passes: the classes across simulator clones, then
the tests in \`serial_tests\` on their own, on this one simulator. They are
pinned there because they fail on a timeout while the clones are still booting
and pass when the machine is quiet — see the comment on that list, including
why a test that fails serially must not be added to it.
Pinned now: ${serial_tests[*]}

Two runs cannot share a simulator, and they cannot share a derived-data
directory either: the first collision arrives as tests killed mid-gesture, the
second as a run that prints nothing for an hour. So a run claims the device it
resolved and refuses to start on one another run holds. Give a second session
its own with --device, and its own build with --derived-data.

Options:
  --device <name|udid>    Simulator name or UDID (default: $device)
  --suite <name>          Test class to run (default: $default_suite)
  --test <name>           Test method to run (default: $default_test)
  --all                   Run every functional test in every class
  --retry                 Re-run a failing test once (on by default for --all)
  --no-retry              Turn that off, so a flake fails the run
  --parallel [N]          Override the worker count (needs --all without --suite)
  --serial                Run in one simulator, the way --all used to
  --result-bundle <path>  Write an .xcresult bundle for inspection
  --derived-data <path>   Build here instead of Xcode's shared derived data
  --no-device-lock        Start even when another run holds this simulator
  --verbose               Show the full xcodebuild output
  --list                  List the available test methods
  --dry-run               Print the xcodebuild invocation and exit
  -h, --help              Show this help

Examples:
  Scripts/run-ui-tests.sh
  Scripts/run-ui-tests.sh --test testImportsBundledGPXAndOpensItsDetails
  Scripts/run-ui-tests.sh --suite AccessibilityUITests --all
  Scripts/run-ui-tests.sh --all --device 'iPhone 17'
  Scripts/run-ui-tests.sh --all --serial
  Scripts/run-ui-tests.sh --all --device OH-second --derived-data .dd-second
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
        # exists.
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

# Says who has the device, in the terms the collision would otherwise be
# reported in — which is to say, not at all.
refuse_busy_device() {
    local holder="$1"
    echo "Another UI-test run (pid $holder) is using $device ($device_udid)." >&2
    echo "Two xcodebuild runs cannot share a simulator: the second install tears" >&2
    echo "the first run's app out from under it, and the failure lands on" >&2
    echo "whichever test happened to be executing, with no assertion and no" >&2
    echo "diagnostic." >&2
    echo "Wait for that run, pass --device <name|udid> to use another simulator," >&2
    echo "or --no-device-lock to start anyway." >&2
}

# Claims $device_udid for this run, or explains who has it and fails.
#
# `mkdir` rather than a test followed by a write, because creating a directory
# is one atomic step and failing it is how the second run finds out. A test and
# a write are two steps with a window between them, and that window is the case
# this exists for: two runs started seconds apart.
#
# The PID inside is what makes a lock recoverable rather than permanent. A run
# killed part-way leaves its claim behind — the same way it leaves simulator
# clones behind — so a holder that is gone is cleared and the claim retaken,
# and only a holder that is still alive refuses the run.
#
# The guard is a courtesy and the tests are the job: a machine that cannot
# write the lock at all gets a warning and its run, not an error.
acquire_device_lock() {
    local lock="$device_lock_root/$device_udid.lock"
    if ! mkdir -p "$device_lock_root" 2>/dev/null; then
        echo "Could not record a device lock under $device_lock_root." >&2
        echo "Continuing without one; nothing here will notice a second run." >&2
        return 0
    fi

    if mkdir "$lock" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock/pid"
        held_device_lock="$lock"
        return 0
    fi

    local holder
    holder="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
        refuse_busy_device "$holder"
        return 1
    fi

    rm -rf "$lock"
    if mkdir "$lock" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock/pid"
        held_device_lock="$lock"
        return 0
    fi
    refuse_busy_device "${holder:-unknown}"
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
        --no-retry)
            retry=false
            retry_set=true
            shift
            ;;
        --retry)
            retry=true
            retry_set=true
            shift
            ;;
        --parallel)
            # The count is optional, so the next argument is only consumed when
            # it looks like one. `--parallel --all` must not swallow `--all`.
            if [[ -n "${2:-}" && "$2" != -* ]]; then
                if [[ ! "$2" =~ ^[0-9]+$ ]] || (( $2 < 2 )); then
                    echo "--parallel takes a worker count of 2 or more, not '$2'." >&2
                    exit 2
                fi
                parallel_workers="$2"
                shift 2
            else
                parallel_workers="$default_parallel_workers"
                shift
            fi
            ;;
        --serial)
            serial=true
            shift
            ;;
        --result-bundle)
            require_value "$1" "${2:-}"
            result_bundle="$2"
            shift 2
            ;;
        --derived-data)
            require_value "$1" "${2:-}"
            derived_data="$2"
            shift 2
            ;;
        --no-device-lock)
            device_lock=false
            shift
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

if [[ "$serial" == true && -n "$parallel_workers" ]]; then
    echo "--serial and --parallel contradict each other; pass one." >&2
    exit 2
fi

# xcodebuild distributes test *classes*, never the methods inside one, so a run
# already scoped to a single class or a single method has nothing to spread:
# the extra clones boot, install the app and sit idle, and the run gets slower
# rather than faster. An explicit --parallel that cannot be honoured is refused
# rather than quietly downgraded. A run that announced "3 workers" and served
# one is the same kind of quiet wrong answer as a report assembled from a device
# the tests never touched, which is what lib/simulator.sh exists to stop, and it
# would be discovered as "parallel testing did nothing for us".
if [[ -n "$parallel_workers" ]] && { [[ "$run_all" != true ]] || [[ -n "$suite" ]]; }; then
    echo "--parallel needs --all without --suite." >&2
    echo "xcodebuild spreads whole classes, so one class or one test cannot be spread." >&2
    exit 2
fi

# A bare `--all` is the run worth making fast — thirteen minutes serial against
# 5m49s across three clones — and it is the line every document already tells a
# contributor to run, so it parallelises without being asked. `--serial` is the
# way back. Everything narrower stays serial with no comment, because there is
# genuinely nothing to spread; that is also what keeps CI untouched, since the
# `accessibility-ui-tests` job always passes `--suite`.
if [[ -z "$parallel_workers" && "$serial" != true ]] \
    && [[ "$run_all" == true && -z "$suite" ]]; then
    parallel_workers="$default_parallel_workers"
fi

# And the same run retries its failures, for the reason it fans out: three
# clones booting, installing and first-launching at once make the machine slow
# enough that a test with a tight wait gives up, and the evidence for that is
# specific rather than general — in one such run the failures were each clone's
# first or second test, every one of them on a timeout, and every one passing on
# its own afterwards.
#
# `serial_tests` pins the ones seen doing it; this covers the ones that have not
# been seen yet, and the difference is why both exist. Pinning three names
# demonstrably promotes whatever was fourth: the run that first passed with the
# list in place failed `testRetryingASaveThatFailedOnce` instead — a name that
# had never failed, at the front of a cold clone, on a timeout, passing on its
# own. A list of names cannot converge on a problem that is about position in a
# queue, so the list is the specific answer and this is the general one.
#
# It costs nothing on a green run: `-retry-tests-on-failure` re-runs failures
# and only failures. What it costs on a red one is one extra go at a genuinely
# broken test, which `--no-retry` turns off. Narrower runs are left alone —
# nothing is contending for anything, so a retry there would only make a real
# failure take twice as long to report.
if [[ "$retry_set" != true && "$run_all" == true && -z "$suite" && "$serial" != true ]]; then
    retry=true
fi

# Both things a run leaves on the machine, released together and early: the
# trap is installed before either is taken, so there is no window in which this
# holds a device lock and has nothing to give it back.
raw_log=""
release_run_state() {
    if [[ -n "$raw_log" ]]; then
        rm -f "$raw_log" || true
    fi
    if [[ -n "$held_device_lock" ]]; then
        rm -rf "$held_device_lock" || true
    fi
}
trap release_run_state EXIT

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

# Scoped to the named classes rather than to the bundle, so a class that is in
# the bundle but not in the list above is never picked up by accident.
only_testing=()
skip_testing=()
# What the serial pass will run, filled in below. Empty for every invocation
# that is not a parallel `--all`, which is what makes that pass conditional.
pinned_testing=()
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
    # The pinned ones come out of this pass and go into a serial one after it —
    # see `serial_tests`. Only when this pass is actually parallel, which is
    # what `parallel_workers` being set means and is why this reads that rather
    # than `--serial`: a suite-scoped `--all` is refused parallelism too, and it
    # is already the quiet run these were pinned for. Splitting it would cost a
    # second build and launch to buy nothing.
    if [[ -n "$parallel_workers" ]]; then
        for entry in "${serial_tests[@]}"; do
            if [[ -z "$suite" || "${entry%%/*}" == "$suite" ]]; then
                skip_testing+=(-skip-testing:"$bundle/$entry")
                pinned_testing+=(-only-testing:"$bundle/$entry")
            fi
        done
    fi
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

# Everything both passes share. The scoping flags and the fan-out are added
# per pass below, because that is the entirety of what makes them different
# runs: same project, same scheme, same device.
base_command=(
    xcodebuild test
    -project "$project"
    -scheme "$scheme"
    -destination "platform=iOS Simulator,id=$device_udid"
    # A machine that has not trusted SwiftLintPlugins' fingerprint — any fresh
    # CI runner — cannot build the app target without this.
    -skipPackagePluginValidation
)
if [[ -n "$derived_data" ]]; then
    base_command+=(-derivedDataPath "$derived_data")
fi
if [[ "$retry" == true ]]; then
    base_command+=(-retry-tests-on-failure -test-iterations 2)
fi

command=(
    "${base_command[@]}"
    "${only_testing[@]}"
    "${skip_testing[@]+"${skip_testing[@]}"}"
)
# Clones, not a second xcodebuild against the same device. The distinction is
# the whole reason this is safe: two `xcodebuild test` runs sharing a simulator
# install the same bundle identifier over each other, which is the failure the
# instructions file describes at length. Here xcodebuild owns the fan-out, each
# worker gets its own cloned device, and the clones are made *from* the device
# resolved above — so the location cleared below, and any `simctl privacy` grant
# made before this script runs, are inherited rather than bypassed.
#
# The clones live in their own device set, `~/Library/Developer/XCTestDevices`,
# named `Clone N of <device>`, and `xcodebuild` deletes them when the run ends
# (verified on Xcode 26.6: three during the run, none after). Two consequences
# worth knowing: `simctl list devices` never shows them, so they cannot make
# `resolve_simulator_udid` ambiguous, and a run killed part-way can leave some
# behind. That set is the only place to look for them:
#
#   xcrun simctl --set ~/Library/Developer/XCTestDevices list devices
if [[ -n "$parallel_workers" ]]; then
    command+=(
        -parallel-testing-enabled YES
        -parallel-testing-worker-count "$parallel_workers"
    )
fi
if [[ -n "$result_bundle" ]]; then
    command+=(-resultBundlePath "$result_bundle")
fi

echo "Scheme: $scheme"
echo "Simulator: $device ($device_udid)"
if [[ -n "$derived_data" ]]; then
    echo "Derived data: $derived_data"
fi
echo "Running: ${only_testing[*]#-only-testing:}"
if [[ -n "$parallel_workers" ]]; then
    echo "Workers: $parallel_workers simulator clones"
fi

if [[ "$dry_run" == true ]]; then
    printf '%q ' "${command[@]}"
    printf '\n'
    # The second invocation too, because it is a second thing that will run and
    # a mode whose whole job is to say what will run must not leave it out.
    if (( ${#pinned_testing[@]} > 0 )); then
        printf '%q ' "${base_command[@]}" "${pinned_testing[@]}"
        printf '\n'
    fi
    exit 0
fi

# Past the dry run deliberately: a mode whose whole job is to print what would
# happen must not claim a device, and it touches nothing that a concurrent run
# could disturb.
if [[ "$device_lock" == true ]] && ! acquire_device_lock; then
    exit 2
fi

# xcodebuild refuses to write over an existing bundle, so a stale one has to go
# first. It happens here, past the dry-run exit above, because a mode that only
# prints its invocation must leave the path the caller named exactly as it was.
if [[ -n "$result_bundle" ]]; then
    rm -rf "$result_bundle"
fi

# UI automation drives Core Location, so a location left over from
# Scripts/simulate-hike.sh would fight the test for the simulator's position.
xcrun simctl location "$device_udid" clear >/dev/null 2>&1 || true

# The raw stream is kept because the formatter is allowed to drop lines:
# --test testLaunchPerformance reports through `measured [Time, s]`, which
# xcbeautify does not emit. See Scripts/lib/xcodebuild-output.sh.
#
# Created once and reused by both passes: what it is for is the output of the
# invocation that just ran, and the second pass has already had the first one's
# read out of it.
if [[ "$verbose" != true ]]; then
    raw_log="$(mktemp -t openhikes-ui-tests)"
fi

# The tests a pass ended up failing, and the ones that only passed on a second
# attempt, named together underneath it.
#
# A run's verdict arrives as an exit code and one trailing sentence. What the
# formatter prints on the way there is a tick per test and a single mark for a
# failure, so a hundred green lines can carry one red one nobody sees — which
# is exactly how two red tests sat on `main` for days, each found by somebody
# reading a result bundle rather than the run. A parallel run makes it worse
# rather than better: three clones write into one terminal, interleaved.
#
# The retried ones are printed on a green run too, and over time that is the
# more useful half. `-retry-tests-on-failure` makes a test that failed once and
# passed once indistinguishable from one that always passes, which is how a
# suite fills up with tests that only work on the second go.
print_test_outcomes() {
    local raw_log="$1"

    [[ -f "$raw_log" ]] || return 0

    # xcodebuild has two spellings for this, and they share nothing but the
    # words:
    #
    #   Test Case '-[OpenHikesUITests.RecordingUITests testSomething]' passed (12.0 seconds).
    #   Test case 'RecordingUITests.testSomething()' passed on 'Clone 1 of X' (12.0 seconds).
    #
    # The first is what a serial run prints; the second is what a parallel one
    # does, in different case, with no bundle, no brackets and the method
    # carrying its own parentheses. Both are reduced to
    # `RecordingUITests/testSomething passed`.
    #
    # Measured rather than assumed, and the measurement is the reason this
    # reads both: one serial run of this bundle printed six of the first form
    # and none of the second, and a parallel one fifteen of the second and none
    # of the first. A summary that knew only the serial spelling would be
    # silent in exactly the run it exists for — which is also why the fallback
    # output filter in lib/xcodebuild-output.sh shows no test lines at all in a
    # parallel run: its pattern is the capitalised one.
    local outcomes
    outcomes="$(
        sed -nE \
            -e "s/.*Test Case '-\\[[A-Za-z0-9_]+\\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\\]' (passed|failed).*/\\1\\/\\2 \\3/p" \
            -e "s/.*Test case '([A-Za-z0-9_]+)\\.([A-Za-z0-9_]+)\\(\\)' (passed|failed).*/\\1\\/\\2 \\3/p" \
            "$raw_log"
    )"
    [[ -n "$outcomes" ]] || return 0

    # Every verdict a test got, gathered under its name: one with no `passed`
    # among them failed, and one with both was retried.
    local failed retried
    failed="$(
        printf '%s\n' "$outcomes" \
            | awk '{ seen[$1] = seen[$1] " " $2 }
                   END { for (test in seen) if (seen[test] !~ /passed/) print "  " test }' \
            | sort
    )"
    retried="$(
        printf '%s\n' "$outcomes" \
            | awk '{ seen[$1] = seen[$1] " " $2 }
                   END {
                       for (test in seen)
                           if (seen[test] ~ /passed/ && seen[test] ~ /failed/) print "  " test
                   }' \
            | sort
    )"

    [[ -z "$failed" ]] || printf '\nFailed:\n%s\n' "$failed"
    [[ -z "$retried" ]] || printf '\nPassed on a retry:\n%s\n' "$retried"
}

# One xcodebuild, formatted or raw.
#
# Sets `status` and `raw_log_status` rather than returning them, because they
# are two different facts — whether the tests passed, and whether the log they
# passed in survived — and a caller has to be able to tell them apart.
run_xcodebuild() {
    local -a invocation=("$@")
    status=0
    raw_log_status=0
    if [[ "$verbose" == true ]]; then
        "${invocation[@]}" || status=$?
        return 0
    fi

    set +e
    "${invocation[@]}" 2>&1 | format_xcodebuild_stream "$raw_log"
    local -a statuses=("${PIPESTATUS[@]}")
    set -e
    status="${statuses[0]}"
    raw_log_status="${statuses[1]}"

    print_measurement_lines "$raw_log"
    print_test_outcomes "$raw_log"
}

status=0
raw_log_status=0
run_xcodebuild "${command[@]}"

# The pinned tests, on this one simulator, after the clones have gone — see
# `serial_tests`. Run even when the pass above failed, and its failure kept:
# these are a handful of launches against a machine that is now quiet, and
# skipping them would mean a run that reported one real failure and silently
# never asked about three more tests.
if (( ${#pinned_testing[@]} > 0 )); then
    parallel_status="$status"
    parallel_raw_log_status="$raw_log_status"
    echo "Pinned to one simulator: ${pinned_testing[*]#-only-testing:}"
    run_xcodebuild "${base_command[@]}" "${pinned_testing[@]}"
    # Both statuses keep the worse of the two passes. A green second pass must
    # not report over a red first one, and a log that landed the second time
    # does not bring back the output of the first.
    if (( parallel_status != 0 )); then
        status="$parallel_status"
    fi
    if (( parallel_raw_log_status != 0 )); then
        raw_log_status="$parallel_raw_log_status"
    fi
fi

if (( status != 0 )); then
    echo "UI tests failed. Re-run with --verbose for the full log." >&2
    exit "$status"
fi

# Reached only when xcodebuild itself passed, so nothing here can hide its
# status. A run whose raw log never landed still printed whatever xcbeautify
# could parse, and everything it could not — a crash with no diagnostic, a
# sanitizer report, the launch measurement — is simply gone; "UI tests passed"
# would be a claim about output nobody can go back and read.
if (( raw_log_status != 0 )); then
    echo "The raw xcodebuild log could not be written, so this run kept no full output." >&2
    echo "Re-run with --verbose to see it." >&2
    exit 1
fi

echo "UI tests passed."
