#!/usr/bin/env bash
#
# A watch map is ready only when its loaded pixels, camera and status bar stay
# unchanged for the same settling interval as the text frames. Compile once;
# invoking the Swift interpreter on every poll consumes the readiness deadline.

prepare_watch_map_checker() {
    mkdir -p "$derived_data"
    map_checker="$derived_data/watch-map-readiness"
    swiftc -O -o "$map_checker" "$repository_root/Scripts/lib/watch-map-readiness.swift"
}

wait_for_map() {
    local shot="$derived_data/watch-map-readiness.png" deadline=$((SECONDS + 10#$map_settle_seconds))
    local status signature previous="" stable_since=$SECONDS
    while true; do
        xcrun simctl io "$udid" screenshot "$shot" >/dev/null 2>&1 || return 1
        status=0
        signature="$("$map_checker" "$shot")" || status=$?
        if (( status == 0 )); then
            if [[ "$signature" != "$previous" ]]; then
                stable_since=$SECONDS
            elif (( SECONDS - stable_since >= 10#$settle_seconds )); then
                return 0
            fi
            previous="$signature"
        else
            previous=""
        fi
        if (( status > 1 || SECONDS >= deadline )); then
            echo "Watch map did not finish rendering and settling; last frame: $shot" >&2
            return 1
        fi
        sleep 2
    done
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
    local entry rest
    if [[ "$just_paired" == true ]]; then
        echo "Waiting out the pairing sync (once, on a first run)…"
        sleep "$sync_wait_seconds"
    fi
    for entry in "${frames[@]}"; do
        rest="${entry#*|}"
        case "${rest%%|*}" in
            map)
                echo "Warming the map…"
                xcrun simctl terminate "$udid" "$app_bundle_id" 2>/dev/null || true
                launch_frame "${entry#*|*|}"
                wait_for_map
                xcrun simctl terminate "$udid" "$app_bundle_id" 2>/dev/null || true
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
        shot="$output_dir/$name.png"
        if [[ "$settle" == map ]]; then
            wait_for_map
            cp "$derived_data/watch-map-readiness.png" "$shot"
        else
            sleep "$settle"
            xcrun simctl io "$udid" screenshot "$shot" >/dev/null 2>&1
        fi
        printf '  %s\n' "$(basename "$shot")"
    done
    xcrun simctl terminate "$udid" "$app_bundle_id" 2>/dev/null || true
}
