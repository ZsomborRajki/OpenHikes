#!/usr/bin/env bash
#
# The Apple Watch App Store screenshots, from a clean simulator to a folder of
# PNGs. The watch half of Scripts/screenshots.sh.
#
# ## Why this is not that script
#
# The iPhone set is captured by a UI test that taps its way to each screen.
# There is no watch equivalent and there is not going to be one: `OpenHikesWatch`
# has no test bundle and no gate boots a watch simulator — see *The watch app*
# in the instructions file — and `simctl` can install, launch and photograph a
# watch app but cannot tap one.
#
# So each frame is a *launch* rather than a journey. The app is launched once
# per frame with the `--ui-test-*` arguments for that frame, given a moment to
# draw, and photographed. `WatchLaunchEnvironment` parses the arguments and
# `SeededWatchFixture` puts the watch in the state they describe — a library, a
# trail, a position on it, a recording — all of it the payloads a phone would
# have sent, because a watch simulator has no paired phone and every screen in
# this app is drawn from something that arrives over `WCSession`.
#
# That also replaces what looking at a watch screen used to cost: editing
# `OpenHikesWatchApp`'s `WindowGroup` to point at the screen, building, and
# putting it back afterwards.
#
# ## Two things the iPhone script does that cannot be done here
#
# **The status bar cannot be pinned.** `simctl status_bar override` answers
# "Status bar overrides not supported on this platform" on every watchOS
# device, so the time in the corner is whatever time it is and the battery is
# the simulator's. Apple's own watch marketing shots read 10:09 and there is no
# supported way to get there; the frames are honest instead.
#
# **There is no light appearance to capture.** `simctl ui <udid> appearance`
# answers "Runtime does not support userInterfaceStyle", because watchOS has no
# light mode to switch to — the system draws dark and an app draws on it. So
# there is no `--appearance` here and no `-dark` suffix on anything; the set is
# the set.
#
# **Location is granted, not answered.** A watchOS permission alert cannot be
# dismissed by anything in `simctl`, and once one is up the only way out is an
# erase. So the grant is applied *before the first launch*, which is also why
# the device is erased at the start of every run rather than at the end.
#
# ## Two things this does that the iPhone script has no need to
#
# **It pairs the watch to an iPhone, and then wakes that iPhone's Maps.** An
# unpaired watch draws a red crossed-out iPhone in its status bar, in every
# frame, which in a store listing reads as a screenshot taken of a broken
# setup. `simctl pair` answers it — and introduces the problem that cost the
# most time here, because **a paired watch fetches its map tiles through its
# companion**. The watch's own log says so:
#
#     [GeoServices:TileLoading] [Companion] Error loading tile key {…}:
#     Code=4099 "The connection to service … com.apple.nanomaps.xpc.GeoServices
#     was invalidated from this process."
#
# …with each request timing out after exactly 60 seconds. Unpaired, the watch
# uses its own network and the map draws; paired, the tiles go through a
# companion whose maps stack is not running, and the map frame comes out as
# MapKit's grey placeholder grid. Launching `com.apple.Maps` on the companion
# starts that stack and the tiles arrive. Nothing of the app runs there, and
# the two never speak: a `--ui-testing` launch does not activate `WCSession` at
# all, so every figure in the frames comes from the seeded fixture and none of
# it from a link.
#
# `--no-pair` skips all of it, and is the fallback if this ever stops working:
# an unpaired watch draws its map and wears the glyph.
#
# **It pins the locale.** A simulator inherits the host's region, so on this
# machine the frames came out reading "4,2 km" and "2026. Sep 7." — correct,
# and not the set anybody uploads to an English listing. Every figure in this
# app is formatted through the reader's locale on purpose, which makes the
# locale part of what a screenshot run has to decide rather than inherit.
#

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The repository's own iOS name-to-UDID resolution, for the companion phone
# only. The watch is resolved by `watch_udid` below, which is the same function
# pointed at the other platform — see its header for why the two are separate.
# shellcheck source=lib/simulator.sh
source "$repository_root/Scripts/lib/simulator.sh"
project="$repository_root/OpenHikes.xcodeproj"
scheme="OpenHikesWatch"

device_name="${OPENHIKES_WATCH_SCREENSHOT_DEVICE:-OpenHikes Watch Screenshots}"
device_type="${OPENHIKES_WATCH_SCREENSHOT_DEVICE_TYPE:-Apple Watch Ultra 4 (49mm)}"
output_dir="$repository_root/Screenshots/WatchOutput"
derived_data="$repository_root/DerivedData/WatchScreenshots"
app_bundle_id="tappium.com.OpenHikes.watchkitapp"
companion_name="${OPENHIKES_WATCH_COMPANION_DEVICE:-OpenHikes Watch Companion}"
companion_type="${OPENHIKES_WATCH_COMPANION_TYPE:-iPhone 18 Pro}"
# English and metric, without having to force the units to disagree with the
# locale. That rules out the obvious two: en_US is imperial, and en_GB prints
# road distances in miles — which this app honours, so an en_GB frame reads
# "6.6 mi" beside a German place name. en_IE is English, metric, and formats a
# date the way most of the world reads one. Override for a localised set;
# `--locale en_US` is the right call for a US listing and will print miles.
locale_id="${OPENHIKES_WATCH_LOCALE:-en_IE}"
keep_device=false
skip_build=false
skip_pair=false
skip_erase=false
# How long a launch is given to settle before it is photographed.
#
# Enough for the status bar, which is the whole of what a text frame waits for:
# a freshly booted watch draws the red crossed-out iPhone until it has settled
# with its companion. `simctl list pairs` reports `connected` throughout that
# window, so the pair state is no use as a signal for it and a wait is what
# there is.
settle_seconds="${OPENHIKES_WATCH_SETTLE:-15}"
# What a frame with a map on it gets instead.
#
# The watch fetches its own tiles, and until they land the map is the green
# route on MapKit's grey placeholder grid — which is also what this app
# genuinely looks like offline, so the frame is wrong in a way that reads as
# deliberate rather than as unfinished. The device is erased at the start of
# every run, so this is always paid from a cold cache.
#
# Measured on an erased device: at 25 seconds the basemap had still not
# arrived; at 60 it is Berchtesgaden, the lake and the labels, every time.
map_settle_seconds="${OPENHIKES_WATCH_MAP_SETTLE:-60}"
# How long a frame waits for the pair to report `connected` before going ahead
# without it. Generous, because the cost of being wrong is the unpaired glyph
# in a store frame and the cost of waiting is seconds on a run done rarely.
pair_wait_seconds="${OPENHIKES_WATCH_PAIR_WAIT:-45}"
# How long a *newly paired* run waits before capturing anything. Only ever paid
# on a first run — see `warm_up`.
sync_wait_seconds="${OPENHIKES_WATCH_SYNC_WAIT:-120}"

usage() {
    cat <<'EOF'
Usage: Scripts/watch-screenshots.sh [options]

Captures the Apple Watch App Store screenshot set on a dedicated simulator.

Options:
  --output <dir>     Where the PNGs land (default: Screenshots/WatchOutput)
  --device <name>    Simulator name to create and reuse
  --device-type <t>  Simulator device type
                     (default: Apple Watch Ultra 4 (49mm))
  --locale <id>      Locale to pin the simulator to (default: en_IE). This is
                     what the figures are formatted in; without it the frames
                     inherit whatever region the Mac is set to.
  --settle <n>       Seconds to let a text-only frame settle (default: 15).
                     A frame with a map on it waits 60 instead; lower that
                     with OPENHIKES_WATCH_MAP_SETTLE and it comes out as
                     MapKit's grey placeholder grid.
  --no-build         Reuse the last build in DerivedData/WatchScreenshots
  --no-pair          Do not pair a companion iPhone. Quicker — it builds the
                     watch scheme alone rather than the whole app — but every
                     frame carries the unpaired-iPhone glyph in its status bar.
  --no-erase         Reuse the simulator as it is. Trades the clean-slate
                     guarantee for MapKit's tile cache, which is what a map
                     frame needs when a cold fetch is being throttled — see
                     "When the map comes out grey" in Screenshots/README.md.
  --keep             Leave the simulators booted afterwards
  -h, --help         Show this help

The simulator is erased before every run, so a capture never inherits a photo
library, a location or a permission answer from an earlier one. It does not
inherit MapKit's tile cache either, which is the one place that costs
something — see --no-erase.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) output_dir="${2:?--output needs a directory}"; shift 2 ;;
        --device) device_name="${2:?--device needs a name}"; shift 2 ;;
        --device-type) device_type="${2:?--device-type needs a type}"; shift 2 ;;
        --locale) locale_id="${2:?--locale needs an identifier}"; shift 2 ;;
        --settle) settle_seconds="${2:?--settle needs a number}"; shift 2 ;;
        --no-build) skip_build=true; shift ;;
        --no-pair) skip_pair=true; shift ;;
        --no-erase) skip_erase=true; shift ;;
        --keep) keep_device=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# The frames, in upload order: "<name>|<settle seconds>|<launch arguments>".
#
# The settle is per frame because only one frame needs the long one. See
# `settle_seconds` for what it buys; the two map frames pay it and the three
# that draw nothing but text do not.
#
# Five rather than the iPhone set's seven, because a watch listing is looked at
# on a phone and the app has fewer screens worth the room. The order is the
# order they appear in on the listing, and the first two carry it: a trail on
# the wrist, and the map that is the reason to raise it.
#
# `--ui-testing` gates every other flag — see `WatchLaunchEnvironment` — so it
# is on every line here.
frames=(
    "01-your-trails|$settle_seconds|--ui-testing --ui-test-screen=trails --ui-test-queued-walks=1"
    "02-the-trail-on-your-wrist|$map_settle_seconds|--ui-testing --ui-test-screen=map --ui-test-follow=0.38"
    "03-how-much-is-left|$map_settle_seconds|--ui-testing --ui-test-screen=figures --ui-test-follow=0.38"
    "04-recording-from-the-wrist|$settle_seconds|--ui-testing --ui-test-screen=record --ui-test-recording=running"
    "05-your-iphone-s-hike|$settle_seconds|--ui-testing --ui-test-screen=record --ui-test-phone-recording=running"
)

# The newest watchOS runtime installed, so the frames show the current system
# chrome rather than whatever old runtime happens to be installed beside it.
runtime_id() {
    xcrun simctl list runtimes --json \
        | /usr/bin/plutil -extract runtimes json -o - -- - \
        | /usr/bin/grep -o '"identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-[^"]*"' \
        | sed 's/.*"\(com[^"]*\)"/\1/' \
        | sort -V \
        | tail -1
}

# Name to UDID, for watchOS.
#
# `Scripts/lib/simulator.sh` is sourced above for the companion phone only,
# and deliberately not used here: its `simulator_devices` filters the listing
# to `-- iOS --` sections, which is the whole point of it — an iPhone and an
# Apple Watch can share a name and the UI test runner must never resolve one
# to the other. This is the same function with the other platform, and it
# keeps that guarantee by staying separate.
watch_udid() {
    local wanted="$1" devices matches booted
    devices="$(xcrun simctl list devices available 2>/dev/null \
        | awk '/^--/ { watch = ($0 ~ /^-- watchOS /); next } watch' \
        | sed -nE 's/^[[:space:]]+(.+) \(([0-9A-Fa-f-]{36})\) \(([^()]+)\)[[:space:]]*$/\2\t\3\t\1/p')"
    [[ -n "$devices" ]] || return 1
    matches="$(printf '%s\n' "$devices" | awk -F'\t' -v name="$wanted" '$3 == name')"
    [[ -n "$matches" ]] || return 1
    # `if` rather than `[[ … ]] && …`: under `set -e` a bare `&&` list whose
    # test fails is a failing command, so the common case — a device that is
    # not booted — would take the whole script down.
    booted="$(printf '%s\n' "$matches" | awk -F'\t' '$2 == "Booted"')"
    if [[ -n "$booted" ]]; then
        matches="$booted"
    fi
    if (( $(printf '%s\n' "$matches" | wc -l) > 1 )); then
        echo "More than one available watchOS simulator named '$wanted'." >&2
        echo "Delete one, or pass --device with another name." >&2
        return 2
    fi
    printf '%s\n' "$matches" | cut -f1
}

# `|| resolution=$?` rather than `|| true`: `watch_udid` answers 2 for a name
# that matches more than one device, and swallowing that would create a *third*
# one with the same name rather than stop and say so.
resolution=0
udid="$(watch_udid "$device_name")" || resolution=$?
if (( resolution > 1 )); then
    exit "$resolution"
fi
if [[ -z "$udid" ]]; then
    runtime="$(runtime_id)"
    [[ -n "$runtime" ]] || { echo "No watchOS simulator runtime installed." >&2; exit 1; }
    echo "Creating '$device_name' ($device_type on ${runtime##*.})"
    udid="$(xcrun simctl create "$device_name" "$device_type" "$runtime")"
fi
echo "Simulator: $device_name ($udid)"

# The iOS runtime to build a companion on. Its own resolution rather than
# `runtime_id`'s, which is watchOS.
phone_runtime_id() {
    xcrun simctl list runtimes --json \
        | /usr/bin/plutil -extract runtimes json -o - -- - \
        | /usr/bin/grep -o '"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-[^"]*"' \
        | sed 's/.*"\(com[^"]*\)"/\1/' \
        | sort -V \
        | tail -1
}

# Every pair this watch is already half of.
watch_pairs() {
    xcrun simctl list pairs \
        | awk -v watch="$udid" '
            /^[0-9A-Fa-f-]{36} \(/ { pair = $1; next }
            $0 ~ watch && pair != "" { print pair; pair = "" }'
}

# Whether *this* watch's pair reports `connected`.
#
# Scoped to this pair rather than `grep -q "(active, connected)"` over the whole
# listing. A machine that has Xcode's own paired watch and iPhone on it answers
# that grep from the wrong pair, and every wait below then returns at once —
# which is a set of frames wearing the unpaired glyph this exists to remove,
# and no warning, because the same grep decides that too.
pair_is_connected() {
    xcrun simctl list pairs \
        | awk -v watch="$udid" '
            /^[0-9A-Fa-f-]{36} \(/ { connected = ($0 ~ /\(active, connected\)/); next }
            connected && $0 ~ watch { found = 1 }
            END { exit(found ? 0 : 1) }'
}

# Whether this watch is already paired to this companion.
#
# **An existing correct pair is left alone, and that is not an optimisation.**
# Unpairing and re-pairing forces a fresh sync, and a watch in the middle of
# one is a watch that reports no companion and starves MapKit: the frames come
# out as a green route on MapKit's grey placeholder grid with a red
# disconnected-iPhone glyph in the status bar, for a minute or more after the
# device is otherwise ready. Both look exactly like bugs in the app. The pair
# survives the erase above — it is a property of the device pair, not of the
# device's contents — so on every run after the first there is nothing to do.
is_paired_to_companion() {
    xcrun simctl list pairs \
        | awk -v watch="$udid" -v phone="$companion_udid" '
            /^[0-9A-Fa-f-]{36} \(/ { seen_watch = 0; next }
            $0 ~ watch { seen_watch = 1; next }
            seen_watch && $0 ~ phone { found = 1 }
            END { exit(found ? 0 : 1) }'
}

# Erase, then boot, then wait. Erasing a booted device is a shutdown in
# disguise, so the order matters, and `bootstatus` is what makes the wait an
# observation rather than a guess.
if [[ "$skip_erase" == false ]]; then
    xcrun simctl shutdown "$udid" 2>/dev/null || true
    xcrun simctl erase "$udid"
fi

if [[ "$skip_pair" == false ]]; then
    companion_udid="$(resolve_simulator_udid "$companion_name" 2>/dev/null || true)"
    if [[ -z "$companion_udid" ]]; then
        phone_runtime="$(phone_runtime_id)"
        if [[ -z "$phone_runtime" ]]; then
            echo "No iOS simulator runtime installed; continuing unpaired." >&2
            skip_pair=true
        else
            echo "Creating '$companion_name' ($companion_type)"
            companion_udid="$(xcrun simctl create \
                "$companion_name" "$companion_type" "$phone_runtime")"
        fi
    fi
fi

# Boots a device if it is not booted already, and waits either way.
ensure_booted() {
    xcrun simctl boot "$1" 2>/dev/null || true
    xcrun simctl bootstatus "$1" -b >/dev/null
}

just_paired=false
if [[ "$skip_pair" == false ]] && ! is_paired_to_companion; then
    # Only when the pairing is actually wrong — see `is_paired_to_companion`.
    # Any *other* pair has to go first: a watch cannot be paired twice, and one
    # naming a phone that has since been deleted is still listed as active and
    # still refuses a new pair, which is the state a machine gets into by
    # tidying up simulators after a run.
    echo "Pairing with '$companion_name'…"
    just_paired=true
    while read -r pair; do
        [[ -n "$pair" ]] || continue
        xcrun simctl unpair "$pair" 2>/dev/null || true
    done < <(watch_pairs)
    xcrun simctl shutdown "$companion_udid" 2>/dev/null || true
    xcrun simctl pair "$udid" "$companion_udid" >/dev/null
fi

if [[ "$skip_pair" == false ]]; then
    # The phone first, then the watch. Pairing makes the watch restart to sync
    # with its new companion, and a watch booted before the phone can be taken
    # down by that restart *after* its own `bootstatus` returned — which is a
    # run that then fails on the next command with "device is not booted".
    ensure_booted "$companion_udid"
    # The companion's maps stack, started by opening its Maps app — see this
    # file's header. Without it every map frame is the grey grid.
    xcrun simctl launch "$companion_udid" com.apple.Maps >/dev/null 2>&1 || true
fi

ensure_booted "$udid"

if [[ "$skip_pair" == false ]]; then
    # Waited on rather than slept through: the glyph this exists to remove is
    # drawn until the pair reports `connected`, and how long that takes is a
    # property of the machine.
    for _ in $(seq 1 30); do
        if pair_is_connected; then
            break
        fi
        sleep 1
    done
    if ! pair_is_connected; then
        echo "The pair never connected; frames will carry the unpaired glyph." >&2
    fi
    # Again, because the sync above can have restarted it since.
    ensure_booted "$udid"
fi

# After the erase, which takes these with everything else, and before the first
# launch, which is the one that reads them. No reboot is needed: a watchOS app
# resolves its locale at launch, and every frame here is its own launch.
xcrun simctl spawn "$udid" defaults write -g AppleLocale -string "$locale_id"
xcrun simctl spawn "$udid" defaults write -g AppleLanguages \
    -array "${locale_id//_/-}"

# What is built, and for which device, depends entirely on whether there is a
# companion — and the difference is not an optimisation.
#
# **A paired watch app has to have its phone app installed too.** watchOS
# mirrors the companion's app list, so a watch app whose phone app is missing
# is an orphan, and the pairing sync *deletes it* — some minutes in, which is
# the middle of a capture. The symptom is `simctl launch` answering
# `FBSOpenApplicationServiceErrorDomain` code 4 from the third or fourth frame
# on, for an app that was launching a minute earlier, and it survives a reboot
# because the app is genuinely gone. So the paired path builds the `OpenHikes`
# scheme, installs `OpenHikes.app` on the phone, and installs the watch app
# **out of that bundle** — which is the arrangement a real pairing has, and
# costs one build rather than two because the iOS app embeds the watch one.
#
# Unpaired there is no sync and no orphan, so the watch scheme alone is
# quicker and is what `--no-pair` is for.
if [[ "$skip_pair" == false ]]; then
    build_scheme="OpenHikes"
    build_destination="platform=iOS Simulator,id=$companion_udid"
    phone_app="$derived_data/Build/Products/Debug-iphonesimulator/OpenHikes.app"
    app="$phone_app/Watch/OpenHikesWatch.app"
else
    build_scheme="$scheme"
    build_destination="platform=watchOS Simulator,id=$udid"
    phone_app=""
    app="$derived_data/Build/Products/Debug-watchsimulator/OpenHikesWatch.app"
fi

if [[ "$skip_build" == false ]]; then
    echo "Building ${build_scheme}…"
    # The log sits beside the derived data, and `>` does not create a directory:
    # on a clean checkout `DerivedData/` does not exist yet, and without this the
    # redirection fails before `xcodebuild` runs — reported as "Build failed" with
    # no log to read.
    mkdir -p "$(dirname "$derived_data")"
    xcodebuild build \
        -project "$project" \
        -scheme "$build_scheme" \
        -destination "$build_destination" \
        -derivedDataPath "$derived_data" \
        > "$derived_data.log" 2>&1 \
        || { echo "Build failed; see $derived_data.log" >&2; exit 1; }
fi

[[ -d "$app" ]] || { echo "No built app at $app. Drop --no-build." >&2; exit 1; }

if [[ -n "$phone_app" ]]; then
    xcrun simctl install "$companion_udid" "$phone_app"
fi
xcrun simctl install "$udid" "$app"
# Before the first launch, deliberately. See this file's header: a watchOS
# permission alert cannot be dismissed by anything in simctl, so a run that let
# one appear would photograph five pictures of it.
xcrun simctl privacy "$udid" grant location-always "$app_bundle_id"

mkdir -p "$output_dir"
rm -f "${output_dir:?}"/*.png

# Launches one frame, retrying a refusal.
#
# `simctl launch` answers `FBSOpenApplicationServiceErrorDomain` code 4 when
# the previous instance has not finished going away — which is the shape of
# every frame here, since each one terminates the last. It is a race rather
# than a failure, and it costs a green run nothing to be patient about: the
# retry only happens when the first attempt was refused.
launch_frame() {
    local arguments="$1" attempt
    for attempt in 1 2 3; do
        # shellcheck disable=SC2086 # the arguments are a deliberate word list
        if xcrun simctl launch "$udid" "$app_bundle_id" $arguments >/dev/null 2>&1; then
            return 0
        fi
        sleep "$attempt"
    done
    echo "Could not launch the app with: $arguments" >&2
    return 1
}

# Blocks until the pair reports `connected`, or gives up quietly.
#
# Called before every frame rather than once, because the connection does not
# simply come up and stay up: the pairing sync restarts the watch a little
# after a pair is made, and a set captured across that restart has the glyph on
# some frames and not others — which is worse than having it on all of them,
# because it looks like a bug in the app rather than a fact about simulators.
wait_for_pair() {
    local _
    [[ "$skip_pair" == false ]] || return 0
    for _ in $(seq 1 "$pair_wait_seconds"); do
        if pair_is_connected; then
            return 0
        fi
        sleep 1
    done
    return 0
}

# One launch whose picture is thrown away.
#
# MapKit has no tiles for this route until something has asked for them, so
# without this the map frame is a green line on an empty grid — the offline
# state, which is a real one this app has and not the one the frame is for. The
# map frame is the one warmed because it is the only one that fetches anything.
#
# On a run that had to pair, this also absorbs the pairing sync. That sync is
# the one thing here that takes minutes rather than seconds, and it is paid
# once ever: the pair outlives both the erase and the devices being shut down,
# so every later run finds it already correct and skips it.
warm_up() {
    local entry
    if [[ "$just_paired" == true ]]; then
        echo "Waiting out the pairing sync (once, on a first run)…"
        sleep "$sync_wait_seconds"
    fi
    for entry in "${frames[@]}"; do
        case "${entry%%|*}" in
            *trail-on-your-wrist*)
                echo "Warming the map…"
                xcrun simctl terminate "$udid" "$app_bundle_id" 2>/dev/null || true
                launch_frame "${entry#*|*|}"
                sleep "$map_settle_seconds"
                xcrun simctl terminate "$udid" "$app_bundle_id" 2>/dev/null || true
                return 0
                ;;
        esac
    done
}

capture() {
    local entry name settle arguments rest shot
    echo "Capturing…"
    for entry in "${frames[@]}"; do
        name="${entry%%|*}"
        rest="${entry#*|}"
        settle="${rest%%|*}"
        arguments="${rest#*|}"
        # Terminated rather than relaunched over the top: a watch app already
        # running is brought to the front with the arguments it was launched
        # with the first time, so every frame after the first would be the
        # first one again.
        xcrun simctl terminate "$udid" "$app_bundle_id" 2>/dev/null || true
        wait_for_pair
        launch_frame "$arguments"
        sleep "$settle"
        shot="$output_dir/$name.png"
        xcrun simctl io "$udid" screenshot "$shot" >/dev/null 2>&1
        printf '  %s\n' "$(basename "$shot")"
    done
    xcrun simctl terminate "$udid" "$app_bundle_id" 2>/dev/null || true
}

warm_up
capture

shopt -s nullglob
captured=("$output_dir"/*.png)
if [[ ${#captured[@]} -eq 0 ]]; then
    echo "No screenshots were captured — check the run above." >&2
    exit 1
fi
echo "Exported to $output_dir"
for shot in "${captured[@]}"; do
    size="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$shot" 2>/dev/null \
        | awk '/pixel/ { printf "%s ", $2 }')"
    printf '  %-40s %s\n' "$(basename "$shot")" "$size"
done
echo "${#captured[@]} screenshot(s) in $output_dir"

if [[ "$keep_device" == false ]]; then
    xcrun simctl shutdown "$udid"
    if [[ "$skip_pair" == false ]]; then
        xcrun simctl shutdown "$companion_udid" 2>/dev/null || true
    fi
fi
