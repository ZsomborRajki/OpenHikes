#!/usr/bin/env bash
#
# The App Store screenshots, from a clean simulator to a folder of PNGs.
#
# App Store Connect wants one set at 6.9" for an iPhone-only app — it scales
# every smaller size from it — so this script pins itself to an iPhone 18 Pro
# Max, whose screenshots come out at 1320 x 2868. That is not a preference:
# a set captured on a narrower device is a set App Store Connect will not take
# for the 6.9" slot.
#
# ## Why a device of its own
#
# A simulator that has been used is a simulator with history: a tile cache from
# an earlier browse, a photo library somebody dragged something into, a
# location left over from `simulate-hike.sh`. All three show up in a
# screenshot, and none of them is reproducible. So this creates its own device,
# named below, and erases it before every run. It also means a screenshot run
# cannot collide with `run-ui-tests.sh`, which claims its own device for the
# same reason — see *A second session on this machine* in AGENTS.md.
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

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The repository's own name-to-UDID resolution, rather than a second copy.
# A hand-rolled `grep` over `simctl list -j` lived here and silently never
# matched, so every run created another simulator called "OpenHikes
# Screenshots" — eight of them before anyone counted.
# shellcheck source=lib/simulator.sh
source "$repository_root/Scripts/lib/simulator.sh"
project="$repository_root/OpenHikes.xcodeproj"
scheme="OpenHikesUI"
suite="OpenHikesUITests/ScreenshotUITests"

device_name="${OPENHIKES_SCREENSHOT_DEVICE:-OpenHikes Screenshots}"
device_type="${OPENHIKES_SCREENSHOT_DEVICE_TYPE:-iPhone 18 Pro Max}"
output_dir="$repository_root/Screenshots/Output"
photo_dir="$repository_root/Screenshots/Stamped"
derived_data="$repository_root/DerivedData/Screenshots"
app_bundle_id="tappium.com.OpenHikes"
keep_device=false
skip_photos=false
appearance_mode="both"
# English and metric, without having to force the units to disagree with the
# locale. That rules out the obvious two: en_US is imperial, and en_GB prints
# road distances in miles — which this app honours, so an en_GB frame reads
# "6.6 mi" beside a German place name. en_IE is English, metric, and formats a
# date the way most of the world reads one. The same default and the same
# argument as `Scripts/watch-screenshots.sh`, which is the point: one listing,
# one set of conventions. Override for a localised set; `--locale en_US` is
# the right call for a US listing and will print miles.
locale_id="${OPENHIKES_SCREENSHOT_LOCALE:-en_IE}"

usage() {
    cat <<'EOF'
Usage: Scripts/screenshots.sh [options]

Captures the App Store screenshot set on a dedicated 6.9" simulator.

Options:
  --output <dir>     Where the PNGs land (default: Screenshots/Output)
  --photos <dir>     JPEGs to put in the simulator's photo library first
                     (default: Screenshots/Stamped; skipped when empty).
                     Stamp them with Scripts/stamp-hike-photos.swift so the
                     app's matcher can place them on the trail.
  --device <name>    Simulator name to create and reuse
  --device-type <t>  Simulator device type (default: iPhone 18 Pro Max)
  --appearance <a>   light, dark, or both (default: both). "both" runs the
                     suite twice and suffixes the dark frames with "-dark".
  --locale <id>      Locale to pin the simulator to (default: en_IE). This is
                     what decides "2.4 km" against "2,4 km" and "6.6 mi", so
                     it is a property of the listing rather than of the Mac.
  --no-photos        Do not touch the photo library
  --keep             Leave the simulator booted afterwards
  -h, --help         Show this help

The simulator is erased before every run, so a capture never inherits a tile
cache, a photo library or a location from an earlier one.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) output_dir="${2:?--output needs a directory}"; shift 2 ;;
        --photos) photo_dir="${2:?--photos needs a directory}"; shift 2 ;;
        --device) device_name="${2:?--device needs a name}"; shift 2 ;;
        --device-type) device_type="${2:?--device-type needs a type}"; shift 2 ;;
        --appearance) appearance_mode="${2:?--appearance needs a value}"; shift 2 ;;
        --locale) locale_id="${2:?--locale needs an identifier}"; shift 2 ;;
        --no-photos) skip_photos=true; shift ;;
        --keep) keep_device=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# The newest iOS runtime available, so the screenshots show the current system
# chrome rather than whatever old runtime happens to be installed too.
runtime_id() {
    xcrun simctl list runtimes --json \
        | /usr/bin/plutil -extract runtimes json -o - -- - \
        | /usr/bin/grep -o '"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-[^"]*"' \
        | sed 's/.*"\(com[^"]*\)"/\1/' \
        | sort -V \
        | tail -1
}

udid="$(resolve_simulator_udid "$device_name" 2>/dev/null || true)"
if [[ -z "$udid" ]]; then
    runtime="$(runtime_id)"
    [[ -n "$runtime" ]] || { echo "No iOS simulator runtime installed." >&2; exit 1; }
    echo "Creating '$device_name' ($device_type on ${runtime##*.})"
    udid="$(xcrun simctl create "$device_name" "$device_type" "$runtime")"
fi
echo "Simulator: $device_name ($udid)"

# Erase, then boot, then wait. Erasing a booted device is a shutdown in
# disguise, so the order matters and `bootstatus` is what makes the wait an
# observation rather than a guess.
xcrun simctl shutdown "$udid" 2>/dev/null || true
xcrun simctl erase "$udid"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b

xcrun simctl status_bar "$udid" override \
    --time "9:41" \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --cellularMode active \
    --cellularBars 4 \
    --batteryState charged \
    --batteryLevel 100

# After the erase, which takes these with everything else, and before the first
# launch, which is the one that reads them. No reboot is needed: an app
# resolves `Locale.autoupdatingCurrent` at launch, and every frame here is its
# own launch.
xcrun simctl spawn "$udid" defaults write -g AppleLocale -string "$locale_id"
xcrun simctl spawn "$udid" defaults write -g AppleLanguages \
    -array "${locale_id//_/-}"

# Whether the two frames that drive the real photo library have anything to
# drive it with. Handed to the tests rather than guessed at by them: they skip
# on 0 and assert on 1, so this script is the only thing that can make them run
# — and a machine without `Screenshots/Stamped`, which the repository does not
# carry, skips those two instead of failing them. `TEST_RUNNER_` is
# xcodebuild's own prefix for passing a variable through to the test runner.
export TEST_RUNNER_OPENHIKES_STAMPED_LIBRARY=0

if [[ "$skip_photos" == false && -d "$photo_dir" ]]; then
    photos=("$photo_dir"/*.[jJ][pP][gG] "$photo_dir"/*.[jJ][pP][eE][gG])
    added=0
    for photo in "${photos[@]}"; do
        [[ -f "$photo" ]] || continue
        xcrun simctl addmedia "$udid" "$photo"
        added=$((added + 1))
    done
    echo "Added $added photo(s) to the simulator library."
    # Granted up front rather than answered as an alert. The photo frame drives
    # the real library on purpose, and a system permission dialog is a
    # springboard element a screenshot run should not be spending gestures on —
    # nor is "which alert was in front" a thing worth making a capture depend
    # on. The grant is per-device and this device is erased every run, so it
    # has to be re-applied here rather than assumed.
    if [[ $added -gt 0 ]]; then
        xcrun simctl privacy "$udid" grant photos "$app_bundle_id"
        echo "Granted photo library access to $app_bundle_id."
        export TEST_RUNNER_OPENHIKES_STAMPED_LIBRARY=1
    fi
fi

mkdir -p "$output_dir"
mkdir -p "$derived_data"
rm -rf "${output_dir:?}"/*.png

# One pass over the suite in one appearance. Called twice for `--appearance
# both`, which is the useful default for a listing: the same screen in light
# and dark is two frames that look considered rather than two that look
# duplicated, and this app draws a different accent green in each — so a dark
# frame is genuinely a different picture, not the same one inverted.
capture_pass() {
    local appearance="$1" suffix="$2"
    local result_bundle="$derived_data/Screenshots-$appearance.xcresult"

    xcrun simctl ui "$udid" appearance "$appearance"
    echo "Capturing ($appearance)…"
    # Retried once, for the reason `Scripts/run-ui-tests.sh` retries its
    # failures: the community scenario waits on a seeded browse answering, and
    # that wait loses to a busy machine rather than to a bug — reliably so on
    # the second pass, when the first one has just finished hammering the same
    # simulator. A green first attempt pays nothing for this.
    local attempt
    for attempt in 1 2; do
        rm -rf "$result_bundle"
        if xcodebuild test \
            -project "$project" \
            -scheme "$scheme" \
            -destination "platform=iOS Simulator,id=$udid" \
            -derivedDataPath "$derived_data" \
            -resultBundlePath "$result_bundle" \
            -only-testing:"$suite"; then
            break
        fi
        if [[ $attempt -eq 2 ]]; then
            echo "The $appearance pass failed twice." >&2
            exit 1
        fi
        echo "The $appearance pass failed; retrying once." >&2
    done

    # The frames are XCTAttachments inside the result bundle. `xcresulttool
    # export attachments` writes them under generated UUID names and a
    # manifest.json that maps each one back to the name the test gave it, so
    # the rename below is not a tidying step: without it the set arrives as
    # seven indistinguishable files and the upload order — which is the order
    # they appear in on the listing — is guesswork.
    local staging="$derived_data/attachments-$appearance"
    rm -rf "$staging"
    xcrun xcresulttool export attachments \
        --path "$result_bundle" \
        --output-path "$staging" >/dev/null

    local manifest="$staging/manifest.json"
    [[ -f "$manifest" ]] || { echo "No attachment manifest was written." >&2; exit 1; }

    # `plutil -extract` rather than jq: jq is not a dependency of this
    # repository, and plutil reads JSON on every Mac that can build the project.
    # The outer loop walks *tests*, and its condition asks whether the manifest
    # has an entry at that index — not whether that entry has an attachment.
    # Asking about `attachments.0` stopped the whole walk at the first test
    # that shot nothing, which silently dropped every frame after it.
    local test_index=0 attachment_index exported readable frame
    while /usr/bin/plutil -extract "$test_index" raw -o /dev/null -- "$manifest" 2>/dev/null; do
        attachment_index=0
        while exported="$(/usr/bin/plutil -extract "$test_index.attachments.$attachment_index.exportedFileName" raw -o - "$manifest" 2>/dev/null)"; do
            readable="$(/usr/bin/plutil -extract "$test_index.attachments.$attachment_index.suggestedHumanReadableName" raw -o - "$manifest" 2>/dev/null)"
            # "01-trail-and-its-photos_0_<uuid>.png" -> "01-trail-and-its-photos"
            frame="${readable%%_*}"
            if [[ -f "$staging/$exported" && -n "$frame" ]]; then
                mv -f "$staging/$exported" "$output_dir/$frame$suffix.png"
            fi
            attachment_index=$((attachment_index + 1))
        done
        test_index=$((test_index + 1))
    done
    rm -rf "$staging"
}

case "$appearance_mode" in
    light) capture_pass light "" ;;
    dark) capture_pass dark "" ;;
    both)
        capture_pass light ""
        capture_pass dark "-dark"
        ;;
    *) echo "Unknown appearance: $appearance_mode" >&2; exit 2 ;;
esac
echo "Exported to $output_dir"

shopt -s nullglob
captured=("$output_dir"/*.png)
if [[ ${#captured[@]} -eq 0 ]]; then
    echo "No screenshots were exported — check the run above." >&2
    exit 1
fi
for shot in "${captured[@]}"; do
    size="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$shot" 2>/dev/null \
        | awk '/pixel/ { printf "%s ", $2 }')"
    printf '  %-40s %s\n' "$(basename "$shot")" "$size"
done
echo "${#captured[@]} screenshot(s) in $output_dir"

if [[ "$keep_device" == false ]]; then
    xcrun simctl shutdown "$udid"
fi
