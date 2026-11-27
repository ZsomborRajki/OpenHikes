#!/usr/bin/env bash
#
# trail-cells.sh — file OpenStreetMap's waymarked day hikes into the squares the
# Community tab's search reads, and the hiking-routes layer's squares and the
# places a place search offers likewise; pack each set into one archive and put
# it in the tile server's bucket. And build the graph a recording is matched
# against and the trail maker routes over, trails and the roads that join
# them, which goes to the same bucket as an archive of its own. The squares,
# with the trail graph's own squares, are also in the public database for the
# builds of the app that read them there, 1.5 to 1.7: `upload` keeps those
# copies, and `prune` takes them away once those builds are gone.
#
# The search used to be a question for Overpass, and the answer was a wait in a
# public server's queue. So the answer is built ahead of time, here: every
# hiking route in an OpenStreetMap extract, filed by quarter-degree square, one
# small file a square, which `pack` puts in one PMTiles archive, a square a
# tile. The app then fetches the few squares a search needs from the tile
# server by name. `OpenHikes/Community/Curated/Cells/TrailCellGrid.swift` argues
# the design and has the measurements, and
# `OpenHikes/Tiles/Squares/SquareArchive.swift` says where a square goes in an
# archive; *Building the squares* in OPERATIONS.md is the procedure.
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
# The planet is downloaded once and never again. A planet file is 90 GB from
# servers OpenStreetMap's volunteers run, and they asked that a copy be kept
# current with the changes they publish rather than downloaded anew for each
# refresh. `update-planet` does that with pyosmium-up-to-date, which pyosmium
# installs (`brew install pipx && pipx install osmium`; Homebrew has no
# formula for it).
#
# Usage:
#   Scripts/trail-cells.sh update-planet <planet.osm.pbf> [--size <MB>]
#   Scripts/trail-cells.sh build <extract.osm.pbf> [--out <dir>] [--world] [--keep-work]
#   Scripts/trail-cells.sh build-routes <extract.osm.pbf> [--out <dir>] [--world] [--keep-work]
#   Scripts/trail-cells.sh build-places <extract.osm.pbf> [--out <dir>] [--world] [--keep-work]
#   Scripts/trail-cells.sh build-graph <extract.osm.pbf> [--out <dir>] [--world] [--keep-work]
#   Scripts/trail-cells.sh build-routing <extract.osm.pbf> [--out <dir>] [--world] [--keep-work]
#   Scripts/trail-cells.sh pack <dir> [--out <dir>] [--name <archive>]
#   Scripts/trail-cells.sh build-elevation [--out <dir>] [--area <s>,<w>,<n>,<e>] [--name <archive>]
#                                 [--source <url|dir>] [--coarser <url|dir>] [--jobs <n>]
#   Scripts/trail-cells.sh upload-archive <dir>
#   Scripts/trail-cells.sh upload-routing <dir>
#   Scripts/trail-cells.sh routing-tile <archive.pmtiles> <x> <y> [--json]
#   Scripts/trail-cells.sh archive-tile <archive.pmtiles> <square-name> [--json]
#   Scripts/trail-cells.sh copernicus-tile <file.tif> [--post <row>,<column>]...
#   Scripts/trail-cells.sh elevation-height <archive.pmtiles> <latitude> <longitude>
#   Scripts/trail-cells.sh upload <dir> --environment development|production
#                                 [--dry-run] [--yes] [--replace-world]
#   Scripts/trail-cells.sh prune trails|routes|places|graph
#                                 --environment development|production [--dry-run] [--yes]
#   Scripts/trail-cells.sh whoami --environment development|production
#   Scripts/trail-cells.sh inspect <file.cell> [--json]
#   Scripts/trail-cells.sh cell <latitude> <longitude>
#
#   update-planet
#             Bring a planet file up to the present, in place, with the hourly
#             changes openstreetmap.org publishes since the time in its header:
#             about half a gigabyte of them a day, against 90 GB for a new
#             planet. Get the first planet by torrent or from a mirror
#             (https://wiki.openstreetmap.org/wiki/Planet.osm), and keep it
#             under one name, such as planet.osm.pbf: after an update a date in
#             the name is wrong, and the builds read the date from the file.
#             Each pass writes a new copy beside the planet before it replaces
#             it, so there has to be room for one. --size caps the changes a
#             pass holds in memory, in MB (default 4096, about a week of
#             them); passes repeat until the planet is current. pyosmium
#             refuses a planet more than three months old, which is a new
#             download.
#   build     File an extract's routes into <dir> (default .build/trail-cells/squares).
#             Pass --world for the whole planet and for nothing else: it is what
#             lets the app answer from the squares at all, and read a square
#             with no file as a place with no trails.
#             Its working files go in <dir>.work and are deleted afterwards
#             unless --keep-work. They are small beside the extract: Hungary's
#             were 50 MB, for one in seventy-five of the world's hiking relations.
#             `pack` makes the archive the app reads out of what it wrote, and
#             `upload` puts the same squares in the public database.
#   build-routes
#             File every hiking route's ways into the hiking-routes layer's
#             squares in <dir> (default .build/trail-cells/routes), four levels
#             of them: see OpenHikes/Tiles/HikingRoutes/RouteSquareGrid.swift.
#             --world, --out and --keep-work as for build. `upload` sends any
#             kind of build; each has a manifest record of its own, and the
#             layer's build writes routes-manifest.json, never manifest.json.
#   build-places
#             File the summits, springs, huts and the rest a place search
#             offers into the places' squares in <dir> (default
#             .build/trail-cells/places): see
#             OpenHikes/Hikes/Places/Squares/PlaceSquareGrid.swift. --world,
#             --out and --keep-work as for build; it writes places-manifest.json.
#   build-graph
#             File every trail the trail graph matches a recording against into
#             its squares in <dir> (default .build/trail-cells/graph): see
#             OpenHikes/Recording/Squares/TrailGraphSquareGrid.swift. --world,
#             --out and --keep-work as for build; it writes graph-manifest.json.
#             Only the public database's copy is built from it, for the builds
#             that read it there: the app reads the trail graph out of the
#             trail maker's archive, and `pack` refuses this build.
#   build-routing
#             File every trail and every road that joins trails, the graph
#             the trail maker routes over, into one PMTiles archive in <dir>
#             (default .build/trail-cells/routing): a tile a region of the
#             graph, see OpenHikes/Recording/Squares/RoutingGraphArchive.swift.
#             It is named for the hour the extract is current to,
#             routing-YYYYMMDD-HH.pmtiles, and routing-build.json beside it says
#             what it is. --world, --out and --keep-work as for build. No index
#             of the positions of every such node in a planet fits in
#             memory, so osmium cuts the ways into bands of longitude, each
#             with every node of its ways, and puts the positions on one band
#             at a time, into a pipe the tool reads; a band is deleted once it
#             is read. Measured on an M4 Max with 48 GB and the planet of
#             2026-11-22: 53 minutes (8 to find the ways, 14 to cut the bands,
#             25 to read them and 6 to write the tiles), a cut of 20 GB, a
#             spool of some 43 GB and the archive, whose size
#             RoutingGraphArchive.swift gives: about 65 GB of disk at the
#             most. The build is written into <dir>.work and replaces an
#             earlier one in <dir> only once it is whole, so that one needs
#             room beside it until then.
#   pack      Pack what build, build-routes or build-places wrote in <dir>
#             into one PMTiles archive for the tile server, each square's file
#             as it is in the tile SquareArchive.swift gives it, into a
#             directory of its own (default <dir>.archive) with
#             archive-build.json beside it. It is named for the set and the
#             hour the extract is current to, trails-YYYYMMDD-HH (routes-…,
#             places-…), unless --name says otherwise. Only a build of the
#             whole world is packed: the app reads a square the archive does
#             not hold as ground with nothing on it. The archive is written
#             beside the output and read back, every tile held to its file,
#             before it replaces an earlier pack there.
#   build-elevation
#             File the Copernicus DEM's heights at 30 m into the elevation
#             squares, one PMTiles archive in <dir> (default
#             .build/trail-cells/elevation), named for the hour the build
#             began, elevation-YYYYMMDD-HH, with archive-build.json beside it:
#             see OpenHikes/Hikes/Elevation/ElevationSquareGrid.swift. It
#             reads every tile of the model's public bucket (--source, a
#             directory of its tiles for a test) and the names of the 90 m
#             model's (--coarser), for the land the 30 m one withholds; see
#             Scripts/lib/trail-cells/ElevationBuild.swift. --area limits it
#             to whole degrees, south,west,north,east. Only a build of both
#             buckets with no --area, each listing as long as the bucket is
#             known to be, is marked the whole world; upload-archive refuses
#             every other. --jobs reads that many tiles at once (16).
#             Measured on the world on 2026-11-26: 589 GB read in 2 h 47 min
#             with --jobs 24, about 60 MB/s, into an archive of 66.4 GB, which
#             upload-archive then sent in 248 parts.
#   upload-archive
#             Put the archive build-routing, pack or build-elevation wrote in <dir> in the R2
#             bucket openhikes-tiles under its own name, refusing one that is
#             not the whole world and a name the bucket already holds, as
#             Scripts/vector-extras.sh upload does. Then name it in the app's
#             manifest: Scripts/vector-archives.sh use <name>, then publish. It
#             signs with R2's S3 keys (Scripts/lib/r2.sh).
#   upload-routing
#             upload-archive, for a directory build-routing wrote.
#   upload    Make the public database hold what <dir> does: send the squares
#             that changed, delete the ones that are gone, then say what the
#             squares cover. --dry-run reads and plans, and changes nothing.
#             The app reads its squares from the tile server; these copies are
#             for the builds that read them in the public database.
#   prune     Take one set of squares out of the public database, once no
#             installed build reads it there: make its manifest say the
#             squares are not the whole world, so those builds ask Overpass,
#             delete every square the manifest lists, then the manifest, which
#             is the only list of them. Stopped part of the way, it carries on
#             from there when run again. --dry-run reads and plans, and changes
#             nothing; production needs --yes, as upload's does.
#   routing-tile
#             Print what a z12 tile of the trail maker's archive holds, read by
#             the archive's own directories as the tile server reads them.
#   archive-tile
#             Print what the square of that name holds, read out of an archive
#             of its set as the tile server reads it.
#   copernicus-tile
#             Print a Copernicus DEM tile's size, place and range, and the
#             heights at the posts asked for, as build-elevation reads them.
#   elevation-height
#             Print the height at a point, read out of an elevation archive's
#             squares as the app reads them, and which squares it read.
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
#   OPENHIKES_R2_ENV             upload-archive's R2 keys (default
#                                ~/.config/openhikes/r2-openhikes-tiles.env).
#
# Exit status:
#   0  done
#   1  it could not be done
#   2  the command line was not understood

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${OPENHIKES_TRAIL_CELLS_BUILD:-$repository_root/.build/trail-cells}"
tool="$build_dir/trail-cells"

# shellcheck source=lib/r2.sh
source "$repository_root/Scripts/lib/r2.sh"

# The edges of the bands of longitude build-routing puts positions on one at a
# time, west to east: osmium's index of a band's node positions is what has to
# fit in memory, sixteen bytes a node. Measured on the planet of 2026-11-22,
# the bands held 2.51 billion nodes, the largest, 25° to 60°, 395 million, some
# 6 GB of index; −100° to −30°, one band until then, held 538 million, past the
# 2²⁹ at which osmium's array doubles to 17 GB, and was cut at −85°.
routing_band_edges=(-180 -100 -85 -30 5 12 25 60 105 180)

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

# The tool's own sources, and the files of the app it is compiled with: each
# set's grid and file format, the byte format they share, and the record
# names. They are the app's, compiled here as they stand, which is why each of
# them imports nothing of the app's.
tool_sources() {
    printf '%s\n' "$repository_root"/Scripts/lib/trail-cells/*.swift \
        "$repository_root/OpenHikes/General/PackedBytes.swift" \
        "$repository_root/OpenHikes/Community/Curated/Cells/TrailCellGrid.swift" \
        "$repository_root/OpenHikes/Community/Curated/Cells/TrailCellFile.swift" \
        "$repository_root/OpenHikes/Tiles/HikingRoutes/RouteSquareGrid.swift" \
        "$repository_root/OpenHikes/Tiles/HikingRoutes/RouteSquareFile.swift" \
        "$repository_root/OpenHikes/Hikes/Places/Squares/PlaceSquareGrid.swift" \
        "$repository_root/OpenHikes/Hikes/Places/Squares/PlaceSquareFile.swift" \
        "$repository_root/OpenHikes/Recording/Squares/TrailGraphSquareGrid.swift" \
        "$repository_root/OpenHikes/Recording/Squares/TrailGraphSquareFile.swift" \
        "$repository_root/OpenHikes/Recording/Squares/RoutingGraphArchive.swift" \
        "$repository_root/OpenHikes/Tiles/Squares/SquareArchive.swift" \
        "$repository_root/OpenHikes/Hikes/Elevation/ElevationSquareGrid.swift" \
        "$repository_root/OpenHikes/Hikes/Elevation/ElevationSquareFile.swift" \
        "$repository_root/OpenHikes/Hikes/Elevation/ElevationCredit.swift" \
        "$repository_root/OpenHikes/Recording/TrailGraphHighway.swift" \
        "$repository_root/OpenHikes/Tiles/Countries/PMTilesFile.swift" \
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

# `build`, `build-routes`, `build-places` and `build-graph`: osmium's steps,
# then the tool's command of the same name, into a directory of its own by
# default. The two routes' builds share their steps; the places' and the trail
# graph's find other things, and the tool says what.
build() {
    local tool_command="$1" extract="" out="$build_dir/$2" world=false keep_work=false
    shift 2
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

    local found="$work/hiking.osm.pbf"
    if [[ "$tool_command" == build-places || "$tool_command" == build-graph ]]; then
        # The tool says what a place or a trail is, so the filter and the
        # build are one list: see PlaceSquareFile.kinds and
        # TrailGraphHighway.trails.
        local filters=() filter kind=places listing=place-filters
        if [[ "$tool_command" == build-graph ]]; then
            kind=graph
            listing=graph-filters
        fi
        while IFS= read -r filter; do
            filters+=("$filter")
        done < <("$tool" "$listing")
        [[ ${#filters[@]} -gt 0 ]] || die "the trail-cells tool named nothing to find."
        found="$work/$kind.osm.pbf"
        echo "Finding the $kind in $extract …"
        osmium tags-filter "$extract" "${filters[@]}" -o "$found" --overwrite
    else
        echo "Finding the hiking relations in $extract …"
        osmium tags-filter "$extract" r/route=hiking -o "$found" --overwrite
    fi
    # Every node's position, put on the ways that use it, which is what lets
    # the next step read a way without a table of the planet's nodes. A way
    # that runs out of a regional extract keeps its place with no positions,
    # and the tool leaves its relation out. A place relation is measured from
    # its member nodes too, as Overpass measures one, so the places' build
    # keeps those though most carry no tags.
    local locating=(--ignore-missing-nodes)
    [[ "$tool_command" != build-places ]] || locating+=(--keep-member-nodes)
    echo "Putting positions on their ways …"
    osmium add-locations-to-ways "$found" "${locating[@]}" \
        -o "$work/located.osm.pbf" --overwrite
    # Relations and ways apart, because a relation says which ways are wanted
    # and comes after them in the file. `locations_on_ways` is what writes the
    # positions out: without it every way reads as having none.
    osmium cat "$work/located.osm.pbf" -t relation -f opl,add_metadata=false \
        -o "$work/relations.opl" --overwrite
    osmium cat "$work/located.osm.pbf" -t way -f opl,add_metadata=false,locations_on_ways=true \
        -o "$work/ways.opl" --overwrite
    # A place is most often a node, which the routes' builds never read. The
    # positions osmium put on the ways took the nodes that held only a
    # position, so what is left is the nodes with tags and the ones a
    # relation names.
    if [[ "$tool_command" == build-places ]]; then
        osmium cat "$work/located.osm.pbf" -t node -f opl,add_metadata=false \
            -o "$work/nodes.opl" --overwrite
    fi

    # When the data was current, off the extract's own header. A planet file
    # and a Geofabrik extract both say; a file that does not is built without.
    local timestamp
    timestamp="$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$extract" 2>/dev/null || true)"
    if [[ -z "$timestamp" ]]; then
        timestamp="$(osmium fileinfo -g header.option.timestamp "$extract" 2>/dev/null || true)"
    fi

    local arguments=("$tool_command" --relations "$work/relations.opl" --ways "$work/ways.opl" --out "$out")
    [[ "$tool_command" != build-places ]] || arguments+=(--nodes "$work/nodes.opl")
    [[ "$world" == false ]] || arguments+=(--world)
    [[ -z "$timestamp" ]] || arguments+=(--osm-timestamp "$timestamp")
    echo "Filing them …"
    "$tool" "${arguments[@]}"

    if [[ "$keep_work" == false ]]; then
        rm -rf "$work"
    fi
    echo "Wrote $out"
}

# `build-routing`: osmium finds the ways and the hiking relations, cuts them
# into bands of longitude with every node of each band's ways, and puts the
# positions on one band at a time into the tool's standard input. A way across
# a band's edge is in both bands, and the tool files it once.
build_routing() {
    local extract="" out="$build_dir/routing" world=false keep_work=false
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
    [[ -n "$extract" ]] || usage_error "build-routing needs an OpenStreetMap extract."
    [[ -f "$extract" ]] || die "there is no file at $extract."
    command -v osmium >/dev/null 2>&1 \
        || die "osmium is not installed. It reads the extract: brew install osmium-tool"

    # Before an hour of osmium rather than after it, as the tool would.
    routing_output_is_replaceable "$out" || die "$out holds files and no routing-build.json, so it is not an \
earlier routing build to replace. Name an empty directory, or a previous build's."

    prepare_tool
    local work="$out.work"
    mkdir -p "$work"

    local filters=() filter
    while IFS= read -r filter; do
        filters+=("$filter")
    done < <("$tool" routing-filters)
    [[ ${#filters[@]} -gt 0 ]] || die "the trail-cells tool named nothing to find."
    echo "Finding the trails and the roads that join them in $extract …"
    osmium tags-filter "$extract" "${filters[@]}" -f pbf,add_metadata=false \
        -o "$work/routing.osm.pbf" --overwrite
    osmium cat "$work/routing.osm.pbf" -t relation -f opl,add_metadata=false \
        -o "$work/relations.opl" --overwrite

    # Each band holds its ways whole, with every node they use however far
    # outside the band it is: osmium's complete_ways, which is its default.
    local bands=$(( ${#routing_band_edges[@]} - 1 )) index separator=""
    {
        printf '{"extracts":['
        for (( index = 0; index < bands; index++ )); do
            printf '%s{"output":"band-%d.osm.pbf","bbox":[%s,-90,%s,90]}' "$separator" "$index" \
                "${routing_band_edges[index]}" "${routing_band_edges[index + 1]}"
            separator=","
        done
        printf ']}\n'
    } > "$work/bands.json"
    echo "Cutting them into $bands bands of longitude …"
    rm -rf "$work/bands"
    mkdir -p "$work/bands"
    osmium extract "$work/routing.osm.pbf" --config "$work/bands.json" --directory "$work/bands" --overwrite
    rm -f "$work/routing.osm.pbf"

    # Named for the hour the extract is current to, as the extras are, so a
    # second build on one day goes up under a name of its own.
    local timestamp name=routing
    timestamp="$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$extract" 2>/dev/null || true)"
    if [[ -z "$timestamp" ]]; then
        timestamp="$(osmium fileinfo -g header.option.timestamp "$extract" 2>/dev/null || true)"
    fi
    if [[ "$timestamp" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}) ]]; then
        name="routing-${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}-${BASH_REMATCH[4]}"
    fi

    # The build is staged in the work directory and replaces what --out held
    # only once both sides of the pipe succeeded. A band osmium gave up on ends
    # the tool's input as the last band would, so the tool writes a build
    # missing it, which is thrown away with the stage; and a build that fails
    # either way leaves an earlier one in --out as it was.
    local staged="$work/build"
    rm -rf "$staged"
    local arguments=(build-routing --relations "$work/relations.opl" --ways - --out "$staged" --name "$name")
    [[ "$world" == false ]] || arguments+=(--world)
    [[ -z "$timestamp" ]] || arguments+=(--osm-timestamp "$timestamp")
    echo "Putting positions on their ways a band at a time, and filing them …"
    if ! located_bands "$work/bands" "$bands" "$keep_work" | "$tool" "${arguments[@]}"; then
        rm -rf "$staged"
        die "the trail maker's graph was not built."
    fi

    # Checked again, since the build took the best part of an hour. The record
    # goes first and comes back last, so --out never holds a record without
    # the archive it names.
    routing_output_is_replaceable "$out" || die "$out holds files and no routing-build.json any more, so \
it was not replaced. The build is in $staged."
    mkdir -p "$out"
    rm -f "$out/routing-build.json" "$out"/*.pmtiles
    mv "$staged/$name.pmtiles" "$out/"
    mv "$staged/routing-build.json" "$out/"

    if [[ "$keep_work" == false ]]; then
        rm -rf "$work"
    fi
    echo "Wrote $out"
}

# Whether build-routing may put its build in a directory: none there yet, an
# empty one, or an earlier build's, which routing-build.json marks. The
# trail-cells tool refuses any other directory the same way.
routing_output_is_replaceable() {
    local directory="$1" entries
    [[ -d "$directory" ]] || return 0
    [[ -f "$directory/routing-build.json" ]] && return 0
    entries="$(find "$directory" -mindepth 1 -maxdepth 1 ! -name '.*' -print -quit)"
    [[ -z "$entries" ]]
}

# Every band's ways, with their nodes' positions, as OPL on standard output.
# The index is a sorted array of the band's own nodes, sixteen bytes each:
# osmium's default can switch to an array as long as the planet's highest node
# id, a hundred gigabytes. A band read is deleted unless the work is kept,
# because the tool's spool grows on the same disk as the bands are read.
located_bands() {
    local directory="$1" bands="$2" keep_work="$3" index
    for (( index = 0; index < bands; index++ )); do
        osmium add-locations-to-ways "$directory/band-$index.osm.pbf" --ignore-missing-nodes \
            -i sparse_mem_array -f opl,add_metadata=false,locations_on_ways=true -o - || return 1
        [[ "$keep_work" == true ]] || rm -f "$directory/band-$index.osm.pbf"
    done
}

# `pack <build-dir> [--out <dir>] [--name <archive>]`: the tool's pack, into a
# directory beside the build unless --out names another.
pack() {
    local build="" out="" name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out|--name)
                [[ $# -ge 2 ]] || usage_error "missing value for $1."
                if [[ "$1" == --out ]]; then out="$2"; else name="$2"; fi
                shift 2
                ;;
            -*)
                usage_error "unknown option '$1'."
                ;;
            *)
                [[ -z "$build" ]] || usage_error "unexpected argument '$1'."
                build="$1"
                shift
                ;;
        esac
    done
    [[ -n "$build" ]] || usage_error "pack needs the directory a build wrote."
    [[ -d "$build" ]] || die "there is no build at $build."
    [[ -n "$out" ]] || out="${build%/}.archive"
    prepare_tool
    local arguments=(pack "$build" --out "$out")
    [[ -z "$name" ]] || arguments+=(--name "$name")
    "$tool" "${arguments[@]}"
    echo "Next, Scripts/trail-cells.sh upload-archive $out"
}

# `build-elevation [--out <dir>] [--area …] [--name …] [--source …]
# [--coarser …] [--jobs <n>]`: the tool's command of the same name, into
# .build/trail-cells/elevation by default.
build_elevation() {
    local out="$build_dir/elevation" arguments=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out)
                [[ $# -ge 2 ]] || usage_error "missing value for --out."
                out="$2"
                shift 2
                ;;
            --area|--name|--source|--coarser|--jobs)
                [[ $# -ge 2 ]] || usage_error "missing value for $1."
                arguments+=("$1" "$2")
                shift 2
                ;;
            *)
                usage_error "unknown option '$1'."
                ;;
        esac
    done
    prepare_tool
    "$tool" build-elevation --out "$out" ${arguments[@]+"${arguments[@]}"}
    echo "Next, Scripts/trail-cells.sh upload-archive $out"
}

# `upload-archive <dir>`: the archive a whole-world build-routing, pack or
# build-elevation wrote, into the bucket under its own name, refusing one
# already there.
upload_archive() {
    [[ $# -eq 1 ]] || usage_error "upload-archive takes the directory build-routing or pack wrote."
    local directory="$1" record="" file name complete archive
    for file in routing-build.json archive-build.json; do
        [[ -f "$directory/$file" ]] || continue
        [[ -z "$record" ]] || die "$directory holds both routing-build.json and archive-build.json, so which \
archive it is for cannot be told. Build or pack into a directory of its own."
        record="$directory/$file"
    done
    [[ -n "$record" ]] || die "$directory holds no routing-build.json or archive-build.json. Build it with \
build-routing, or pack a build of squares, first."
    name="$(plutil -extract name raw -o - "$record" 2>/dev/null)" || die "$record names no archive."
    complete="$(plutil -extract complete raw -o - "$record" 2>/dev/null)" || die "$record does not say what it covers."
    [[ "$complete" == true ]] || die "$name is not the whole world. The app reads a tile the archive does \
not hold as ground with nothing on it, so only a build of the planet with --world goes up."
    [[ "$name" =~ ^(routing|trails|routes|places|elevation)-[0-9]{8}-[0-9]{2}$ ]] \
        || die "$name is not named for the hour its planet is current to, or its elevation build began. \
Build it from a planet whose header says."
    archive="$directory/$name.pmtiles"
    [[ -f "$archive" ]] || die "there is no archive at $archive."
    r2_load_keys
    [[ -z "$(r2_etag "$name.pmtiles")" ]] || die "$name.pmtiles is already in $R2_BUCKET; build from a newer planet."
    r2_put_parts "$archive" "$name.pmtiles" 256
    echo "Next, Scripts/vector-archives.sh use $name, then publish."
}

# `upload-routing <dir>`: upload-archive, for the directory build-routing
# wrote, by the name it had before there were other archives.
upload_routing() {
    [[ $# -eq 1 ]] || usage_error "upload-routing takes the directory build-routing wrote."
    [[ -f "$1/routing-build.json" ]] || die "$1 holds no routing-build.json. Build it with build-routing first."
    upload_archive "$1"
}

# `update-planet`: pyosmium-up-to-date, again for as long as it says more
# changes are waiting. Its first pass starts from the time in the planet's
# header, on the hourly diffs it takes from openstreetmap.org by default, and
# writes the server and the diff it reached into the header, so every later
# pass carries on from exactly there. It answers 1 only after it has applied
# some, so the passes always end. A pass that fails leaves the file as the
# pass before it wrote it.
update_planet() {
    local planet="" size=4096
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --size)
                [[ $# -ge 2 ]] || usage_error "missing value for --size."
                [[ "$2" =~ ^[1-9][0-9]*$ ]] || usage_error "--size takes a whole number of megabytes."
                size="$2"
                shift 2
                ;;
            -*)
                usage_error "unknown option '$1'."
                ;;
            *)
                [[ -z "$planet" ]] || usage_error "unexpected argument '$1'."
                planet="$1"
                shift
                ;;
        esac
    done
    [[ -n "$planet" ]] || usage_error "update-planet needs the planet file to update."
    [[ -f "$planet" ]] || die "there is no file at $planet. Download a planet once, by torrent or from \
a mirror (https://wiki.openstreetmap.org/wiki/Planet.osm), then keep it current with update-planet."
    command -v pyosmium-up-to-date >/dev/null 2>&1 \
        || die "pyosmium-up-to-date is not installed. It applies the changes: brew install pipx && pipx install osmium"

    # Room for the new copy and the changes, checked before a diff is
    # downloaded: a pass that fills the disk downloaded its diffs for nothing.
    local bytes needed available
    bytes="$(stat -f %z "$planet" 2>/dev/null || stat -c %s "$planet")"
    needed=$(( bytes / 1024 + size * 1024 ))
    available="$(df -Pk "$(dirname "$planet")" | awk 'NR == 2 { print $4 }')"
    [[ "$available" =~ ^[0-9]+$ ]] || die "could not read the free space beside $planet."
    (( available >= needed )) || die "there is no room beside $planet for its updated copy: \
it needs $(( (needed + 1048575) / 1048576 )) GB free, and there are $(( available / 1048576 ))."

    local pass=1 status
    while true; do
        echo "Applying OpenStreetMap's changes to $planet, pass $pass …"
        status=0
        pyosmium-up-to-date -v --size "$size" "$planet" || status=$?
        case "$status" in
            0) break ;;
            1) pass=$(( pass + 1 )) ;;
            *) die "pyosmium-up-to-date stopped with status $status. $planet is as the pass before left it." ;;
        esac
    done

    local timestamp=""
    if command -v osmium >/dev/null 2>&1; then
        timestamp="$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$planet" 2>/dev/null || true)"
    fi
    echo "$planet is current${timestamp:+ to $timestamp}."
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
    update-planet)
        update_planet "$@"
        ;;
    build)
        build build squares "$@"
        ;;
    build-routes)
        build build-routes routes "$@"
        ;;
    build-places)
        build build-places places "$@"
        ;;
    build-graph)
        build build-graph graph "$@"
        ;;
    build-routing)
        build_routing "$@"
        ;;
    pack)
        pack "$@"
        ;;
    upload-archive)
        upload_archive "$@"
        ;;
    upload-routing)
        upload_routing "$@"
        ;;
    upload|prune|whoami)
        with_database "$command" "$@"
        ;;
    build-elevation)
        build_elevation "$@"
        ;;
    inspect|cell|sign|routing-tile|archive-tile|copernicus-tile|elevation-height|copernicus-fixture)
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
