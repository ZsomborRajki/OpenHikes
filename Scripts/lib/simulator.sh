#!/usr/bin/env bash
#
# Simulator resolution, sourced by Scripts/run-ui-tests.sh,
# Scripts/lib/screenshots.sh and Scripts/watch-screenshots.sh. Not executable
# on its own.
#
# The script used to send `xcodebuild` to `name=<device>` while doing its
# simulator housekeeping — clearing a leftover simulated location, granting
# location authorisation, reading the app container back out — against
# `simctl booted`. `booted` is not a device: with more than one simulator up it
# is whichever one simctl picks, so the location cleared, the permission
# granted and the container read could each belong to a device the test run
# never touched. The failure is silent in both directions — a run that fights a
# stale location, and a report assembled from another device's files.
#
# So a name is resolved to exactly one UDID once, up front, and every command
# afterwards is addressed by that UDID.

# `xcrun simctl list devices available`, reduced to `udid<TAB>state<TAB>name`
# for the iOS runtimes only, or for the one iOS version given. Restricted to iOS
# because watchOS and tvOS devices share the listing and can share a name with
# an iPhone; `available` because an unavailable device is one xcodebuild cannot
# use.
simulator_devices() {
    local version="${1:-}"
    # The name is matched greedily up to the last two parenthesised groups,
    # since a device name may contain parentheses of its own — the runner image
    # ships `Apple Watch Series 11 (46mm)`.
    xcrun simctl list devices available 2>/dev/null \
        | awk -v version="$version" '/^--/ { ios = ($0 ~ /^-- iOS /) && (version == "" || $0 == "-- iOS " version " --"); next } ios' \
        | sed -nE 's/^[[:space:]]+(.+) \(([0-9A-Fa-f-]{36})\) \(([^()]+)\)[[:space:]]*$/\2	\3	\1/p'
}

# Prints the UDID for a simulator name, or echoes back a UDID that exists.
#
# A booted device wins over a shutdown one of the same name, because that is
# the device a developer has open and the one xcodebuild would reuse. Anything
# still ambiguous after that is an error rather than a guess: two devices
# sharing a name is exactly the situation this function exists to stop being
# resolved silently, and `--device <UDID>` says which one.
resolve_simulator_udid() {
    local wanted="$1"
    local devices
    devices="$(simulator_devices)"

    if [[ -z "$devices" ]]; then
        echo "No available iOS simulators. Check 'xcrun simctl list devices available'." >&2
        return 1
    fi

    if [[ "$wanted" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]]; then
        local known
        known="$(printf '%s\n' "$devices" | awk -F'\t' -v udid="$wanted" 'tolower($1) == tolower(udid) { print $1 }')"
        if [[ -z "$known" ]]; then
            echo "No available iOS simulator with UDID $wanted." >&2
            return 1
        fi
        printf '%s\n' "$known"
        return 0
    fi

    local matches
    matches="$(printf '%s\n' "$devices" | awk -F'\t' -v name="$wanted" '$3 == name')"
    if [[ -z "$matches" ]]; then
        echo "No available iOS simulator named '$wanted'. Available:" >&2
        printf '%s\n' "$devices" | awk -F'\t' '{ print "  " $3 "  (" $1 ", " $2 ")" }' >&2
        return 1
    fi

    local booted
    booted="$(printf '%s\n' "$matches" | awk -F'\t' '$2 == "Booted"')"
    if [[ -n "$booted" ]]; then
        matches="$booted"
    fi

    if (( $(printf '%s\n' "$matches" | wc -l) > 1 )); then
        echo "More than one available iOS simulator named '$wanted':" >&2
        printf '%s\n' "$matches" | awk -F'\t' '{ print "  " $1 "  (" $2 ")" }' >&2
        echo "Pass --device <UDID> to say which one." >&2
        return 1
    fi

    printf '%s\n' "$matches" | cut -f1
}

# Prints the UDID of the one booted iOS simulator with this name, for a caller
# that has just booted it by name and needs to know the boot held.
#
# resolve_simulator_udid gives the wrong answer here. The CI image has two
# simulators named `iPhone 18 Pro`, one per iOS runtime, and `simctl boot`
# picks one of them. When that boot dies — `bootstatus -b` can report it
# finished with the device already down — neither device is booted, so
# resolve_simulator_udid refuses the name as ambiguous. That reads as a fault in
# the script, not in the boot. This says what actually happened, and lists the
# state of every device with that name.
booted_simulator_udid() {
    local wanted="$1"
    local matches booted
    matches="$(simulator_devices | awk -F'\t' -v name="$wanted" '$3 == name')"
    booted="$(printf '%s\n' "$matches" | awk -F'\t' '$2 == "Booted" { print $1 }')"

    if [[ -z "$booted" ]]; then
        echo "No iOS simulator named '$wanted' is booted. If one was just booted, it did not stay up." >&2
        printf '%s\n' "$matches" | awk -F'\t' 'NF { print "  " $1 "  (" $2 ")" }' >&2
        return 1
    fi

    if (( $(printf '%s\n' "$booted" | wc -l) > 1 )); then
        echo "More than one booted iOS simulator is named '$wanted':" >&2
        printf '%s\n' "$booted" | sed 's/^/  /' >&2
        return 1
    fi

    printf '%s\n' "$booted"
}

# Prints the UDID of the simulator with this name on the iOS runtime of the
# selected Xcode's own simulator SDK, for a CI job that has to name its device
# before it builds, and before anything is booted.
#
# A name alone cannot say which device that is. The runner image carries iOS
# runtimes newer than its Xcode, and puts a device of the same name on more
# than one of them on some machines and not on others. xcodebuild's `name=`
# with no `OS=` asks for the newest runtime, so on a machine whose newest
# runtime has no `iPhone 18 Pro` it matched nothing (run 43910913375). And
# where both runtimes have one, `simctl boot` by name could warm one device
# while the tests ran on the other. The SDK's runtime is the one the pinned
# Xcode was built against.
sdk_simulator_udid() {
    local wanted="$1"
    local version matches
    version="$(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null)" || version=""
    if [[ -z "$version" ]]; then
        echo "The selected Xcode reports no iOS Simulator SDK version." >&2
        return 1
    fi

    matches="$(simulator_devices "$version" | awk -F'\t' -v name="$wanted" '$3 == name { print $1 }')"
    if [[ -z "$matches" ]]; then
        echo "No available iOS $version simulator named '$wanted'. The iOS simulators on this machine are:" >&2
        xcrun simctl list devices available 2>/dev/null | awk '/^--/ { ios = ($0 ~ /^-- iOS /) } ios' >&2
        return 1
    fi

    if (( $(printf '%s\n' "$matches" | wc -l) > 1 )); then
        echo "More than one available iOS $version simulator is named '$wanted':" >&2
        printf '%s\n' "$matches" | sed 's/^/  /' >&2
        return 1
    fi

    printf '%s\n' "$matches"
}
