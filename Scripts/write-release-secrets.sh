#!/usr/bin/env bash
#
# Writes the map keys a release bundles into `OpenHikes/Secrets.plist`, from
# the environment rather than from a file only one laptop has.
#
# The TestFlight workflow archives on a runner that has never seen that file,
# so it hands the keys over as secrets of the `testflight` environment, and
# this turns the two variables into the file `Secrets.swift` reads. It writes
# and nothing more. Scripts/check-release-secrets.sh decides whether what it
# wrote unlocks anything, so the two cannot disagree about which keys a
# release needs: a key this program stopped writing is one that check names
# as missing.
#
# Surrounding whitespace is stripped. A secret pasted from a terminal, or
# piped in from a file, can carry a newline, and a key with one in it is
# bundled, resolves, and is sent in every tile URL, where the provider refuses
# it. That is the silent failure the check exists for, one character from
# where it can see it.
#
# An existing file is never overwritten, because on a laptop it is the only
# copy of the keys.
#
# Environment:
#   STADIA_API_KEY         the Stadia Maps key (Stadia Outdoors, Stamen Terrain)
#   THUNDERFOREST_API_KEY  the Thunderforest key (Thunderforest Outdoors)
#
# Exit status:
#   0  the file was written
#   1  the file already exists, or a variable is unset or blank
#   2  a usage error

set -euo pipefail

# The plist key each variable fills.
keys=(
    "StadiaAPIKey	STADIA_API_KEY"
    "ThunderforestAPIKey	THUNDERFOREST_API_KEY"
)

default_plist="OpenHikes/Secrets.plist"

usage() {
    cat <<EOF
Usage: Scripts/write-release-secrets.sh [--plist <file>]

Writes STADIA_API_KEY and THUNDERFOREST_API_KEY into the bundled secrets file.

Options:
  --plist <file>  The file to write (default: $default_plist); it must not exist
  -h, --help      Show this help
EOF
}

plist="$default_plist"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --plist)
            if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
                echo "error: missing value for --plist." >&2
                exit 2
            fi
            plist="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option '$1'." >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -e "$plist" ]]; then
    echo "error: $plist already exists, and this never overwrites it." >&2
    exit 1
fi

# Every variable is read before anything is written, and every blank one is
# named at once, so a person setting secrets learns about both in one run.
values=()
missing=()
for entry in "${keys[@]}"; do
    IFS=$'\t' read -r key variable <<< "$entry"
    value="${!variable:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ -z "$value" ]]; then
        missing+=("$variable")
    fi
    values+=("$key" "$value")
done

if (( ${#missing[@]} > 0 )); then
    {
        echo "error: no value for ${missing[*]}."
        echo "  The TestFlight workflow reads each from a secret of the same name"
        echo "  in the repository's testflight environment."
    } >&2
    exit 1
fi

# Built aside and moved into place, so an interrupted run leaves no file with
# one key in it, which the next run would refuse to replace.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
plutil -create xml1 "$scratch/Secrets.plist"
for (( index = 0; index < ${#values[@]}; index += 2 )); do
    plutil -insert "${values[index]}" -string "${values[index + 1]}" "$scratch/Secrets.plist"
done
mv "$scratch/Secrets.plist" "$plist"

echo "$plist: wrote ${#keys[@]} keys."
