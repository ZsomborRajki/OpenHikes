#!/usr/bin/env bash
#
# The App Store screenshot capture, sourced by Scripts/screenshots-light.sh and
# Scripts/screenshots-dark.sh. Not executable on its own: each of those sets
# `screenshot_appearance` and calls `screenshots_main "$@"`.
#
# App Store Connect wants one set at 6.9" for an iPhone-only app — it scales
# every smaller size from it — so this pins itself to an iPhone 18 Pro Max,
# whose screenshots come out at 1320 x 2868. That is not a preference: a set
# captured on a narrower device is a set App Store Connect will not take for
# the 6.9" slot.
#
# ## One appearance per script, and one device per appearance
#
# The light and dark passes used to be one script run twice over one device.
# A dark pass that hung then did so after twenty minutes of light frames, on a
# simulator the light pass had just worked, with the two passes' output
# interleaved in one log — so "which pass, which frame, and in what state did
# the light pass leave the device" was the first thing every investigation had
# to reconstruct. Each appearance now has its own entry point, its own
# simulator, its own derived data and its own logs, which also means the two
# can run side by side.
#
# ## Why a device of its own
#
# A simulator that has been used is a simulator with history: a tile cache from
# an earlier browse, a photo library somebody dragged something into, a
# location left over from `simulate-hike.sh`. All three show up in a
# screenshot, and none of them is reproducible. So each appearance creates its
# own device, named below, and erases it before every run. It also means a
# screenshot run cannot collide with `run-ui-tests.sh`, which claims its own
# device for the same reason — see *A second session on this machine* in
# AGENTS.md.
#
# ## The status bar
#
# Apple's own marketing shots read 9:41 with a full battery and full bars, and
# a real simulator status bar reads whatever time it is with a chipped battery
# — which looks, in a store listing, like a screenshot somebody forgot to
# clean up. `simctl status_bar override` is what fixes it, and it has to be
# re-applied after every erase because an erase takes it with everything else.
#
# ## The locale
#
# A simulator inherits the host's region, and every figure in this app is
# formatted through the reader's locale on purpose — so without pinning it the
# frames come out reading "2,4 km", "2 000 m" and "2026. Sep 6." on a machine
# set to Hungary, and "6.6 mi" on one set to the UK. All correct, and none of
# them the set anybody uploads to an English listing. That makes the locale
# part of what a screenshot run decides rather than inherits, exactly as
# `Scripts/watch-screenshots.sh` already decided it.

screenshots_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$screenshots_lib_dir/../.." && pwd)"
# The repository's own name-to-UDID resolution, rather than a second copy.
# A hand-rolled `grep` over `simctl list -j` lived here and silently never
# matched, so every run created another simulator called "OpenHikes
# Screenshots" — eight of them before anyone counted.
# shellcheck source=simulator.sh
source "$screenshots_lib_dir/simulator.sh"
# shellcheck source=xcodebuild-output.sh
source "$screenshots_lib_dir/xcodebuild-output.sh"

readonly screenshot_project="$repository_root/OpenHikes.xcodeproj"
readonly screenshot_scheme="OpenHikesUI"
readonly screenshot_suite="OpenHikesUITests/ScreenshotUITests"
readonly screenshot_bundle_id="tappium.com.OpenHikes"

# Set by the entry script before `screenshots_main`:
#   screenshot_appearance      light | dark — `simctl ui … appearance`
#   screenshot_suffix          appended to every frame's file name
#   screenshot_default_device  the simulator this appearance claims

# Frame number to the test that shoots it. The number is the file name's
# prefix and the listing's order; `--frame 03` is how one frame is re-shot on
# its own while it is being debugged, which a full pass makes a nine-minute
# wait for.
readonly screenshot_frames=(
    "01:testCapturesTrailWithPhotoPins"
    "02:testCapturesPhotosAlongTheTrail"
    "03:testCapturesNearbyTrails"
    "04:testCapturesStatisticsAndProfile"
    "05:testCapturesRecordingAHike"
    "06:testCapturesOfflineMaps"
    "07:testCapturesWalkHistory"
    "08:testCapturesDrawingATrail"
    "09:testCapturesAPlaceAndItsPhotos"
)

# The frames that use the hiker's location, and are shot with it granted.
#
# Only these. MapKit draws the location dot on every map once the app is
# authorised, launch argument or not, so a lasting grant put a stale dot —
# wherever frame 08 had last put the simulator — beside the trailhead of the
# hero frame and on the map behind every other one. The frames used to get
# away without that only because the prompt was answered *Allow Once*, which
# lapses when the app quits. So the rest are shot first, with location reset
# to never asked, and these after it is granted.
readonly screenshot_location_frames=" 03 05 08 "

# The frames that import the stamped photographs, and skip without them.
readonly screenshot_library_frames=" 01 02 09 "

# How long `simctl addmedia` gets for the whole stamped library. It took 31s
# for eight photographs on a freshly erased device, and once — one photograph
# at a time, straight after `bootstatus` — hung on the fourth for twenty-six
# minutes before any test had started. A bounded call is what turns that hang
# into a retry.
readonly addmedia_timeout_seconds=180

# How long one frame may run before XCTest kills it and moves on. The slowest,
# the recording frame, walks twenty fixes at four seconds each; a frame still
# going after five minutes is stuck rather than slow, and an allowance is what
# makes it fail with a spindump instead of holding the pass until someone
# notices.
readonly frame_time_allowance_seconds=300

screenshots_usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Captures the App Store screenshot set in $screenshot_appearance appearance on a
dedicated 6.9" simulator.

Options:
  --frame <nn>       Shoot only this frame (01-09); repeat for more. Existing
                     PNGs of the other frames are left alone.
  --output <dir>     Where the PNGs land (default: Screenshots/Output)
  --photos <dir>     JPEGs to put in the simulator's photo library first
                     (default: Screenshots/Stamped; skipped when empty).
                     Stamp them with Scripts/stamp-hike-photos.swift so the
                     app's matcher can place them on the trail.
  --device <name>    Simulator name to create and reuse
                     (default: "$screenshot_default_device")
  --device-type <t>  Simulator device type (default: iPhone 18 Pro Max)
  --derived-data <p> Build directory (default: DerivedData/Screenshots-$screenshot_appearance)
  --locale <id>      Locale to pin the simulator to (default: en_IE). This is
                     what decides "2.4 km" against "2,4 km" and "6.6 mi", so
                     it is a property of the listing rather than of the Mac.
  --no-photos        Do not touch the photo library
  --no-retry         Do not re-run the frames that failed
  --keep             Leave the simulator booted afterwards
  -h, --help         Show this help

The simulator is erased before every run, so a capture never inherits a tile
cache, a photo library or a location from an earlier one. Logs and result
bundles are kept under the derived-data directory; the path is printed at the
end of every run.
EOF
}

# The test method for a frame number, or nothing.
screenshot_test_for_frame() {
    local wanted="$1" entry
    for entry in "${screenshot_frames[@]}"; do
        if [[ "${entry%%:*}" == "$wanted" ]]; then
            printf '%s\n' "${entry#*:}"
            return 0
        fi
    done
    return 1
}

# Runs a command with a deadline. macOS ships no `timeout`, and perl's alarm
# survives the exec, so the command is killed by SIGALRM rather than left
# running behind a script that has moved on.
run_with_deadline() {
    local seconds="$1"
    shift
    /usr/bin/perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$seconds" "$@"
}

# The newest iOS runtime available, so the screenshots show the current system
# chrome rather than whatever old runtime happens to be installed too.
screenshot_runtime_id() {
    xcrun simctl list runtimes --json \
        | /usr/bin/plutil -extract runtimes json -o - -- - \
        | /usr/bin/grep -o '"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-[^"]*"' \
        | sed 's/.*"\(com[^"]*\)"/\1/' \
        | sort -V \
        | tail -1
}

# Erases, boots and dresses the device: status bar, locale, appearance,
# permissions and photographs. Returns non-zero only when the photo library
# could not be filled in time, which the caller answers by starting over from
# the erase — a half-filled library is not something to add to, because the
# frames pick photographs by their position in it.
prepare_screenshot_device() {
    # Erase, then boot, then wait. Erasing a booted device is a shutdown in
    # disguise, so the order matters and `bootstatus` is what makes the wait
    # an observation rather than a guess.
    xcrun simctl shutdown "$udid" 2>/dev/null || true
    xcrun simctl erase "$udid"
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b >/dev/null

    xcrun simctl status_bar "$udid" override \
        --time "9:41" \
        --dataNetwork wifi \
        --wifiMode active \
        --wifiBars 3 \
        --cellularMode active \
        --cellularBars 4 \
        --batteryState charged \
        --batteryLevel 100

    # After the erase, which takes these with everything else, and before the
    # first launch, which is the one that reads them. No reboot is needed: an
    # app resolves `Locale.autoupdatingCurrent` at launch, and every frame
    # here is its own launch.
    xcrun simctl spawn "$udid" defaults write -g AppleLocale -string "$locale_id"
    xcrun simctl spawn "$udid" defaults write -g AppleLanguages \
        -array "${locale_id//_/-}"

    xcrun simctl ui "$udid" appearance "$screenshot_appearance"

    # Whether the three frames that drive the real photo library have
    # anything to drive it with. Handed to the tests rather than guessed at by
    # them: they skip on 0 and assert on 1, so this script is the only thing
    # that can make them run — and a machine without `Screenshots/Stamped`,
    # which the repository does not carry, skips those three instead of
    # failing them. `TEST_RUNNER_` is xcodebuild's own prefix for passing a
    # variable through to the test runner.
    export TEST_RUNNER_OPENHIKES_STAMPED_LIBRARY=0
    [[ "$skip_photos" == false && -d "$photo_dir" ]] || return 0

    local photos=() photo
    for photo in "$photo_dir"/*.[jJ][pP][gG] "$photo_dir"/*.[jJ][pP][eE][gG]; do
        if [[ -f "$photo" ]]; then photos+=("$photo"); fi
    done
    [[ ${#photos[@]} -gt 0 ]] || return 0

    # One call for the whole library rather than one per photograph: the
    # per-photograph loop is the one that hung.
    if ! run_with_deadline "$addmedia_timeout_seconds" \
        xcrun simctl addmedia "$udid" "${photos[@]}"; then
        echo "simctl addmedia did not finish within ${addmedia_timeout_seconds}s." >&2
        return 1
    fi
    echo "Added ${#photos[@]} photo(s) to the simulator library."
    export TEST_RUNNER_OPENHIKES_STAMPED_LIBRARY=1
}

# Builds the app and its UI tests once, for every attempt that follows.
build_screenshot_tests() {
    local raw_log="$derived_data/Screenshots-$screenshot_appearance-build.log"
    echo "[$screenshot_appearance] building…" >&2
    set +e
    xcodebuild build-for-testing \
        -project "$screenshot_project" \
        -scheme "$screenshot_scheme" \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$derived_data" 2>&1 \
        | format_xcodebuild_stream "$raw_log" >&2
    local status=${PIPESTATUS[0]}
    set -e
    if [[ $status -ne 0 ]]; then
        echo "[$screenshot_appearance] the build failed — see $raw_log" >&2
        exit 1
    fi
}

# Installs the app, and grants it the photo library when there is one.
install_app() {
    local app
    app="$(find "$derived_data/Build/Products" -maxdepth 2 -name OpenHikes.app -path '*-iphonesimulator/*' | head -1)"
    [[ -n "$app" ]] || { echo "No OpenHikes.app under $derived_data/Build/Products." >&2; exit 1; }
    xcrun simctl install "$udid" "$app"
    if [[ "$TEST_RUNNER_OPENHIKES_STAMPED_LIBRARY" == 1 ]]; then
        xcrun simctl privacy "$udid" grant photos "$screenshot_bundle_id"
    fi
}

# Grants or takes away location before a group of frames — see
# `screenshot_location_frames` for which, and why only those.
#
# Granted rather than prompted for. The location alert used to arrive on the
# first tap of every location launch — frames 03, 05 and 08 — and a frame is a
# picture of the app, not of its permission prompt, so the prompt is taken out
# of the run rather than answered by an interruption monitor mid-gesture.
# Always rather than While Using, so starting a recording does not raise the
# upgrade prompt either.
#
# **After the install, not before.** A location grant made to a bundle the
# device does not have yet is lost when `xcodebuild` installs it: the first
# version of this granted straight after the erase and all three frames still
# met the alert, in both appearances. Granted to the installed app it holds,
# and `test-without-building` installs over it as an update, which keeps it.
set_location_access() {
    if [[ "$1" == granted ]]; then
        xcrun simctl privacy "$udid" grant location-always "$screenshot_bundle_id"
    else
        xcrun simctl privacy "$udid" reset location "$screenshot_bundle_id"
        # The last simulated fix too, which a location frame leaves behind.
        xcrun simctl location "$udid" clear >/dev/null 2>&1 || true
    fi
}

# Lifts the frames out of a result bundle into the output directory under
# their own names, and prints the number of each frame it wrote.
#
# The frames are XCTAttachments inside the result bundle. `xcresulttool export
# attachments` writes them under generated UUID names and a manifest.json that
# maps each one back to the name the test gave it, so the rename below is not
# a tidying step: without it the set arrives as indistinguishable files and the
# upload order — which is the order they appear in on the listing — is
# guesswork.
export_screenshot_frames() {
    local result_bundle="$1" staging="$2"
    rm -rf "$staging"
    xcrun xcresulttool export attachments \
        --path "$result_bundle" \
        --output-path "$staging" >/dev/null 2>&1 || return 0

    local manifest="$staging/manifest.json"
    [[ -f "$manifest" ]] || return 0

    # `plutil -extract` rather than jq: jq is not a dependency of this
    # repository, and plutil reads JSON on every Mac that can build the
    # project. The outer loop walks *tests*, and its condition asks whether
    # the manifest has an entry at that index — not whether that entry has an
    # attachment. Asking about `attachments.0` stopped the whole walk at the
    # first test that shot nothing, which silently dropped every frame after
    # it.
    local test_index=0 attachment_index exported readable frame
    while /usr/bin/plutil -extract "$test_index" raw -o /dev/null -- "$manifest" 2>/dev/null; do
        attachment_index=0
        while exported="$(/usr/bin/plutil -extract "$test_index.attachments.$attachment_index.exportedFileName" raw -o - "$manifest" 2>/dev/null)"; do
            readable="$(/usr/bin/plutil -extract "$test_index.attachments.$attachment_index.suggestedHumanReadableName" raw -o - "$manifest" 2>/dev/null)"
            # "01-trail-and-its-photos_0_<uuid>.png" -> "01-trail-and-its-photos"
            frame="${readable%%_*}"
            if [[ -f "$staging/$exported" && "$frame" =~ ^[0-9][0-9]- ]]; then
                mv -f "$staging/$exported" "$output_dir/$frame$screenshot_suffix.png"
                printf '%s\n' "${frame%%-*}"
            fi
            attachment_index=$((attachment_index + 1))
        done
        test_index=$((test_index + 1))
    done
    rm -rf "$staging"
}

# One xcodebuild run over `frames`, exported. Prints the frames it shot.
run_screenshot_group() {
    local attempt="$1"
    shift
    local frames=("$@") only_testing=() frame
    for frame in "${frames[@]}"; do
        only_testing+=("-only-testing:$screenshot_suite/$(screenshot_test_for_frame "$frame")")
    done

    local result_bundle="$derived_data/Screenshots-$screenshot_appearance-$attempt.xcresult"
    local raw_log="$derived_data/Screenshots-$screenshot_appearance-$attempt.log"
    rm -rf "$result_bundle"

    echo "[$screenshot_appearance] $attempt: frames ${frames[*]}" >&2
    set +e
    xcodebuild test-without-building \
        -project "$screenshot_project" \
        -scheme "$screenshot_scheme" \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$derived_data" \
        -resultBundlePath "$result_bundle" \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance "$frame_time_allowance_seconds" \
        -maximum-test-execution-time-allowance "$frame_time_allowance_seconds" \
        "${only_testing[@]}" 2>&1 \
        | format_xcodebuild_stream "$raw_log" >&2
    set -e

    [[ -d "$result_bundle" ]] || return 0
    export_screenshot_frames "$result_bundle" "$derived_data/attachments-$screenshot_appearance-$attempt"
}

# Shoots `frames` in two groups — without location, then with it — and prints
# the frames that came out.
run_screenshot_attempt() {
    local attempt="$1"
    shift
    local plain=() located=() frame
    for frame in "$@"; do
        if [[ "$screenshot_location_frames" == *" $frame "* ]]; then
            located+=("$frame")
        else
            plain+=("$frame")
        fi
    done
    if [[ ${#plain[@]} -gt 0 ]]; then
        set_location_access reset
        run_screenshot_group "$attempt-plain" "${plain[@]}"
    fi
    if [[ ${#located[@]} -gt 0 ]]; then
        set_location_access granted
        run_screenshot_group "$attempt-location" "${located[@]}"
    fi
}

screenshots_main() {
    device_name="${OPENHIKES_SCREENSHOT_DEVICE:-$screenshot_default_device}"
    device_type="${OPENHIKES_SCREENSHOT_DEVICE_TYPE:-iPhone 18 Pro Max}"
    output_dir="$repository_root/Screenshots/Output"
    photo_dir="$repository_root/Screenshots/Stamped"
    derived_data="$repository_root/DerivedData/Screenshots-$screenshot_appearance"
    keep_device=false
    skip_photos=false
    retry=true
    # English and metric, without having to force the units to disagree with
    # the locale. That rules out the obvious two: en_US is imperial, and en_GB
    # prints road distances in miles — which this app honours, so an en_GB
    # frame reads "6.6 mi" beside a German place name. en_IE is English,
    # metric, and formats a date the way most of the world reads one. The same
    # default and the same argument as `Scripts/watch-screenshots.sh`, which
    # is the point: one listing, one set of conventions. `--locale en_US` is
    # the right call for a US listing and will print miles.
    locale_id="${OPENHIKES_SCREENSHOT_LOCALE:-en_IE}"
    local requested=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --frame) requested+=("${2:?--frame needs a number}"); shift 2 ;;
            --output) output_dir="${2:?--output needs a directory}"; shift 2 ;;
            --photos) photo_dir="${2:?--photos needs a directory}"; shift 2 ;;
            --device) device_name="${2:?--device needs a name}"; shift 2 ;;
            --device-type) device_type="${2:?--device-type needs a type}"; shift 2 ;;
            --derived-data) derived_data="${2:?--derived-data needs a path}"; shift 2 ;;
            --locale) locale_id="${2:?--locale needs an identifier}"; shift 2 ;;
            --no-photos) skip_photos=true; shift ;;
            --no-retry) retry=false; shift ;;
            --keep) keep_device=true; shift ;;
            -h|--help) screenshots_usage; exit 0 ;;
            *) echo "Unknown option: $1" >&2; screenshots_usage >&2; exit 2 ;;
        esac
    done

    local frames=() frame entry
    if [[ ${#requested[@]} -eq 0 ]]; then
        for entry in "${screenshot_frames[@]}"; do frames+=("${entry%%:*}"); done
    else
        for frame in "${requested[@]}"; do
            # "3" and "03" both mean frame 03.
            if [[ "$frame" =~ ^[0-9]+$ ]]; then frame="$(printf '%02d' "$((10#$frame))")"; fi
            if ! screenshot_test_for_frame "$frame" >/dev/null; then
                echo "Unknown frame: $frame (expected 01-09)" >&2
                exit 2
            fi
            frames+=("$frame")
        done
    fi

    udid="$(resolve_simulator_udid "$device_name" 2>/dev/null || true)"
    if [[ -z "$udid" ]]; then
        local runtime
        runtime="$(screenshot_runtime_id)"
        [[ -n "$runtime" ]] || { echo "No iOS simulator runtime installed." >&2; exit 1; }
        echo "Creating '$device_name' ($device_type on ${runtime##*.})"
        udid="$(xcrun simctl create "$device_name" "$device_type" "$runtime")"
    fi
    echo "Simulator: $device_name ($udid), $screenshot_appearance"

    if ! prepare_screenshot_device; then
        echo "Starting the device over from the erase." >&2
        prepare_screenshot_device || { echo "The photo library could not be filled." >&2; exit 1; }
    fi

    # Without the stamped library the three frames that import it would only
    # skip, so they are not run — nor retried as though they had failed.
    local skipped=()
    if [[ "$TEST_RUNNER_OPENHIKES_STAMPED_LIBRARY" == 0 ]]; then
        local kept=()
        for frame in "${frames[@]}"; do
            if [[ "$screenshot_library_frames" == *" $frame "* ]]; then
                skipped+=("$frame")
            else
                kept+=("$frame")
            fi
        done
        frames=(${kept[@]+"${kept[@]}"})
    fi
    if [[ ${#frames[@]} -eq 0 ]]; then
        echo "[$screenshot_appearance] skipped, no stamped library: ${skipped[*]} — nothing left to shoot."
        return 0
    fi

    mkdir -p "$output_dir" "$derived_data"
    build_screenshot_tests
    install_app
    # Only this appearance's copies of only the frames being shot: the other
    # script, or an earlier `--frame` run, owns the rest of the folder.
    for frame in "${frames[@]}"; do
        for entry in "$output_dir/$frame"-*.png; do
            [[ -f "$entry" ]] || continue
            if [[ -n "$screenshot_suffix" ]]; then
                if [[ "$entry" == *"$screenshot_suffix.png" ]]; then rm -f "$entry"; fi
            elif [[ "$entry" != *-dark.png ]]; then
                rm -f "$entry"
            fi
        done
    done

    # Retried once, and only the frames that did not come out. The community
    # frame waits on a seeded browse answering, and that wait can lose to a
    # busy machine rather than to a bug; re-running the eight frames that
    # already passed to give it a second chance used to double the pass.
    local shot=() missing=("${frames[@]}") attempt
    for attempt in 1 2; do
        while IFS= read -r frame; do
            if [[ -n "$frame" ]]; then shot+=("$frame"); fi
        done < <(run_screenshot_attempt "$attempt" "${missing[@]}")
        missing=()
        for frame in "${frames[@]}"; do
            if [[ " ${shot[*]:-} " != *" $frame "* ]]; then missing+=("$frame"); fi
        done
        if [[ ${#missing[@]} -eq 0 || "$retry" == false || $attempt -eq 2 ]]; then
            break
        fi
        echo "[$screenshot_appearance] not shot: ${missing[*]} — retrying those once." >&2
    done

    echo
    echo "[$screenshot_appearance] $output_dir"
    for frame in "${frames[@]}"; do
        for entry in "$output_dir/$frame"-*"$screenshot_suffix".png; do
            [[ -f "$entry" ]] || continue
            if [[ -z "$screenshot_suffix" && "$entry" == *-dark.png ]]; then continue; fi
            local size
            size="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$entry" 2>/dev/null \
                | awk '/pixel/ { printf "%s ", $2 }')"
            printf '  %-44s %s\n' "$(basename "$entry")" "$size"
        done
    done
    echo "Logs and result bundles: $derived_data/Screenshots-$screenshot_appearance-*"

    if [[ "$keep_device" == false ]]; then
        xcrun simctl shutdown "$udid"
    fi

    if [[ ${#skipped[@]} -gt 0 ]]; then
        echo "[$screenshot_appearance] skipped, no stamped library: ${skipped[*]}" >&2
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "[$screenshot_appearance] FAILED — not shot: ${missing[*]}" >&2
        return 1
    fi
    echo "[$screenshot_appearance] ${#shot[@]} of ${#frames[@]} frame(s) shot."
}
