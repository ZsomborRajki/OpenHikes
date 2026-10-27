#!/usr/bin/env bash
#
# Raw captures share one output root. Only marked capture sets belong to us:
# an arbitrary --output may also hold the hiker's photographs. Resolve paths
# before preparation, but remove old frames only after build and install.

screenshot_output_directory() {
    local root="$1" device="$2" locale="$3" layout="$4" appearance="$5" checkout
    if [[ -L "$root" ]]; then
        echo "The screenshot output must be a directory, not a symbolic link: $root" >&2
        return 2
    fi
    mkdir -p "$root" || return 2
    root="$(cd "$root" && pwd -P)" || return 2
    # macOS preserves a leading // in pwd; it still addresses filesystem root.
    while [[ "$root" == //* ]]; do root="${root#/}"; done
    checkout="$(cd "$repository_root" && pwd -P)" || return 2
    # --output is a capture destination, never permission to empty the
    # checkout, a parent of it, or its source and input directories.
    if [[ "$root" == / || "$checkout/" == "$root/"* || "$root" == "${HOME:-/}" ]]; then
        echo "Refusing to clean a home, checkout, or parent directory: $root" >&2
        return 2
    fi
    if [[ "$root" == "$checkout/"* ]]; then
        case "${root#"$checkout/"}" in
            Screenshots/Output|Screenshots/Output/*|Screenshots/Output-*|Screenshots/WatchOutput|Screenshots/WatchOutput/*|Screenshots/WatchOutput-*) ;;
            *) echo "Choose a screenshot output directory under Screenshots/Output: $root" >&2; return 2 ;;
        esac
    fi
    local name capture_date="${OPENHIKES_SCREENSHOT_DATE:-$(date -u +%F)}"
    if [[ ! "$capture_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "OPENHIKES_SCREENSHOT_DATE must be YYYY-MM-DD." >&2
        return 2
    fi
    name="$(printf '%s' "${device}${layout:+_$layout}_${locale}_${capture_date}" \
        | LC_ALL=C tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/_$//')"
    local directory="$root/$name${appearance:+/$appearance}"
    if [[ -L "$root/$name" || -L "$directory" ]]; then
        echo "The screenshot result must not be a symbolic link: $directory" >&2
        return 2
    fi
    printf '%s\n' "$directory"
}

# --clean is explicit and restricted to sets carrying our ownership marker.
# A targeted re-shoot replaces only its requested frame numbers. Neither path
# ever empties an unmarked directory or follows a result-directory symlink.
screenshot_prepare_output() {
    local root="$1" directory="$2" clean="$3" set candidate frame shot
    shift 3
    root="$(cd "$root" && pwd -P)" || return 2
    while [[ "$root" == //* ]]; do root="${root#/}"; done
    set="$directory"
    case "${directory##*/}" in light|dark) set="${directory%/*}" ;; esac
    if [[ "$set" != "$root/"* || "${set#"$root/"}" == */* || -L "$set" || -L "$directory" \
        || -L "$set/.openhikes-screenshot-set" ]]; then
        echo "Refusing an unsafe screenshot result directory: $directory" >&2
        return 2
    fi
    if [[ "$clean" == true ]]; then
        for candidate in "$root"/*; do
            if [[ -d "$candidate" && ! -L "$candidate" \
                && -f "$candidate/.openhikes-screenshot-set" && ! -L "$candidate/.openhikes-screenshot-set" ]]; then
                rm -rf -- "$candidate" || return 1
            fi
        done
    fi
    mkdir -p "$directory" || return 1
    touch "$set/.openhikes-screenshot-set" || return 1
    for frame in "$@"; do
        for shot in "$directory/$frame"-*.png; do
            [[ -f "$shot" || -L "$shot" ]] || continue
            rm -f -- "$shot" || return 1
        done
    done
}
