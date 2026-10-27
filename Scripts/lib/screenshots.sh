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
# ## The iPhone Duo
#
# The Duo has a slot of its own, and takes a frame of either display:
# 1398 × 2034 from the cover, 2007 × 2853 from the inner one, either way up.
# `--device-type "iPhone Duo"` shoots the set on one, and `--pose open` opens
# it first, through Scripts/duo-pose.sh — a simulator boots closed, and only
# Device Hub can open it by hand. Opening needs hinge, an optional tool
# (Scripts/lib/hinge.sh): on a machine without it an open set is skipped, and
# said to be, before a device is touched. The open Duo is turned upright unless
# `--orientation landscape` keeps it the way it opens, which is where the map
# screen puts its panel beside the map. XCTest captures the inner display a
# pixel short each way, and a landscape frame stored on its side, so every
# exported frame goes through Scripts/lib/fit-screenshot.swift. That turns a
# frame upright in its pixels and puts the pixel back on one that is that
# close to a size App Store Connect takes, and leaves the rest alone.
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
# own device, named below, and starts it clean before every run — as a fresh
# clone of a settled template rather than an erase, which costs 1.4 GB of
# downloads on the next boot (see Scripts/lib/simulator-templates.sh). Only a
# device passed by UDID is erased in place instead: that one was named as
# itself, and replacing it would hand back a different UDID. It also means a
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
# re-applied every run because a clean device has none.
#
# Full and *discharging*, not `charged`. `charged` is the state of a phone that
# is plugged in, and the status bar draws it that way: a green battery with a
# bolt through it, in the corner of every frame.
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
# shellcheck source=simulator-templates.sh
source "$screenshots_lib_dir/simulator-templates.sh"
# shellcheck source=xcodebuild-output.sh
source "$screenshots_lib_dir/xcodebuild-output.sh"
# shellcheck source=hinge.sh
source "$screenshots_lib_dir/hinge.sh"
# shellcheck source=screenshot-output.sh
source "$screenshots_lib_dir/screenshot-output.sh"

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
# its own while it is being debugged, which a full pass makes a wait of
# several minutes for.
readonly screenshot_frames=(
    "01:testCapturesTrailWithPhotoPins"
    "02:testCapturesPhotosAlongTheTrail"
    "03:testCapturesNearbyTrails"
    "04:testCapturesFollowingTheTrail"
    "05:testCapturesRecordingAHike"
    "06:testCapturesMapsForTheMountains"
    "07:testCapturesWalkHistory"
    "08:testCapturesDrawingATrail"
    "09:testCapturesAPlaceAndItsPhotos"
    "10:testCapturesSharingAHike"
)

# The frames that use the hiker's location, and are shot with it granted.
#
# Only these. MapKit draws the location dot on every map once the app is
# authorised, launch argument or not, so a lasting grant put a stale dot —
# wherever frame 08 had last put the simulator — beside the trailhead of the
# hero frame and on the map behind every other one. The frames used to get
# away without that only because the prompt was answered *Allow Once*, which
# lapses when the app quits. So the rest are shot first, with location reset
# to never asked, and these after it is granted. Frame 04 is one of them
# because a hiker on the trail is what it is of.
readonly screenshot_location_frames=" 03 04 05 08 "

# The frames that import the stamped photographs, and skip without them.
readonly screenshot_library_frames=" 01 02 06 09 10 "

# How long `simctl addmedia` gets for the whole stamped library. It took 31s
# for eight photographs on a freshly erased device, and once — one photograph
# at a time, straight after `bootstatus` — hung on the fourth for twenty-six
# minutes before any test had started. A bounded call is what turns that hang
# into a retry.
readonly addmedia_timeout_seconds=180

# The sizes App Store Connect takes for an iPhone frame, each way up: the 6.9"
# slot, then the iPhone Duo's cover and inner displays. Handed to
# Scripts/lib/fit-screenshot.swift, which only ever adds the pixel a capture
# came out short of one of them.
readonly screenshot_store_sizes=(
    1320x2868 2868x1320
    1398x2034 2034x1398
    2007x2853 2853x2007
)

# How long one frame may run before XCTest kills it and moves on. The slowest,
# the routed walk, waits on Apple and Stadia and takes under a minute; a frame
# still going after five minutes is stuck rather than slow, and an allowance is
# what makes it fail with a spindump instead of holding the pass until someone
# notices.
readonly frame_time_allowance_seconds=300

screenshots_usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Captures the App Store screenshot set in $screenshot_appearance appearance on a
dedicated 6.9" simulator.

Options:
  --frame <nn>       Shoot only this frame (01-10); repeat for more.
  --output <dir>     Clean output root (default: Screenshots/Output). Raw PNGs
                     go in device/layout/locale/date and appearance folders.
  --append           Keep other capture sets in the output root. This set's
                     appearance directory is still cleaned before capturing.
  --photos <dir>     JPEGs to put in the simulator's photo library first
                     (default: Screenshots/Stamped; skipped when empty).
                     Stamp them with Scripts/stamp-hike-photos.swift so the
                     app's matcher can place them on the trail.
  --device <name>    Simulator name to create and reuse
                     (default: "$screenshot_default_device")
  --prepared-device <udid>
                    Use a freshly acquired pool device without erasing it.
                    The caller owns its pool claim and releases it afterwards.
  --pool-owner <id>  Owner passed to sim-pool acquire (default: session/checkout)
  --device-type <t>  iPhone 18 Pro Max (default) or iPhone Duo
  --pose <p>         For an iPhone Duo: closed (its inner display folded away,
                     as it boots) or open (unfolded). See Scripts/duo-pose.sh.
                     open needs hinge, and is skipped on a machine without it.
  --orientation <o>  With --pose open: portrait (default, the inner display
                     turned upright, 2007 x 2853) or landscape (the way it
                     opens, 2853 x 2007). A closed Duo is shot upright: the
                     cover's home screen does not turn, so its pose cannot be
                     read back on its side before the app is up.
  --derived-data <p> Build directory (default: DerivedData/Screenshots-$screenshot_appearance)
  --locale <id>      Locale to pin the simulator to (default: en_IE). This is
                     what decides "2.4 km" against "2,4 km" and "6.6 mi", so
                     it is a property of the listing rather than of the Mac.
  --no-photos        Do not touch the photo library
  --no-retry         Do not re-run the frames that failed
  --keep             Leave the simulator booted afterwards
  -h, --help         Show this help

The simulator starts clean before every run — a fresh clone of a settled
template, or erased when --device names it by UDID — so a capture never
inherits a tile cache, a photo library or a location from an earlier one. Logs and result
bundles for the last five completed runs are kept under the derived-data
directory; the path is printed at the end of every run. Active runs are kept.
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

# Makes `udid` a clean device named `device_name`: a fresh clone of the
# template for its type, in place of the one there was, on the newest iOS
# runtime that can run that type, so the frames show the current system
# chrome. A device named by UDID is erased in place instead, and so is any
# device when no template can be settled; with no device at all, one is
# created.
reset_screenshot_device() {
    local runtime template clone=""
    runtime="$(newest_simulator_runtime iOS "$device_type")"
    if [[ "$device_pinned" == false && -n "$runtime" ]] \
        && template="$(simulator_template "$device_type" "$runtime")"; then
        if [[ -n "$udid" ]]; then
            clone="$(replace_simulator_with_clone "$udid" "$template" "$device_name")" || clone=""
        else
            clone="$(clone_simulator_template "$template" "$device_name")" || clone=""
        fi
    fi
    if [[ -n "$clone" ]]; then
        udid="$clone"
        return 0
    fi
    if [[ -z "$udid" ]]; then
        [[ -n "$runtime" ]] || { echo "No iOS simulator runtime installed." >&2; exit 1; }
        echo "Creating '$device_name' ($device_type on ${runtime##*.})"
        udid="$(xcrun simctl create "$device_name" "$device_type" "$runtime")"
        return 0
    fi
    # Erasing a booted device is a shutdown in disguise, so it goes first.
    xcrun simctl shutdown "$udid" 2>/dev/null || true
    xcrun simctl erase "$udid"
}

# Starts the device clean, boots and dresses it: status bar, locale,
# appearance, permissions and photographs. Returns non-zero only when the photo
# library could not be filled in time, which the caller answers by starting
# over from a clean device — a half-filled library is not something to add to,
# because the frames pick photographs by their position in it.
prepare_screenshot_device() {
    if [[ "$prepared_device" == false ]]; then
        reset_screenshot_device
    fi
    # `bootstatus -b` also boots a shutdown device; a pooled one is already up.
    xcrun simctl bootstatus "$udid" -b >/dev/null

    xcrun simctl status_bar "$udid" override \
        --time "9:41" \
        --dataNetwork wifi \
        --wifiMode active \
        --wifiBars 3 \
        --cellularMode active \
        --cellularBars 4 \
        --batteryState discharging \
        --batteryLevel 100

    # On the clean device, which has none of these, and before the first
    # launch, which is the one that reads them. No reboot is needed: an
    # app resolves `Locale.autoupdatingCurrent` at launch, and every frame
    # here is its own launch.
    xcrun simctl spawn "$udid" defaults write -g AppleLocale -string "$locale_id"
    xcrun simctl spawn "$udid" defaults write -g AppleLanguages \
        -array "${locale_id//_/-}"
    export TEST_RUNNER_OPENHIKES_SCREENSHOT_LOCALE="$locale_id"

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
    local raw_log="$screenshot_log_dir/build.log"
    echo "[$screenshot_appearance] building…" >&2
    set +e
    xcodebuild build-for-testing \
        -project "$screenshot_project" \
        -scheme "$screenshot_scheme" \
        -skipPackagePluginValidation \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$derived_data" 2>&1 \
        | format_xcodebuild_stream "$raw_log" >&2
    local statuses=("${PIPESTATUS[@]}")
    set -e
    if [[ ${statuses[0]} -ne 0 || ${statuses[1]} -ne 0 ]]; then
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
    # Read the shipping translations instead of keeping German UI wording in
    # the tests too. The runner receives these; the app uses its own bundle.
    local language="${locale_id%%[_-]*}"
    export TEST_RUNNER_OPENHIKES_SCREENSHOT_STRINGS='{}'
    if [[ -f "$app/$language.lproj/Localizable.strings" ]]; then
        TEST_RUNNER_OPENHIKES_SCREENSHOT_STRINGS="$(/usr/bin/plutil -convert json -o - \
            "$app/$language.lproj/Localizable.strings")"
    fi
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
    local passed
    passed="$(xcrun xcresulttool get test-results tests --path "$result_bundle" \
        | swift "$screenshots_lib_dir/screenshot-passed-tests.swift")" || return 0
    [[ -n "$passed" ]] || return 0
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
    local test_index=0 attachment_index exported readable frame identifier
    while /usr/bin/plutil -extract "$test_index" raw -o /dev/null -- "$manifest" 2>/dev/null; do
        identifier="$(/usr/bin/plutil -extract "$test_index.testIdentifier" raw -o - "$manifest" 2>/dev/null || true)"
        if ! printf '%s\n' "$passed" | grep -Fxq -- "$identifier"; then
            test_index=$((test_index + 1))
            continue
        fi
        attachment_index=0
        while exported="$(/usr/bin/plutil -extract "$test_index.attachments.$attachment_index.exportedFileName" raw -o - "$manifest" 2>/dev/null)"; do
            readable="$(/usr/bin/plutil -extract "$test_index.attachments.$attachment_index.suggestedHumanReadableName" raw -o - "$manifest" 2>/dev/null)"
            # "01-trail-and-its-photos_0_<uuid>.png" -> "01-trail-and-its-photos"
            frame="${readable%%_*}"
            if [[ -f "$staging/$exported" && "$frame" =~ ^[0-9][0-9]- ]]; then
                if fit_screenshot_frame "$staging/$exported"; then
                    mv -f "$staging/$exported" "$output_dir/$frame$screenshot_suffix.png"
                    printf '%s\n' "${frame%%-*}"
                fi
            fi
            attachment_index=$((attachment_index + 1))
        done
        test_index=$((test_index + 1))
    done
    rm -rf "$staging"
}

# Turns a frame captured on its side upright in its pixels, and puts back the
# pixel XCTest leaves off a frame of the iPhone Duo's inner display — see
# Scripts/lib/fit-screenshot.swift — and leaves every other frame as it was.
# Says what it changed on stderr, since stdout is the list of frames shot.
fit_screenshot_frame() {
    swift "$screenshots_lib_dir/fit-screenshot.swift" "${screenshot_store_sizes[@]}" -- "$1" >&2 || return 1
    local size accepted
    size="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$1" \
        | awk '$1 ~ /^pixel(Width|Height):$/ { print $2 }' | paste -sd x -)"
    for accepted in "${screenshot_store_sizes[@]}"; do
        if [[ "$size" == "$accepted" ]]; then return 0; fi
    done
    echo "Rejected $(basename "$1"): $size is not an App Store screenshot size." >&2
    return 1
}

# One xcodebuild run over `frames`, exported. Prints the frames it shot.
run_screenshot_group() {
    local attempt="$1"
    shift
    local frames=("$@") only_testing=() frame
    for frame in "${frames[@]}"; do
        only_testing+=("-only-testing:$screenshot_suite/$(screenshot_test_for_frame "$frame")")
    done

    local result_bundle="$screenshot_log_dir/$attempt.xcresult"
    local raw_log="$screenshot_log_dir/$attempt.log"
    rm -rf "$result_bundle"

    echo "[$screenshot_appearance] $attempt: frames ${frames[*]}" >&2
    # No diagnostics, as Scripts/run-ui-tests.sh collects none: a group with a
    # failed frame otherwise ends in Xcode 27's `simctl diagnose`, which held
    # the result bundle — the frames that did come out with it — for ten
    # minutes before the retry could start.
    set +e
    xcodebuild test-without-building \
        -project "$screenshot_project" \
        -scheme "$screenshot_scheme" \
        -skipPackagePluginValidation \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$derived_data" \
        -testLanguage "${locale_id%%[_-]*}" \
        -testRegion "${locale_id##*[_-]}" \
        -resultBundlePath "$result_bundle" \
        -collect-test-diagnostics never \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance "$frame_time_allowance_seconds" \
        -maximum-test-execution-time-allowance "$frame_time_allowance_seconds" \
        "${only_testing[@]}" 2>&1 \
        | format_xcodebuild_stream "$raw_log" >&2
    local statuses=("${PIPESTATUS[@]}")
    set -e

    if [[ ${statuses[0]} -ne 0 || ${statuses[1]} -ne 0 ]]; then
        echo "[$screenshot_appearance] $attempt failed (xcodebuild ${statuses[0]}, log ${statuses[1]}) — see $raw_log" >&2
        # Exit 65 includes ordinary test failures. Export only frames whose
        # own tests passed, never one attached by a failed or crashed test.
        if [[ ${statuses[0]} -ne 65 || ${statuses[1]} -ne 0 ]]; then return 0; fi
    fi

    [[ -d "$result_bundle" ]] || return 0
    export_screenshot_frames "$result_bundle" "$screenshot_log_dir/attachments-$attempt"
}

# Preserve evidence from five completed runs, including failures. An active
# run has no marker, so another capture cannot prune its bundle mid-export.
finish_screenshot_run() {
    touch "$screenshot_log_dir/.complete"
    local completed=0 directory
    while IFS= read -r directory; do
        [[ -f "$directory/.complete" ]] || continue
        completed=$((completed + 1))
        if (( completed > 5 )); then rm -rf "$directory"; fi
    done < <(find "$screenshot_runs_dir" -mindepth 1 -maxdepth 1 -type d | sort -r)
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
    screenshot_run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    device_type="${OPENHIKES_SCREENSHOT_DEVICE_TYPE:-iPhone 18 Pro Max}"
    output_root="$repository_root/Screenshots/Output"
    append_output=false
    photo_dir="$repository_root/Screenshots/Stamped"
    derived_data="$repository_root/DerivedData/Screenshots-$screenshot_appearance"
    keep_device=false
    prepared_device=false
    pool_owner=""
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
    pose=""
    orientation=""
    local requested=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --frame) requested+=("${2:?--frame needs a number}"); shift 2 ;;
            --output) output_root="${2:?--output needs a directory}"; shift 2 ;;
            --append) append_output=true; shift ;;
            --photos) photo_dir="${2:?--photos needs a directory}"; shift 2 ;;
            --device) device_name="${2:?--device needs a name}"; prepared_device=false; shift 2 ;;
            --prepared-device)
                device_name="${2:?--prepared-device needs a UDID}"
                if ! [[ "$device_name" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]]; then
                    echo "--prepared-device needs a pool device’s UDID." >&2
                    exit 2
                fi
                prepared_device=true
                shift 2
                ;;
            --device-type) device_type="${2:?--device-type needs a type}"; shift 2 ;;
            --pool-owner) pool_owner="${2:?--pool-owner needs an owner}"; shift 2 ;;
            --pose)
                pose="${2:?--pose needs open or closed}"
                if [[ "$pose" != open && "$pose" != closed ]]; then
                    echo "Unknown pose: $pose (open or closed)" >&2
                    exit 2
                fi
                shift 2
                ;;
            --orientation)
                orientation="${2:?--orientation needs portrait or landscape}"
                if [[ "$orientation" != portrait && "$orientation" != landscape ]]; then
                    echo "Unknown orientation: $orientation (portrait or landscape)" >&2
                    exit 2
                fi
                shift 2
                ;;
            --derived-data) derived_data="${2:?--derived-data needs a path}"; shift 2 ;;
            --locale) locale_id="${2:?--locale needs an identifier}"; shift 2 ;;
            --no-photos) skip_photos=true; shift ;;
            --no-retry) retry=false; shift ;;
            --keep) keep_device=true; shift ;;
            -h|--help) screenshots_usage; exit 0 ;;
            *) echo "Unknown option: $1" >&2; screenshots_usage >&2; exit 2 ;;
        esac
    done

    if [[ -n "$orientation" && "$pose" != open ]]; then
        echo "--orientation needs --pose open: a closed Duo is shot upright." >&2
        exit 2
    fi
    case "$device_type" in
        'iPhone 18 Pro Max'|'iPhone Duo') ;;
        *) echo "Unsupported screenshot device type: $device_type (iPhone 18 Pro Max or iPhone Duo)." >&2; exit 2 ;;
    esac
    # Before any device is touched: an open Duo needs hinge, and a machine
    # without it skips the set rather than failing the run or shooting it closed.
    local without_hinge
    if [[ "$pose" == open ]] && ! without_hinge="$(hinge_command)"; then
        echo "[$screenshot_appearance] skipped, the open iPhone Duo needs hinge: $without_hinge"
        return 0
    fi

    local frames=() frame entry
    if [[ ${#requested[@]} -eq 0 ]]; then
        for entry in "${screenshot_frames[@]}"; do frames+=("${entry%%:*}"); done
    else
        for frame in "${requested[@]}"; do
            # "3" and "03" both mean frame 03.
            if [[ "$frame" =~ ^[0-9]+$ ]]; then frame="$(printf '%02d' "$((10#$frame))")"; fi
            if ! screenshot_test_for_frame "$frame" >/dev/null; then
                echo "Unknown frame: $frame (expected 01-10)" >&2
                exit 2
            fi
            if [[ " ${frames[*]:-} " != *" $frame "* ]]; then frames+=("$frame"); fi
        done
    fi

    udid="$(resolve_simulator_udid "$device_name" 2>/dev/null || true)"
    if [[ "$prepared_device" == true && -z "$udid" ]]; then
        echo "No available prepared iOS simulator with UDID $device_name." >&2
        exit 2
    fi
    if [[ "$prepared_device" == true ]]; then
        OPENHIKES_SIM_POOL_DEVICE_TYPE="$device_type" "$repository_root/Scripts/sim-pool.sh" \
            validate "$udid" ${pool_owner:+--owner "$pool_owner"} || exit 2
    fi
    local layout="${pose:+$pose${orientation:+_$orientation}}"
    if [[ "$device_type" == 'iPhone Duo' && -z "$pose" ]]; then layout="closed"; fi
    if [[ "$pose" == open && -z "$orientation" ]]; then layout="open_portrait"; fi
    output_dir="$(screenshot_output_directory "$output_root" "$device_type" "$locale_id" \
        "$layout" "$screenshot_appearance" "$append_output")" || exit $?
    device_pinned=false
    if [[ "$device_name" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]]; then
        device_pinned=true
    fi

    if ! prepare_screenshot_device; then
        if [[ "$prepared_device" == true ]]; then
            echo "The photo library could not be filled; acquire a clean pool device before retrying." >&2
            exit 1
        fi
        echo "Starting over from a clean device." >&2
        prepare_screenshot_device || { echo "The photo library could not be filled." >&2; exit 1; }
    fi
    # On the clean device, which has just booted closed: an iPhone Duo is
    # opened once, from cold, which is the fold Scripts/duo-pose.sh can be
    # relied on for — and a pose that did not happen stops the run rather
    # than shooting a set on the wrong display.
    if [[ -n "$pose" ]]; then
        "$repository_root/Scripts/duo-pose.sh" "$pose" --device "$udid" \
            ${orientation:+--orientation "$orientation"}
    fi
    # After the device is clean, since a clean device is a new UDID.
    echo "Simulator: $device_name ($udid), $screenshot_appearance${pose:+, $pose}${orientation:+, $orientation}"

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
    screenshot_runs_dir="$derived_data/ScreenshotRuns-$screenshot_appearance"
    screenshot_log_dir="$screenshot_runs_dir/$screenshot_run_id"
    mkdir -p "$screenshot_log_dir"
    trap finish_screenshot_run EXIT
    build_screenshot_tests
    install_app
    # Retried once, and only the frames that did not come out. The community
    # frame waits on a seeded browse answering, and that wait can lose to a
    # busy machine rather than to a bug; re-running every frame that
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
                | awk '$1 ~ /^pixel(Width|Height):$/ { printf "%s ", $2 }')"
            printf '  %-44s %s\n' "$(basename "$entry")" "$size"
        done
    done
    echo "Logs and result bundles: $screenshot_log_dir"

    if [[ "$keep_device" == false && "$prepared_device" == false ]]; then
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
