#!/bin/bash
#
# Brings the four String Catalogs up to date with the strings the last build
# extracted from the source.
#
# The targets build with SWIFT_EMIT_LOC_STRINGS = YES, so every compile writes
# a `.stringsdata` file per source file listing the localizable literals it
# found: SwiftUI `Text("…")`, `Button("…")`, `String(localized:)` and the
# rest. Xcode's IDE folds those into the catalogs on its own builds; an
# `xcodebuild` build does not, which is why this exists — a new string added
# from the command line otherwise never reaches the catalog, and a translator
# never sees it. Strings that left the source are marked stale rather than
# deleted, which is what the IDE does too.
#
# Each catalog is then put in the IDE's key order by
# Scripts/lib/sort-string-catalogs.swift. `xcstringstool` writes keys in byte
# order and the IDE case-insensitively, so without it every build in Xcode
# re-sorted the app's catalog into a diff that meant nothing, and the next run
# of this sorted it straight back.
#
# Build first (any build of the OpenHikes scheme compiles all four targets),
# then point this at the same derived data:
#
#   Scripts/sync-string-catalogs.sh ~/Library/Developer/Xcode/DerivedData/OpenHikes-…
#
# `--check` syncs copies instead and fails if any catalog would change:
# a string in the source that no catalog carries yet, or one the catalog
# still carries that the source has dropped. That is the only way to ask
# whether the catalogs are complete — an English key is not compiled into the
# bundle at all, so no run-time lookup can tell (see StringCatalogTests).
#
# Exit status:
#   0  every catalog synced, or with --check, every catalog already current
#   1  no derived data, or a target with nothing extracted in it
#   2  with --check, a catalog that is out of date
#
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
    cat <<'USAGE'
Usage: Scripts/sync-string-catalogs.sh [--check] <derived-data-path>

Syncs the Localizable.xcstrings in OpenHikes/, OpenWidget/, OpenHikesWatch/ and
OpenHikesWatchWidgets/ with the .stringsdata the last build of those targets
wrote under <derived-data-path>.

Options:
  --check         Change nothing; exit 2 if any catalog is out of date
  -h, --help      Show this help
USAGE
}

check=false
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ "${1:-}" == "--check" ]]; then
    check=true
    shift
fi
if [[ $# -ne 1 ]]; then
    usage
    exit 1
fi

intermediates="$1/Build/Intermediates.noindex"
if [[ ! -d "$intermediates" ]]; then
    echo "error: no build under $1 — build the OpenHikes scheme into it first" >&2
    exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Catalog folder, then the target whose compile extracts its strings.
for pair in OpenHikes:OpenHikes OpenWidget:OpenWidgetExtension OpenHikesWatch:OpenHikesWatch \
    OpenHikesWatchWidgets:OpenHikesWatchWidgets; do
    folder="${pair%%:*}"
    target="${pair##*:}"
    args=()
    while IFS= read -r file; do
        args+=(--stringsdata "$file")
    # The project's own folder is OpenHikes.build too, and every target's
    # intermediates sit inside it, so the target's folder is matched one
    # level below the configuration folder rather than anywhere in the path.
    done < <(find "$intermediates" -path "*/OpenHikes.build/*/$target.build/*" -name '*.stringsdata')
    if [[ ${#args[@]} -eq 0 ]]; then
        echo "error: $target has no extracted strings under $1 — was it built?" >&2
        exit 1
    fi
    catalog="$folder/Localizable.xcstrings"
    if $check; then
        # A folder per catalog, because the file name is the table the sync
        # takes strings from, so the copy has to keep it.
        mkdir "$scratch/$folder"
        copy="$scratch/$folder/Localizable.xcstrings"
        cp "$catalog" "$copy"
        xcrun xcstringstool sync "$copy" "${args[@]}"
        swift Scripts/lib/sort-string-catalogs.swift "$copy"
        if ! cmp -s "$catalog" "$copy"; then
            echo "error: $catalog is out of date — run Scripts/sync-string-catalogs.sh $1" >&2
            outdated=true
        else
            echo "  current $catalog"
        fi
    else
        xcrun xcstringstool sync "$catalog" "${args[@]}"
        swift Scripts/lib/sort-string-catalogs.swift "$catalog"
        echo "  synced  $catalog ($(( ${#args[@]} / 2 )) source files)"
    fi
done

if [[ "${outdated:-false}" == true ]]; then
    exit 2
fi
