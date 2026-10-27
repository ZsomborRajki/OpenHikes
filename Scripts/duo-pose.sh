#!/usr/bin/env bash
#
# Opens or closes a booted iPhone Duo simulator, and turns the display that is
# then showing the app to portrait or landscape.
#
# Xcode 27.1 can fold the Duo only by hand, in Device Hub; neither simctl nor
# devicectl has a hinge command. hinge (https://github.com/artemnovichkov/hinge)
# posts the event Device Hub's own hinge slider posts, from inside the
# simulator, and that is the whole of why a screenshot run or a UI test can
# reach the inner display at all. It is an optional tool, found the way
# Scripts/lib/hinge.sh says, and only opening needs it: a simulator boots
# closed, so without hinge a closed pose is read back rather than posted.
# Scripts/lib/screenshots.sh calls this for `--pose`.
#
# **Every change is read back.** The event goes through undocumented
# interfaces, and the failure they have when a release moves them is the silent
# kind: the post succeeds and nothing folds. hinge returns once CoreMotion
# reports the new angle, and this then waits for the display devicectl reports
# as active, and for the orientation it reports after every turn. The two
# readings fail apart, and the error says which: an angle that never arrives
# means the event has changed, and an angle that arrives with no display behind
# it means the simulator has stopped following the hinge. Either way a pose
# that did not happen is an error rather than a run of frames shot on the wrong
# screen.
#
# **One fold from a fresh boot is the move to rely on.** A simulator boots
# closed, and a screenshot run starts from a fresh clone, so `--pose open` is
# a single unfold from cold. That took on every clone but one, where the
# displays never swapped and posting 180° again changed nothing, minutes
# later as straight away; moving the hinge to 90° first did. So a post that
# does not take is tried once more by way of half-open, which is a change from
# any angle this posts. Folding back and forth is less dependable: after a few
# folds the simulator's locationd took a close and SpringBoard never swapped
# the displays, swept or not. The read-back reports it; `xcrun simctl
# shutdown` and `boot` bring the device back closed.
#
# **The device is always named.** Given none, hinge folds the only booted
# iPhone Duo and refuses to choose between several; this passes it the one it
# was given, so the pose lands there whatever else is booted.
#
# hinge builds its in-simulator helper once per Xcode, with Xcode's own clang,
# and keeps it in ~/.cache/hinge.

set -euo pipefail

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/simulator.sh
source "$scripts/lib/simulator.sh"
# shellcheck source=lib/hinge.sh
source "$scripts/lib/hinge.sh"

# How long each half of a fold may take: hinge's wait for CoreMotion to report
# the angle, then the wait for the display state to show it. Both are instant
# in the simulator; this is the time a loaded machine gets before it is called
# a failure.
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
#
# A write that fails ends the list. Where SIGPIPE is ignored, as it is in CI, a
# reader that has gone does not stop this loop: the line that failed stays in
# bash's output buffer, each `$(…)` forked after it writes that line out again,
# and the loop reads it as the name of one more display, forever.
displays() {
    local json index=0 name
    json="$(xcrun devicectl device info displays -d "$udid" --json-output - 2>/dev/null)" || return 1
    while name="$(display_field "$json" "$index" name)" && [[ -n "$name" ]]; do
        if [[ "$name" == LCD* ]]; then
            printf '%s\t%s\t%s\t%s\n' \
                "$(display_field "$json" "$index" displayId)" \
                "$(display_field "$json" "$index" primary)" \
                "$(display_field "$json" "$index" active)" \
                "$(display_field "$json" "$index" currentOrientation)" || return 1
        fi
        index=$((index + 1))
    done
}

# One field of one display from devicectl's JSON, or nothing.
display_field() {
    /usr/bin/plutil -extract "result.displays.$2.$3" raw -o - -- - <<< "$1" 2>/dev/null || true
}

# `cover` or `inner`, and its rotation, for the display that is active. The
# whole list is read rather than left at the first match, so that `displays`
# never writes to a reader that has gone.
active_display() {
    displays | awk -F'\t' '$3 == "true" && !found { print ($2 == "true" ? "cover" : "inner") "\t" $4; found = 1 }'
}

if (( $(displays | wc -l) < 2 )); then
    echo "$device has one display: it is not an iPhone Duo." >&2
    exit 1
fi

# Only opening needs hinge. Without it, a closed pose is read back rather than
# posted, and `without_hinge` says what to install should it need a fold or a
# turn after all.
hinge=""
without_hinge=""
if found="$(hinge_command)"; then
    hinge="$found"
else
    without_hinge="$found"
    if [[ "$pose" == open ]]; then
        echo "$device cannot be opened: $without_hinge" >&2
        exit 1
    fi
fi

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

# What hinge said when it last failed, kept for the report.
hinge_said=""
quote_hinge() {
    printf '%s\n' "$hinge_said" | sed 's/^/  /' >&2
}

# Sets the hinge to $1 degrees. hinge returns once CoreMotion reports the
# angle, so `angle_reached` says whether the event moved the hinge at all.
angle_reached=false
set_hinge() {
    local said
    if said="$("$hinge" -d "$udid" -t "$settle_seconds" set "$1" 2>&1)"; then
        angle_reached=true
    else
        angle_reached=false
        hinge_said="$said"
    fi
}

if [[ "$pose" == open ]]; then screen="inner"; degrees=180; else screen="cover"; degrees=0; fi
# Half-open, which shows the inner display: the way round a post that did not
# take (see the header).
half_open_degrees=90
if [[ -n "$hinge" ]]; then
    set_hinge "$degrees"
    if ! wait_for_display "$settle_seconds" "$screen" any; then
        set_hinge "$half_open_degrees"
        wait_for_display "$settle_seconds" inner any || true
        set_hinge "$degrees"
        if ! wait_for_display "$settle_seconds" "$screen" any; then
            if [[ "$angle_reached" == true ]]; then
                echo "The hinge reached ${degrees}°, but the $screen display did not become active:" \
                    "the simulator has stopped following the hinge. \`xcrun simctl shutdown\` and" \
                    "\`boot\` bring it back closed." >&2
            else
                echo "The $screen display did not become active, and hinge failed to set the angle" \
                    "to ${degrees}°:" >&2
                quote_hinge
                echo "If the angle never arrived, the event Device Hub posts has likely changed in" \
                    "this Xcode; \`brew upgrade hinge\` brings a newer hinge, if there is one." >&2
            fi
            exit 1
        fi
    fi
    # The display is what a frame is shot on, so a fold that shows there
    # stands; an angle hinge could not confirm is still worth a word.
    if [[ "$angle_reached" == false ]]; then
        echo "warning: the $screen display is active, but hinge could not confirm the angle:" >&2
        quote_hinge
    fi
elif ! wait_for_display "$settle_seconds" "$screen" any; then
    echo "The $screen display is not active, and closing the Duo needs hinge: $without_hinge" >&2
    exit 1
fi

# The device orientation that turns a display's interface a given way differs
# between the two — the inner display sits a quarter turn from the cover, so
# holding the device on its side is what stands its interface upright — so the
# likeliest is tried first, every one is tried before giving up, and the
# rotation is read back each time. The cover's home screen does not turn at
# all, like any iPhone's: a landscape cover needs an app in front that does.
case "$screen:$orientation" in
    inner:portrait|cover:landscape)
        device_orientations="landscape-left landscape-right portrait portrait-upside-down" ;;
    *) device_orientations="portrait portrait-upside-down landscape-left landscape-right" ;;
esac
if ! is_wanted_rotation "$(active_display | cut -f2)"; then
    if [[ -z "$hinge" ]]; then
        echo "The $screen display is not $orientation, and turning it needs hinge:" \
            "$without_hinge" >&2
        exit 1
    fi
    turned=false
    hinge_said=""
    for device_orientation in $device_orientations; do
        # hinge fails when the device orientation it reads back did not
        # change, but the display's rotation is what decides here: its word
        # is kept for the report, and the rotation is read either way.
        said="$("$hinge" -d "$udid" orient "$device_orientation" 2>&1)" || hinge_said="$said"
        if wait_for_display "$turn_seconds" "$screen" wanted; then
            turned=true
            break
        fi
    done
    if [[ "$turned" == false ]]; then
        echo "The $screen display did not turn to $orientation." >&2
        if [[ -n "$hinge_said" ]]; then
            quote_hinge
        fi
        exit 1
    fi
fi

echo "$device: $pose, the $screen display showing, $orientation."
