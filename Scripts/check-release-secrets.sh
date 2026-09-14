#!/usr/bin/env bash
#
# Decides whether this tree is fit to archive, as far as bundled keys go.
#
# `OpenHikes/Secrets.plist` is gitignored, is the only place the Stadia and
# Thunderforest keys live, and exists on exactly one laptop. A Release archive
# cut without it builds, signs, uploads and passes CI's archive job, and ships
# an app whose two paid map styles cannot draw a tile: `Secrets.canLoadTiles`
# is false for both paid sources, so both provider rows are drawn at
# `disabledOpacity` and refuse the tap.
#
# Not a CI check, and it must not become one. The `archive` job builds without
# keys deliberately, and its *Verify what the archive does and does not carry*
# step is the right place for everything it can assert; a missing
# `Secrets.plist` is the one thing it cannot, because in that job it is
# correct. Not a Run Script build phase either: conditioning one on
# `$(CONFIGURATION)` == Release would fail the Release *simulator* build the
# `builds` job runs on every pull request.
#
# So it is a thing a person runs before pressing Archive, and it is named in
# *Build and test* beside the tag convention for the same reason — the archive
# checklist was one step long and this is the second.
#
# The placeholder case is the likelier mistake than the missing file: copying
# `Secrets.example.plist` into place and not filling it in leaves a file that
# parses, resolves to nothing, and reads exactly like a working one.
#
# Exit status:
#   0  every key-gated provider has a real key
#   1  the file is missing, unreadable, or a key is absent, empty or a placeholder

set -euo pipefail

# The keys `TileProvider.apiKeyPlistKey` names, and the source each one is for.
# Kept here rather than read out of the Swift, because this program has to run
# against a tree it cannot compile and a name it could not resolve would make
# it pass rather than fail.
required_keys=(
    "StadiaAPIKey	Stadia Outdoors"
    "ThunderforestAPIKey	Thunderforest Outdoors"
)

# `Secrets.values` drops anything starting with this, so a placeholder is
# indistinguishable from a missing key at runtime — and silently so.
placeholder_prefix="YOUR_"

default_plist="OpenHikes/Secrets.plist"

usage() {
    cat <<EOF
Usage: Scripts/check-release-secrets.sh [--plist <file>]

Checks that every key-gated map provider has a real key before an archive.

Options:
  --plist <file>  The bundled secrets file to check (default: $default_plist)
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

if [[ ! -f "$plist" ]]; then
    {
        echo "error: $plist does not exist."
        echo "  Copy Secrets.example.plist to $plist and fill in both keys."
        echo "  It is gitignored, so a fresh clone never has one."
    } >&2
    exit 1
fi

# Read through JSON rather than key by key: it settles "is the root even a
# dictionary" and "is this value a string" in the same pass, and an unreadable
# file fails here rather than looking like an absent key.
if ! json="$(plutil -convert json -o - "$plist" 2>&1)"; then
    echo "error: $plist could not be read: $json" >&2
    exit 1
fi

if [[ "$(jq -r 'type' <<< "$json")" != "object" ]]; then
    echo "error: $plist is not a dictionary at its root." >&2
    exit 1
fi

# Every required key this build would resolve to nothing, and why. The three
# cases are separated because they are three different mistakes: a key that was
# never added, one whose value was emptied, and the template copied and not
# filled in. `Secrets.values` treats all three the same, which is exactly what
# makes them hard to notice.
problems=()
for entry in "${required_keys[@]}"; do
    IFS=$'\t' read -r key provider <<< "$entry"
    state="$(
        jq -r --arg key "$key" --arg placeholder "$placeholder_prefix" '
            if has($key) | not then "missing"
            elif (.[$key] | type) != "string" or .[$key] == "" then "empty"
            elif (.[$key] | startswith($placeholder)) then "placeholder"
            else "ok"
            end
        ' <<< "$json"
    )"
    case "$state" in
        missing)
            problems+=("$key is missing ($provider cannot load tiles)")
            ;;
        empty)
            problems+=("$key is empty ($provider cannot load tiles)")
            ;;
        placeholder)
            problems+=("$key is still the template placeholder ($provider cannot load tiles)")
            ;;
    esac
done

if (( ${#problems[@]} > 0 )); then
    {
        echo "error: $plist would not unlock the paid map styles:"
        for problem in "${problems[@]}"; do
            echo "  - $problem"
        done
    } >&2
    exit 1
fi

echo "$plist: ${#required_keys[@]} keys resolve. Safe to archive."
