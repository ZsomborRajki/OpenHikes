#!/usr/bin/env bash
#
# Settled simulator templates, sourced by Scripts/sim-pool.sh,
# Scripts/lib/screenshots.sh and Scripts/watch-screenshots.sh after
# Scripts/lib/simulator.sh. Not executable on its own.
#
# ## What an erase costs
#
# An iOS 27 simulator downloads Siri, dictation, text-to-speech and search
# models the first time it boots, and again on the first boot after every
# `simctl erase`: 1,427 MB across 91 assets, read back from the simulator's own
# `mobileassetd` log on 2026-10-22, nearly all of it inside two minutes. The
# runtime does not carry them, so an erase throws them away and the next boot
# fetches them again. That day the pool erased its devices thirteen times,
# which is up to 18 GB, over a metered connection, of models no test uses.
#
# ## A clone instead of an erase
#
# So a device that has to start clean is replaced with a clone of a template: a
# simulator of the same type and runtime that has booted once, finished its
# downloads and been shut down. `simctl clone` is an APFS copy — seconds, next
# to no disk, no network — and the clone starts with the template's assets, so
# it has nothing to fetch. It is as clean as an erase, because nothing but the
# system has ever run on the template. What changes is the UDID: a clone is a
# new device, so every caller prints or re-reads the one it gets back.
#
# Measured the same evening: a clone of a settled template booted in three
# seconds, never started a download job, and fetched nothing but three asset
# catalogs, the largest 4.5 MB. Its asset store did not grow.
#
# A template is named `OpenHikes Template (<device type>, <runtime>)`, so one
# exists per device type and per runtime, and a runtime update builds a new one
# rather than cloning a device the old runtime would have to boot. Nothing but
# this file should boot, erase or delete one.
#
# ## Settled
#
# A template is shut down once `mobileassetd` has no download left to do, read
# from its own table of active download jobs — not after a duration, because
# the same downloads take two minutes on one connection and twenty on another.
# On 2026-10-22 a fresh template showed four jobs the moment it had booted, nine
# at the peak, and none 158 seconds in, after 1.45 GB. A template booted again
# to refresh it may have nothing to do, and then its table never fills — a
# clone of a settled template showed none for 158 seconds — so it counts as
# settled once the table has stayed empty for OPENHIKES_SIM_TEMPLATE_IDLE_SECONDS
# (60). That minute is what a refresh gets to start an update in: on the same
# clone, the first status requests for the model sets came 27 seconds in. A
# build's table is given the same minute after it empties, because it grew
# from four jobs to nine while the first ones ran: an empty moment between two
# batches would settle a template with half its models, and every clone would
# fetch the rest until the next refresh.
#
# ## Refreshed
#
# Apple ships new versions of these models, and a clone of a template that
# predates them downloads the new versions itself — each clone, every time. So a
# template settled longer ago than OPENHIKES_SIM_TEMPLATE_REFRESH_DAYS (7) is
# booted again to catch up before the next clone: one download for the machine
# rather than one per device.

template_devices_root="${OPENHIKES_SIM_DEVICES_DIR:-${HOME:-/tmp}/Library/Developer/CoreSimulator/Devices}"
template_state_root="${OPENHIKES_SIM_TEMPLATE_DIR:-${HOME:-/tmp}/Library/Caches/OpenHikes/sim-templates}"
template_refresh_days="${OPENHIKES_SIM_TEMPLATE_REFRESH_DAYS:-7}"
template_settle_seconds="${OPENHIKES_SIM_TEMPLATE_SETTLE_SECONDS:-1800}"
template_idle_seconds="${OPENHIKES_SIM_TEMPLATE_IDLE_SECONDS:-60}"
template_prefix="OpenHikes Template"

# The newest runtime installed for a platform — `iOS` or `watchOS` — as its
# identifier, or nothing when there is none. Given a device type as well, the
# newest one that can run it.
#
# The device type is not a refinement. Xcode 27.1 installs an iOS 27.1 runtime
# that runs exactly one device type, the iPhone Duo, beside an iOS 27.0 that
# runs the iPhone 18s — so "the newest iOS" named a runtime that could not
# create the 6.9" screenshot device or a pool device. Building their templates
# on it failed with "Incompatible device", and what followed was an erase: the
# 1.4 GB download templates exist to avoid. A runtime whose listing names no
# device types at all is not ruled out, since nothing says it cannot.
newest_simulator_runtime() {
    local platform="$1" device_type="${2:-}" json index=0 identifier types
    json="$(xcrun simctl list runtimes --json 2>/dev/null)" || return 0
    while identifier="$(/usr/bin/plutil -extract "runtimes.$index.identifier" raw -o - -- - <<< "$json" 2>/dev/null)"; do
        types="$(/usr/bin/plutil -extract "runtimes.$index.supportedDeviceTypes" json -o - -- - <<< "$json" 2>/dev/null || true)"
        index=$((index + 1))
        [[ "$identifier" == "com.apple.CoreSimulator.SimRuntime.$platform-"* ]] || continue
        if [[ -n "$device_type" && -n "$types" && "$types" != *"\"name\":\"$device_type\""* ]]; then
            continue
        fi
        printf '%s\n' "$identifier"
    done | sort -V | tail -1
}

# `OpenHikes Template (iPhone 18 Pro, iOS 27.0)` for an iPhone 18 Pro on
# `com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
simulator_template_name() {
    local version="${2##*.}"
    local platform="${version%%-*}"
    version="${version#*-}"
    printf '%s (%s, %s %s)\n' "$template_prefix" "$1" "$platform" "${version//-/.}"
}

# `udid<TAB>state` of the available iOS simulator with exactly this name.
template_device() {
    simulator_devices | awk -F'\t' -v name="$1" '$3 == name { print $1 "\t" $2; exit }'
}

template_marker() { printf '%s/%s.settled\n' "$template_state_root" "$1"; }

# How many download jobs `mobileassetd` has under way on a device, or nothing
# while it has not written its table yet.
template_active_jobs() {
    local table="$template_devices_root/$1/data/private/var/MobileAsset/AssetsV2/persisted/AutoSetActiveJobDescriptors/AutoSetActiveJobDescriptors_TableOfContents.state"
    /usr/bin/plutil -extract SUCorePersistedStatePolicyFields.currentEntries raw -o - "$table" 2>/dev/null
}

# MARK: The template lock

# Builds and clones take turns, because a template is booted while it is built
# and `simctl clone` needs it shut down. `mkdir` because it is one atomic step;
# the PID inside lets a lock left by a killed run be taken over. No trap: a
# caller's own EXIT trap stays its own, so every path out of a holder releases
# the lock by hand, and a crash is what the PID is for.
template_lock="$template_state_root/.lock"

# Takes the lock, waiting up to the given number of seconds for it (0: do not
# wait). Returns 1 when it is still held at the end of the wait.
take_template_lock() {
    local wait_seconds="$1" waited=0
    mkdir -p "$template_state_root"
    until mkdir "$template_lock" 2>/dev/null; do
        local holder
        holder="$(cat "$template_lock/pid" 2>/dev/null || true)"
        if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
            rm -rf "$template_lock"
            continue
        fi
        # Polling the lock itself — the thing being waited on — rather than
        # sleeping a guess at how long a build takes.
        (( waited < wait_seconds * 10 )) || return 1
        sleep 0.1
        waited=$((waited + 1))
    done
    printf '%s\n' "$$" > "$template_lock/pid"
}

release_template_lock() { rm -rf "$template_lock"; }

template_lock_held() {
    local holder
    holder="$(cat "$template_lock/pid" 2>/dev/null || true)"
    [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null
}

# MARK: Settling

# Waits for `mobileassetd` on a booted device to have nothing left to download.
# Returns 1 when it is still downloading at the deadline.
wait_for_settled_assets() {
    local udid="$1" started now jobs quiet_since=""
    started="$(date +%s)"
    while :; do
        now="$(date +%s)"
        jobs="$(template_active_jobs "$udid")"
        if [[ "$jobs" =~ ^[0-9]+$ ]]; then
            if (( jobs > 0 )); then
                quiet_since=""
            else
                quiet_since="${quiet_since:-$now}"
                (( now - quiet_since < template_idle_seconds )) || return 0
            fi
        fi
        (( now - started < template_settle_seconds )) || return 1
        sleep 2
    done
}

# Whether a template is shut down and settled recently enough to clone as it
# is. Says nothing about whether somebody is about to boot it: see
# `simulator_template_ready`.
template_settled() {
    local udid="$1" marker state
    marker="$(template_marker "$udid")"
    [[ -f "$marker" ]] || return 1
    state="$(simulator_devices | awk -F'\t' -v udid="$udid" '$1 == udid { print $2 }')"
    [[ "$state" == "Shutdown" ]] || return 1
    (( ($(date +%s) - $(stat -f %m "$marker")) < template_refresh_days * 86400 ))
}

# Whether a template can be cloned right now: settled, and not being built or
# refreshed by anyone.
simulator_template_ready() {
    template_settled "$1" && ! template_lock_held
}

# Prints the UDID of a settled template of this device type on this runtime,
# building or refreshing it first when it needs it — the one time that costs a
# download. Progress goes to stderr. Returns 1 when it could not settle one that
# had never settled; one whose refresh runs out of time is still printed.
simulator_template() {
    local device_type="$1" runtime="$2" name udid
    name="$(simulator_template_name "$device_type" "$runtime")"
    udid="$(template_device "$name" | cut -f1)"
    if [[ -n "$udid" ]] && simulator_template_ready "$udid"; then
        printf '%s\n' "$udid"
        return 0
    fi

    if ! take_template_lock "$((template_settle_seconds + 300))"; then
        echo "Timed out waiting for another process to settle $name." >&2
        return 1
    fi
    # Again under the lock: whoever held it may have just built this one.
    udid="$(template_device "$name" | cut -f1)"
    if [[ -n "$udid" ]] && template_settled "$udid"; then
        release_template_lock
        printf '%s\n' "$udid"
        return 0
    fi

    if [[ -z "$udid" ]]; then
        echo "Building $name. Its first boot downloads the system's models — about 1.4 GB, once — and every device cloned from it starts with them." >&2
        if ! udid="$(xcrun simctl create "$name" "$device_type" "$runtime")" || [[ -z "$udid" ]]; then
            release_template_lock
            echo "simctl could not create $name." >&2
            return 1
        fi
    elif [[ -f "$(template_marker "$udid")" ]]; then
        echo "Refreshing $name, settled more than $template_refresh_days days ago, so its clones do not each download what Apple has shipped since." >&2
    else
        echo "Settling $name, which has not finished its downloads." >&2
    fi

    local boot_log
    if ! boot_log="$(xcrun simctl bootstatus "$udid" -b 2>&1)"; then
        printf '%s\n' "$boot_log" >&2
        release_template_lock
        echo "$name did not boot." >&2
        return 1
    fi
    local settled=true
    if ! wait_for_settled_assets "$udid"; then
        settled=false
    fi
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    if [[ "$settled" == false ]]; then
        release_template_lock
        if [[ -f "$(template_marker "$udid")" ]]; then
            # A refresh that ran out of time still leaves a template that
            # settled once, with all it had then and some of what came since,
            # so a clone of it has less to fetch than an erased device. The
            # marker stays as old as it was, so the next clean device carries
            # the refresh on and the download stays the template's.
            echo "$name was still catching up after ${template_settle_seconds}s; it is cloned as it is, and the next clean device carries the refresh on." >&2
            printf '%s\n' "$udid"
            return 0
        fi
        echo "$name was still downloading after ${template_settle_seconds}s; the next build carries on from where it stopped." >&2
        return 1
    fi
    touch "$(template_marker "$udid")"
    release_template_lock
    echo "$name has settled." >&2
    printf '%s\n' "$udid"
}

# Prints the UDID of a new device named `name`, cloned from a template.
# `--no-wait` returns 2 at once when the template is being built or refreshed,
# for a caller holding a lock of its own that must not wait behind a download.
clone_simulator_template() {
    local template="$1" name="$2" wait_seconds=60 clone
    if [[ "${3:-}" == "--no-wait" ]]; then wait_seconds=0; fi
    take_template_lock "$wait_seconds" || return 2
    if ! clone="$(xcrun simctl clone "$template" "$name")" || [[ -z "$clone" ]]; then
        release_template_lock
        echo "simctl could not clone $template as $name." >&2
        return 1
    fi
    release_template_lock
    printf '%s\n' "$clone"
}

# Replaces a device with a clone of a template under the same name, and prints
# the clone's UDID. The clone is made first, under a name of its own, so a
# failed clone leaves the device it was to replace where it was.
replace_simulator_with_clone() {
    local old="$1" template="$2" name="$3" clone status=0
    clone="$(clone_simulator_template "$template" "$name (replacing)" "${4:-}")" || status=$?
    (( status == 0 )) || return "$status"
    xcrun simctl shutdown "$old" >/dev/null 2>&1 || true
    if ! xcrun simctl delete "$old"; then
        # Two devices of one name is the ambiguity Scripts/lib/simulator.sh
        # refuses to resolve, so the clone goes and the old device stays.
        xcrun simctl delete "$clone" >/dev/null 2>&1 || true
        echo "simctl could not delete $old to replace it." >&2
        return 1
    fi
    xcrun simctl rename "$clone" "$name"
    printf '%s\n' "$clone"
}
