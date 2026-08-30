#!/usr/bin/env bash
#
# Simulator resolution, sourced by Scripts/run-ui-tests.sh and
# Scripts/run-performance-tests.sh. Not executable on its own.
#
# Both scripts used to send `xcodebuild` to `name=<device>` while doing their
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
# for the iOS runtimes only. Restricted to iOS because watchOS and tvOS devices
# share the listing and can share a name with an iPhone; `available` because an
# unavailable device is one xcodebuild cannot use.
simulator_devices() {
    # The name is matched greedily up to the last two parenthesised groups,
    # since a device name may contain parentheses of its own — the runner image
    # ships `Apple Watch Series 11 (46mm)`.
    xcrun simctl list devices available 2>/dev/null \
        | awk '/^--/ { ios = ($0 ~ /^-- iOS /); next } ios' \
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
