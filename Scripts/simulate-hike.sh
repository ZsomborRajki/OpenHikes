#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
default_route="$repository_root/OpenHikes/SimulatedLocations/ThumseeLoopFast.gpx"

action="start"
device="${OPENHIKES_SIMULATOR:-booted}"
route="$default_route"
speed="${OPENHIKES_DEMO_SPEED:-12}"
interval="${OPENHIKES_DEMO_INTERVAL:-1}"
point_limit="${OPENHIKES_DEMO_POINTS:-60}"
dry_run=false

usage() {
    cat <<'EOF'
Usage: Scripts/simulate-hike.sh [start|stop] [options]

Starts or stops a simulated hiking route on an iOS Simulator.

Options:
  --device <udid|booted>  Simulator destination (default: booted)
  --route <file.gpx>      GPX track to replay
  --speed <meters/sec>    Playback speed (default: 12)
  --interval <seconds>    Location update interval (default: 1)
  --points <count>        Replay only the first points (default: 60)
  --full                  Replay the complete GPX track
  --dry-run               Validate and summarize without changing location
  -h, --help              Show this help

Examples:
  Scripts/simulate-hike.sh start
  Scripts/simulate-hike.sh start --full --speed 4
  Scripts/simulate-hike.sh stop
EOF
}

require_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        echo "Missing value for $option." >&2
        usage >&2
        exit 2
    fi
}

if [[ $# -gt 0 && "$1" != --* && "$1" != "-h" ]]; then
    action="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            require_value "$1" "${2:-}"
            device="$2"
            shift 2
            ;;
        --route)
            require_value "$1" "${2:-}"
            route="$2"
            shift 2
            ;;
        --speed)
            require_value "$1" "${2:-}"
            speed="$2"
            shift 2
            ;;
        --interval)
            require_value "$1" "${2:-}"
            interval="$2"
            shift 2
            ;;
        --points)
            require_value "$1" "${2:-}"
            point_limit="$2"
            shift 2
            ;;
        --full)
            point_limit=0
            shift
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$action" in
    start|stop)
        ;;
    *)
        echo "Unknown action: $action" >&2
        usage >&2
        exit 2
        ;;
esac

command -v xcrun >/dev/null 2>&1 || {
    echo "xcrun is required. Install Xcode command-line tools first." >&2
    exit 1
}

if [[ "$action" == "stop" ]]; then
    if [[ "$dry_run" == true ]]; then
        echo "Would clear simulated location on $device."
        exit 0
    fi
    xcrun simctl location "$device" clear
    echo "Cleared simulated location on $device."
    exit 0
fi

command -v xmllint >/dev/null 2>&1 || {
    echo "xmllint is required to read GPX tracks." >&2
    exit 1
}

if [[ ! -f "$route" ]]; then
    echo "GPX route not found: $route" >&2
    exit 1
fi
# The zero test has to be numeric: a textual `== "0"` lets "0.0" and "00"
# through, and both divide by zero when the playback loop derives its step.
is_positive() {
    awk -v value="$1" 'BEGIN { exit !(value > 0) }'
}
if [[ ! "$speed" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! is_positive "$speed"; then
    echo "--speed must be a positive number." >&2
    exit 2
fi
if [[ ! "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! is_positive "$interval"; then
    echo "--interval must be a positive number." >&2
    exit 2
fi
if [[ ! "$point_limit" =~ ^[0-9]+$ ]]; then
    echo "--points must be an integer." >&2
    exit 2
fi
if (( point_limit == 1 )); then
    echo "--points must be 0 for the full route or at least 2." >&2
    exit 2
fi

waypoints="$(
    xmllint --format "$route" 2>/dev/null \
        | sed -nE 's/^[[:space:]]*<trkpt lat="([^"]+)" lon="([^"]+)".*/\1,\2/p' \
        | if (( point_limit > 0 )); then
            sed -n "1,${point_limit}p"
        else
            cat
        fi
)"

waypoint_count="$(printf '%s\n' "$waypoints" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
if (( waypoint_count < 2 )); then
    echo "The GPX route must contain at least two track points." >&2
    exit 1
fi

first_waypoint="$(printf '%s\n' "$waypoints" | head -1)"
last_waypoint="$(printf '%s\n' "$waypoints" | tail -1)"
echo "Route: $route"
echo "Simulator: $device"
echo "Waypoints: $waypoint_count ($first_waypoint -> $last_waypoint)"
echo "Playback: ${speed} m/s, updates every ${interval} s"

if [[ "$dry_run" == true ]]; then
    exit 0
fi

printf '%s\n' "$waypoints" \
    | xcrun simctl location "$device" start \
        "--speed=$speed" "--interval=$interval" -

echo "Location playback started. Run '$0 stop --device $device' to clear it."
