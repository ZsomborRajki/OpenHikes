#!/usr/bin/env bash
#
# trail-cells.sh — file OpenStreetMap's waymarked day hikes into the squares the
# Community tab's search reads, and put them in the public database.
#
# The search used to be a question for Overpass, and the answer was a wait in a
# public server's queue. So the answer is built ahead of time, here: every
# hiking route in an OpenStreetMap extract, filed by quarter-degree square, one
# small file a square, which `upload` saves as one record a square in the
# container's public database. The app then fetches the few squares a search
# needs by name. `OpenHikes/Community/Curated/Cells/TrailCellGrid.swift` argues
# the design and has the measurements; *The trail squares* in AGENTS.md is the
# procedure.
#
# It is a *development* tool and is in no gate, though its parts are:
# Scripts/run-script-tests.sh builds the tool and runs it against fixtures.
#
# `build` needs osmium (`brew install osmium-tool`), which does the two things
# that are hard: finding the hiking relations in a planet file, and putting
# every node's position on the ways that use it. What it hands on is read by a
# small Swift tool compiled from Scripts/lib/trail-cells and from the app's own
# description of a square, so what is written here and what the app reads are
# one source.
#
# Usage:
#   Scripts/trail-cells.sh build <extract.osm.pbf> [--out <dir>] [--world] [--keep-work]
#   Scripts/trail-cells.sh upload <dir> --environment development|production
#                                 [--dry-run] [--yes] [--replace-world]
#   Scripts/trail-cells.sh whoami --environment development|production
#   Scripts/trail-cells.sh inspect <file.cell> [--json]
#   Scripts/trail-cells.sh cell <latitude> <longitude>
#
#   build     File an extract's routes into <dir> (default .build/trail-cells/squares).
#             Pass --world for the whole planet and for nothing else: it is what
#             lets the app read a square with no file as a place with no trails.
#             Its working files go in <dir>.work and are deleted afterwards
#             unless --keep-work. They are small beside the extract: Hungary's
#             were 50 MB, for one in seventy-five of the world's hiking relations.
#   upload    Make the public database hold what <dir> does: send the squares
#             that changed, delete the ones that are gone, then say what the
#             squares cover. --dry-run reads and plans, and changes nothing.
#   whoami    Print the account the server-to-server key acts as.
#   inspect   Print what a square's file holds.
#   cell      Print the record name of the square a point is in.
#
# Environment:
#   OPENHIKES_CLOUDKIT_KEY_ID    The server-to-server key's id, from the CloudKit
#                                Console. Or pass --key-id.
#   OPENHIKES_CLOUDKIT_KEY_FILE  Its private half, a PEM file kept outside the
#                                repository. Or pass --key-file.
#   Each environment has keys of its own in the Console. Add _DEVELOPMENT or
#   _PRODUCTION to either name for a key that is only that environment's; it
#   is read before the plain name.
#   OPENHIKES_TRAIL_CELLS_BUILD  Where the tool is compiled to
#                                (default .build/trail-cells).
#
# Exit status:
#   0  done
#   1  it could not be done
#   2  the command line was not understood

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${OPENHIKES_TRAIL_CELLS_BUILD:-$repository_root/.build/trail-cells}"
tool="$build_dir/trail-cells"

usage() {
    sed -n '/^# Usage:/,/^# Exit status:/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
    echo "error: $1" >&2
    exit 1
}

usage_error() {
    echo "error: $1" >&2
    echo >&2
    usage >&2
    exit 2
}

# The tool's own sources, and the three files of the app it is compiled with:
# the grid, the file format and the record names. They are the app's, compiled
# here as they stand, which is why each of them imports nothing of the app's.
tool_sources() {
    printf '%s\n' "$repository_root"/Scripts/lib/trail-cells/*.swift \
        "$repository_root/OpenHikes/Community/Curated/Cells/TrailCellGrid.swift" \
        "$repository_root/OpenHikes/Community/Curated/Cells/TrailCellFile.swift" \
        "$repository_root/OpenHikes/Community/Transport/CommunitySchema.swift"
}

# Compiles the tool when it is missing or older than one of its sources.
# Compiled rather than interpreted because a planet's ways are gigabytes of
# text, read a byte at a time.
prepare_tool() {
    local sources=() source stale=false
    while IFS= read -r source; do
        sources+=("$source")
        [[ -f "$source" ]] || die "missing $source"
        if [[ ! -x "$tool" || "$source" -nt "$tool" ]]; then
            stale=true
        fi
    done < <(tool_sources)
    [[ "$stale" == true ]] || return 0
    mkdir -p "$build_dir"
    swiftc -O -swift-version 6 -warnings-as-errors -o "$tool" "${sources[@]}" \
        || die "the trail-cells tool did not compile."
}

# The container the app itself names, read out of the app rather than spelled
# a second time here.
container_identifier() {
    local source="$repository_root/OpenHikes/Sync/CloudSyncCoordinator.swift" identifier
    identifier="$(sed -n 's/.*static let containerIdentifier = "\(.*\)".*/\1/p' "$source" | head -n 1)"
    [[ -n "$identifier" ]] || die "could not read the container identifier out of $source."
    printf '%s\n' "$identifier"
}

build() {
    local extract="" out="$build_dir/squares" world=false keep_work=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out)
                [[ $# -ge 2 ]] || usage_error "missing value for --out."
                out="$2"
                shift 2
                ;;
            --world)
                world=true
                shift
                ;;
            --keep-work)
                keep_work=true
                shift
                ;;
            -*)
                usage_error "unknown option '$1'."
                ;;
            *)
                [[ -z "$extract" ]] || usage_error "unexpected argument '$1'."
                extract="$1"
                shift
                ;;
        esac
    done
    [[ -n "$extract" ]] || usage_error "build needs an OpenStreetMap extract."
    [[ -f "$extract" ]] || die "there is no file at $extract."
    command -v osmium >/dev/null 2>&1 \
        || die "osmium is not installed. It reads the extract: brew install osmium-tool"

    prepare_tool
    local work="$out.work"
    mkdir -p "$work"

    echo "Finding the hiking relations in $extract …"
    osmium tags-filter "$extract" r/route=hiking -o "$work/hiking.osm.pbf" --overwrite
    # Every node's position, put on the ways that use it, which is what lets
    # the next step read a way without a table of the planet's nodes. A way
    # that runs out of a regional extract keeps its place with no positions,
    # and the tool leaves its relation out.
    echo "Putting positions on their ways …"
    osmium add-locations-to-ways "$work/hiking.osm.pbf" --ignore-missing-nodes \
        -o "$work/located.osm.pbf" --overwrite
    # Relations and ways apart, because a relation says which ways are wanted
    # and comes after them in the file. `locations_on_ways` is what writes the
    # positions out: without it every way reads as having none.
    osmium cat "$work/located.osm.pbf" -t relation -f opl,add_metadata=false \
        -o "$work/relations.opl" --overwrite
    osmium cat "$work/located.osm.pbf" -t way -f opl,add_metadata=false,locations_on_ways=true \
        -o "$work/ways.opl" --overwrite

    # When the data was current, off the extract's own header. A planet file
    # and a Geofabrik extract both say; a file that does not is built without.
    local timestamp
    timestamp="$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$extract" 2>/dev/null || true)"
    if [[ -z "$timestamp" ]]; then
        timestamp="$(osmium fileinfo -g header.option.timestamp "$extract" 2>/dev/null || true)"
    fi

    local arguments=(build --relations "$work/relations.opl" --ways "$work/ways.opl" --out "$out")
    [[ "$world" == false ]] || arguments+=(--world)
    [[ -z "$timestamp" ]] || arguments+=(--osm-timestamp "$timestamp")
    echo "Filing the routes …"
    "$tool" "${arguments[@]}"

    if [[ "$keep_work" == false ]]; then
        rm -rf "$work"
    fi
    echo "Wrote $out"
}

# `upload` and `whoami`: the tool's own options, with the container and the key
# filled in from where this machine keeps them.
with_database() {
    local command="$1" has_key_id=false has_key_file=false argument environment="" previous=""
    shift
    for argument in "$@"; do
        case "$argument" in
            --key-id) has_key_id=true ;;
            --key-file) has_key_file=true ;;
            --container) usage_error "the container is the app's own; it is not an option." ;;
        esac
        [[ "$previous" != --environment ]] || environment="$argument"
        previous="$argument"
    done
    # A key belongs to one environment, so each may have its own:
    # OPENHIKES_CLOUDKIT_KEY_ID_PRODUCTION is read before the plain name when
    # the upload is to production, and likewise for the file and development.
    local suffix key_id key_file id_name="OPENHIKES_CLOUDKIT_KEY_ID" file_name="OPENHIKES_CLOUDKIT_KEY_FILE"
    suffix="$(printf '%s' "$environment" | tr '[:lower:]' '[:upper:]')"
    key_id="${OPENHIKES_CLOUDKIT_KEY_ID:-}"
    key_file="${OPENHIKES_CLOUDKIT_KEY_FILE:-}"
    if [[ "$suffix" == DEVELOPMENT || "$suffix" == PRODUCTION ]]; then
        id_name="OPENHIKES_CLOUDKIT_KEY_ID_$suffix"
        file_name="OPENHIKES_CLOUDKIT_KEY_FILE_$suffix"
        key_id="${!id_name:-$key_id}"
        key_file="${!file_name:-$key_file}"
    fi
    local arguments=("$command" "$@" --container "$(container_identifier)")
    # A plan against a saved state sends nothing, so it needs no key.
    if [[ " $* " != *" --against "* ]]; then
        if [[ "$has_key_id" == false ]]; then
            [[ -n "$key_id" ]] \
                || usage_error "name the server-to-server key: --key-id, $id_name or OPENHIKES_CLOUDKIT_KEY_ID."
            arguments+=(--key-id "$key_id")
        fi
        if [[ "$has_key_file" == false ]]; then
            [[ -n "$key_file" ]] \
                || usage_error "name the key's PEM file: --key-file, $file_name or OPENHIKES_CLOUDKIT_KEY_FILE."
            arguments+=(--key-file "$key_file")
        fi
    fi
    prepare_tool
    "$tool" "${arguments[@]}"
}

[[ $# -gt 0 ]] || usage_error "no command given."
command="$1"
shift

case "$command" in
    build)
        build "$@"
        ;;
    upload|whoami)
        with_database "$command" "$@"
        ;;
    inspect|cell|sign)
        prepare_tool
        "$tool" "$command" "$@"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage_error "unknown command '$command'."
        ;;
esac
