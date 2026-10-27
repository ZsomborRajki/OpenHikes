#!/usr/bin/env bash
#
# Raw captures share one output root. A new run empties it; --append keeps
# other device/language sets while replacing this capture's directory. Both
# phone appearances and the watch use the same naming and cleanup rules.

screenshot_output_directory() {
    local root="$1" device="$2" locale="$3" layout="$4" appearance="$5" append="$6" checkout
    if [[ -L "$root" ]]; then
        echo "The screenshot output must be a directory, not a symbolic link: $root" >&2
        return 2
    fi
    mkdir -p "$root" || return 2
    root="$(cd "$root" && pwd -P)" || return 2
    checkout="$(cd "$repository_root" && pwd -P)" || return 2
    # --output is a capture destination, never permission to empty the
    # checkout, a parent of it, or its source and input directories.
    if [[ "$checkout/" == "$root/"* || "$root" == "${HOME:-/}" ]]; then
        echo "Refusing to clean a home, checkout, or parent directory: $root" >&2
        return 2
    fi
    if [[ "$root" == "$checkout/"* ]]; then
        case "${root#"$checkout/"}" in
            Screenshots/Output|Screenshots/Output/*|Screenshots/Output-*|Screenshots/WatchOutput|Screenshots/WatchOutput/*|Screenshots/WatchOutput-*) ;;
            *) echo "Choose a screenshot output directory under Screenshots/Output: $root" >&2; return 2 ;;
        esac
    fi
    local name
    name="$(printf '%s' "${device}${layout:+_$layout}_${locale}_$(date -u +%F)" \
        | LC_ALL=C tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/_$//')"
    if [[ "$append" == false ]]; then
        find "$root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || return 1
    fi
    local directory="$root/$name${appearance:+/$appearance}"
    if [[ -L "$root/$name" || -L "$directory" ]]; then
        echo "The screenshot result must not be a symbolic link: $directory" >&2
        return 2
    fi
    mkdir -p "$directory" || return 1
    find "$directory" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || return 1
    printf '%s\n' "$directory"
}
