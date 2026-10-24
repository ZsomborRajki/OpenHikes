#!/usr/bin/env bash
#
# Opens or closes a booted iPhone Duo simulator, and turns the display that is
# then showing the app to portrait or landscape.
#
# Xcode 27.1 can fold the Duo only by hand, in Device Hub; neither simctl nor
# devicectl has a hinge command. This posts the event Device Hub's own hinge
# slider posts, from inside the simulator — see Scripts/lib/duo-pose.m — and
# that is the whole of why a screenshot run or a UI test can reach the inner
# display at all. Scripts/lib/screenshots.sh calls it for `--pose`.
#
# **Every change is read back.** The event goes through undocumented
# interfaces, and the failure they have when a release moves them is the silent
# kind: the post succeeds and nothing folds. So the display devicectl reports
# as active is waited for after the hinge moves, and the orientation it reports
# after every turn, and a pose that did not happen is an error rather than a
# run of frames shot on the wrong screen.
#
# **One fold from a fresh boot is the move to rely on.** A simulator boots
# closed, and a screenshot run starts from a fresh clone, so `--pose open` is
# a single unfold from cold — which worked every time it was tried. Folding
# back and forth is less dependable: after a few folds the simulator's
# locationd took a close and SpringBoard never swapped the displays, swept or
# not. The read-back reports it; `xcrun simctl shutdown` and `boot` bring the
# device back closed.
#
# The helper is built once per Xcode, with Xcode's own clang, and kept in
# ~/Library/Caches/OpenHikes/duo-pose.

set -euo pipefail

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/simulator.sh
source "$scripts/lib/simulator.sh"

helper_source="$scripts/lib/duo-pose.m"
cache_dir="${OPENHIKES_DUO_POSE_CACHE:-${HOME:-/tmp}/Library/Caches/OpenHikes/duo-pose}"
# How long a fold may take to show in the display state. It is instant in the
# simulator; this is the time a loaded machine gets before it is called a
# failure.
settle_seconds="${OPENHIKES_DUO_POSE_SETTLE_SECONDS:-10}"
# How long one device orientation is given to turn the display. A turn
# animates for about half a second, and an orientation that turns this display
# some other way — or not at all — has to be told apart from one that is slow.
turn_seconds="${OPENHIKES_DUO_POSE_TURN_SECONDS:-3}"

usage() {
    cat <<'EOF'
Usage: Scripts/duo-pose.sh <open|closed> --device <name|udid> [options]

Opens or closes a booted iPhone Duo simulator, then turns the display that is
showing the app.

Options:
  --device <name|udid>       The simulator (required)
  --orientation <value>      portrait (default) or landscape. Of the interface
                             on the display that is showing it: the inner
                             display opens in landscape, the cover in portrait.
  -h, --help                 Show this help
EOF
}

pose=""
device=""
orientation="portrait"
while [[ $# -gt 0 ]]; do
    case "$1" in
        open|closed) pose="$1"; shift ;;
        --device) device="${2:?--device needs a name or UDID}"; shift 2 ;;
        --orientation) orientation="${2:?--orientation needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
if [[ -z "$pose" ]]; then
    echo "Say open or closed." >&2
    usage >&2
    exit 2
fi
if [[ -z "$device" ]]; then
    echo "--device is required: a pose is never guessed onto whichever simulator is booted." >&2
    exit 2
fi
case "$orientation" in
    portrait|landscape) ;;
    *) echo "Unknown orientation: $orientation (portrait or landscape)" >&2; exit 2 ;;
esac

udid="$(resolve_simulator_udid "$device")"
state="$(simulator_devices | awk -F'\t' -v udid="$udid" '$1 == udid { print $2 }')"
if [[ "$state" != "Booted" ]]; then
    echo "$device is not booted." >&2
    exit 1
fi

# One line per built-in display, as `id<TAB>primary<TAB>active<TAB>rotation`.
# The cover display is the primary one; the inner is the other `LCD`. A field
# devicectl does not report yet is left empty: for a few seconds after a boot
# no display says whether it is active.
displays() {
    local json index=0 name
    json="$(xcrun devicectl device info displays -d "$udid" --json-output - 2>/dev/null)" || return 1
    while name="$(display_field "$json" "$index" name)" && [[ -n "$name" ]]; do
        if [[ "$name" == LCD* ]]; then
            printf '%s\t%s\t%s\t%s\n' \
                "$(display_field "$json" "$index" displayId)" \
                "$(display_field "$json" "$index" primary)" \
                "$(display_field "$json" "$index" active)" \
                "$(display_field "$json" "$index" currentOrientation)"
        fi
        index=$((index + 1))
    done
}

# One field of one display from devicectl's JSON, or nothing.
display_field() {
    /usr/bin/plutil -extract "result.displays.$2.$3" raw -o - -- - <<< "$1" 2>/dev/null || true
}

# `cover` or `inner`, and its rotation, for the display that is active.
active_display() {
    displays | awk -F'\t' '$3 == "true" { print ($2 == "true" ? "cover" : "inner") "\t" $4; exit }'
}

if (( $(displays | wc -l) < 2 )); then
    echo "$device has one display: it is not an iPhone Duo." >&2
    exit 1
fi

# Builds the helper for this Xcode, once: keyed on its source and on the
# developer directory, so a new Xcode or a changed helper builds afresh.
helper_binary() {
    local key binary
    key="$( { cat "$helper_source"; xcode-select -p; } | shasum -a 256 | cut -c1-12)"
    binary="$cache_dir/duo-pose-$key"
    if [[ ! -x "$binary" ]]; then
        mkdir -p "$cache_dir"
        xcrun -sdk iphonesimulator clang -fobjc-arc -O2 -arch "$(uname -m)" \
            -mios-simulator-version-min=17.0 -framework Foundation -framework IOKit \
            "$helper_source" -o "$binary.partial"
        codesign -f -s - "$binary.partial" >/dev/null
        mv -f "$binary.partial" "$binary"
    fi
    printf '%s\n' "$binary"
}
# A helper already built, used as it is: Scripts/run-script-tests.sh's seam,
# so that no case compiles anything. Nothing else sets it.
helper="${OPENHIKES_DUO_POSE_HELPER:-}"
[[ -n "$helper" ]] || helper="$(helper_binary)"

# Whether a display rotation is the orientation asked for. Landscape is
# either way round; portrait is the right way up.
is_wanted_rotation() {
    case "$orientation:$1" in
        portrait:rot0|landscape:rot90|landscape:rot270) return 0 ;;
        *) return 1 ;;
    esac
}

# Polls until the active display is `screen` — and, unless told `any`, at the
# orientation asked for — for up to `seconds`; returns 1 when it never is.
# Polling the state is the barrier rather than a pause: devicectl answers in a
# fraction of a second.
wait_for_display() {
    local seconds="$1" screen="$2" rotation="$3" deadline current
    deadline=$((SECONDS + seconds))
    while (( SECONDS < deadline )); do
        current="$(active_display)"
        if [[ "${current%%$'\t'*}" == "$screen" ]] \
            && { [[ "$rotation" == any ]] || is_wanted_rotation "${current#*$'\t'}"; }; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

if [[ "$pose" == open ]]; then screen="inner"; degrees=180; else screen="cover"; degrees=0; fi
xcrun simctl spawn "$udid" "$helper" hinge "$degrees"
if ! wait_for_display "$settle_seconds" "$screen" any; then
    echo "The $screen display did not become active after setting the hinge to ${degrees}°." >&2
    exit 1
fi

# The device orientation that turns a display's interface a given way differs
# between the two — the inner display sits a quarter turn from the cover, so
# holding the device on its side is what stands its interface upright — so the
# likeliest is tried first, every one is tried before giving up, and the
# rotation is read back each time. The cover's home screen does not turn at
# all, like any iPhone's: a landscape cover needs an app in front that does.
case "$screen:$orientation" in
    inner:portrait|cover:landscape) device_orientations="landscape-left landscape-right portrait pud" ;;
    *) device_orientations="portrait pud landscape-left landscape-right" ;;
esac
if ! is_wanted_rotation "$(active_display | cut -f2)"; then
    turned=false
    for device_orientation in $device_orientations; do
        xcrun simctl spawn "$udid" "$helper" orientation "$device_orientation"
        if wait_for_display "$turn_seconds" "$screen" wanted; then
            turned=true
            break
        fi
    done
    if [[ "$turned" == false ]]; then
        echo "The $screen display did not turn to $orientation." >&2
        exit 1
    fi
fi

echo "$device: $pose, the $screen display showing, $orientation."
