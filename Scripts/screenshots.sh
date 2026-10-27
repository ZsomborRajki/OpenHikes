#!/usr/bin/env bash
#
# The whole App Store screenshot set: Scripts/screenshots-light.sh, then
# Scripts/screenshots-dark.sh, with the same options handed to both.
#
# One after the other rather than side by side, although each claims its own
# simulator and derived data and could: two simulators building and driving
# MapKit at once make the machine slow enough that the waits in the frames
# start losing, and a screenshot run is not the place to find out which. Run
# the two scripts in two terminals with separate --output roots when that
# trade is worth it.
#
# Debug one appearance with its own script — `--frame 03` shoots a single
# frame — rather than with this one.

set -uo pipefail

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# One UTC date for both appearances, even if the light pass crosses midnight.
export OPENHIKES_SCREENSHOT_DATE="${OPENHIKES_SCREENSHOT_DATE:-$(date -u +%F)}"
for option in "$@"; do
    if [[ "$option" == --prepared-device ]]; then
        echo "Use screenshots-light.sh and screenshots-dark.sh on separate fresh pool claims with --prepared-device." >&2
        exit 2
    fi
done
light=0
dark=0
"$scripts/screenshots-light.sh" "$@" || light=$?
"$scripts/screenshots-dark.sh" "$@" --append || dark=$?

if [[ $light -ne 0 || $dark -ne 0 ]]; then
    echo "Light exited $light, dark exited $dark." >&2
    exit 1
fi
