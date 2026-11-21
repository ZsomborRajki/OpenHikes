#!/usr/bin/env bash
#
# offline-countries.sh — cut the countries the app downloads out of the planet
# the OpenHikes map draws, and put them beside it on the tile server.
#
# An area is every country Natural Earth outlines, except the few too big for
# one download (Scripts/lib/offline-countries.json), which are cut by state or
# province instead (Scripts/lib/offline-countries/Areas.swift). Each is four
# PMTiles archives, cut along its outline grown by a margin: the Protomaps
# basemap's tiles and the extras' (Scripts/vector-extras.sh) to zoom 14, which
# every download takes, and both at zoom 15, which the app's Extra Detail adds.
# They are read out of local copies of the archives the app's manifest names
# first, where Scripts/vector-archives.sh basemap and Scripts/vector-extras.sh
# build leave them, or out of the R2 bucket `openhikes-tiles` with signed HTTP
# ranges where there is none, and each is read back through the app's own
# reader and held to the source before it is listed.
# `countries/manifest.json` lists them, with each file's size and SHA-256 and
# the outline the map draws; the app reads it from tiles.openhikes.app.
# *The offline countries* in AGENTS.md is the procedure, and
# OpenHikes/Tiles/Countries/OfflineCountryManifest.swift the format.
#
# It is a development tool and is in no gate, though its parts are:
# Scripts/run-script-tests.sh builds the tool and runs `selftest`.
#
# Usage:
#   Scripts/offline-countries.sh publish [--only AT,US] [--batch <n>] [--planet <file>]
#                                        [--extras <file>] [--margin-km <km>]
#   Scripts/offline-countries.sh build [--only AT,US] [--out <dir>] [--planet <file>]
#                                      [--extras <file>] [--margin-km <km>]
#   Scripts/offline-countries.sh upload <dir> [--dry-run]
#   Scripts/offline-countries.sh prune [--dry-run]
#   Scripts/offline-countries.sh areas
#   Scripts/offline-countries.sh inspect <file.pmtiles>...
#   Scripts/offline-countries.sh selftest
#
#   publish   Build and upload every area, or only those --only names, a batch
#             of --batch (20) at a time, deleting each batch once it is up, so
#             the disk holds no more than a batch beside the planet. It lists
#             the areas it has put up under .build/offline-countries, one list
#             for each basemap and extras, and a run after a stop goes on from
#             there, given the same files, margin and bucket as the run that
#             started the list, which it writes down beside it. Takes build's
#             options.
#   build     Cut every area, or only those --only names (a region's code, or a
#             split country's for all its regions), into <dir> (default
#             .build/offline-countries/out) with its manifest.json. The basemap
#             and the extras are the first the app's manifest names
#             (OpenHikes/Tiles/Vector/VectorTileArchiveManifest.json), read
#             from the local copies where there are whole ones, which is what
#             makes cutting the whole world take hours rather than a day, and
#             from the bucket where not; --planet and --extras name other
#             files. The build is named for the later of the two archives'
#             days. A 3 km margin by default.
#   upload    Put <dir>'s files in the bucket under countries/, each with its
#             SHA-256 beside it, skipping any already there with the same bytes
#             and refusing one there with others, then merge its manifest into
#             the server's and write that last, so the app never lists a file
#             that is not there yet.
#   prune     Delete every archive under countries/ of a build earlier than
#             the one the server's manifest lists for its area, keeping any
#             other the manifest does not list, since an upload puts its files
#             up before the manifest. An app that already has the manifest
#             that listed one and asks for it fails that download, and tries
#             again from the manifest it reads next.
#   areas     Print every area build cuts, its code and a region's country.
#   inspect   Print an archive's header.
#   selftest  Cut a made-up archive and read it back.
#
# Environment:
#   OPENHIKES_R2_ENV  The bucket's S3 keys (default
#                     ~/.config/openhikes/r2-openhikes-tiles.env: R2_ACCOUNT_ID,
#                     R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET), as for
#                     Scripts/vector-extras.sh (Scripts/lib/r2.sh).
#   OPENHIKES_OFFLINE_COUNTRIES_BUILD  Where the tool is compiled to.
#
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${OPENHIKES_OFFLINE_COUNTRIES_BUILD:-$repository_root/.build/offline-countries}"
tool="$build_dir/offline-countries"
cache="$HOME/Library/Caches/OpenHikes/offline-countries"
# Where Scripts/vector-archives.sh basemap and Scripts/vector-extras.sh build
# leave their archives.
archives_cache="${OPENHIKES_VECTOR_ARCHIVES_CACHE:-$HOME/Library/Caches/OpenHikes/vector-archives}"
extras_cache="${OPENHIKES_VECTOR_EXTRAS_CACHE:-$HOME/Library/Caches/OpenHikes/vector-extras}"

# shellcheck source=lib/r2.sh
source "$repository_root/Scripts/lib/r2.sh"

# Natural Earth's 1:50m countries and 1:10m states and provinces, public
# domain, pinned to a release.
natural_earth="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson"
outlines_url="$natural_earth/ne_50m_admin_0_countries.geojson"
outlines_sha256="3e458fc036ad0a66411f2c1e6cac49c5d7bfb81cb1123bc513b22511a2b7fdeb"
regions_url="$natural_earth/ne_10m_admin_1_states_provinces.geojson"
regions_sha256="22d0e3ad85eb3e27f17cabf8ba2d50e554fbc27a87796ff891d958185da62fb5"

die() {
    echo "offline-countries: $1" >&2
    exit 1
}

usage() {
    sed -n '/^# Usage:/,/^# Environment:/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
}

# The app's files the tool is compiled with: the format, the reader and the
# manifest, as they stand, which is why each imports nothing of the app's.
# With them, out of the package that draws the map, the one file that says
# which layouts of the archives its renderer reads, which the manifest
# holds a country to.
tool_sources() {
    printf '%s\n' "$repository_root"/Scripts/lib/offline-countries/*.swift \
        "$repository_root/OpenHikes/General/PackedBytes.swift" \
        "$repository_root/OpenHikes/Tiles/Countries/PMTilesFile.swift" \
        "$repository_root/OpenHikes/Tiles/Countries/PMTilesArchive.swift" \
        "$repository_root/OpenHikes/Tiles/Countries/OfflineCountryManifest.swift" \
        "$repository_root/OpenHikesVectorTiles/Sources/OpenHikesVectorTiles/Archives/VectorTileSchema.swift"
}

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
    swiftc -O -swift-version 6 -warnings-as-errors -parse-as-library -o "$tool" "${sources[@]}" \
        || die "the tool did not compile."
}

# The first of `list` (basemaps or extras) the app's manifest names, which is
# what the app draws from, read out of the app rather than spelled here.
archive_name() {
    local list="$1" manifest="$repository_root/OpenHikes/Tiles/Vector/VectorTileArchiveManifest.json" name
    name="$(plutil -extract "$list.0.name" raw -o - "$manifest" 2>/dev/null)" \
        || die "could not read the first of $list out of $manifest"
    printf '%s\n' "$name"
}

# The generation of the first extras the app's manifest names, which an area
# cut from them carries, so that a build which draws only earlier ones leaves
# it off its list.
extras_generation() {
    local manifest="$repository_root/OpenHikes/Tiles/Vector/VectorTileArchiveManifest.json" generation
    generation="$(plutil -extract "extras.0.generation" raw -o - "$manifest" 2>/dev/null)" \
        || die "could not read the first extras' generation out of $manifest"
    [[ "$generation" =~ ^[1-9][0-9]*$ ]] || die "the first extras' generation in $manifest is '$generation'"
    printf '%s\n' "$generation"
}

# The archive to cut from: a local copy where there is a whole one, as large
# as the bucket's, and the bucket's where there is none. A copy of another
# size is a download or a build cut short, which nothing should be cut from.
archive_source() {
    local name="$1" directory size remote
    for directory in "$archives_cache" "$extras_cache"; do
        [[ -f "$directory/$name.pmtiles" ]] || continue
        size="$(stat -f %z "$directory/$name.pmtiles")"
        remote="$(r2_list "$name.pmtiles" / | awk -F '\t' -v key="$name.pmtiles" '$1 == key { print $2 }')"
        [[ "$size" == "$remote" ]] \
            || die "$directory/$name.pmtiles is $size bytes and the bucket's ${remote:-is missing}; delete it, or name the file to cut from"
        printf '%s\n' "$directory/$name.pmtiles"
        return
    done
    printf 'r2:%s.pmtiles\n' "$name"
}

# A Natural Earth file, downloaded once and held to its pinned SHA-256.
natural_earth_file() {
    local url="$1" sha256="$2" file
    file="$cache/$(basename "$url" .geojson)-5.1.2.geojson"
    if [[ ! -f "$file" ]]; then
        mkdir -p "$cache"
        curl -sSfL -o "$file.part" "$url" || die "could not download $url"
        mv "$file.part" "$file"
    fi
    [[ "$(shasum -a 256 "$file" | cut -d ' ' -f 1)" == "$sha256" ]] \
        || die "$file is not the pinned Natural Earth release; delete it and build again"
    printf '%s\n' "$file"
}

build() {
    local out="$repository_root/.build/offline-countries/out" planet_file="" extras="" only="" margin=3
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out) out="$2"; shift 2 ;;
            --planet) planet_file="$2"; shift 2 ;;
            --extras) extras="$2"; shift 2 ;;
            --only) only="$2"; shift 2 ;;
            --margin-km) margin="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    local basemap planet extras_name extras_day build
    basemap="$(archive_name basemaps)"
    planet="${basemap#planet-}"
    [[ "$planet" =~ ^[0-9]{8}$ ]] || die "the basemap $basemap is not named planet-YYYYMMDD"
    extras_name="$(archive_name extras)"
    [[ "$extras_name" =~ ^extras-([0-9]{8})(-[0-9]{2})?$ ]] \
        || die "the extras $extras_name are not named extras-YYYYMMDD-HH"
    extras_day="${BASH_REMATCH[1]}"
    # A build is named for the later of its two archives' days, so a cut
    # over new extras on the same basemap goes up under names of its own,
    # and an installed app, which offers a later build as an update, offers
    # it. A second cut on one day over the same two days is refused at the
    # upload, which keeps a name's bytes, and waits for a newer archive.
    build="$planet"
    [[ "$extras_day" < "$build" ]] || build="$extras_day"
    local outline_file region_file
    outline_file="$(natural_earth_file "$outlines_url" "$outlines_sha256")"
    region_file="$(natural_earth_file "$regions_url" "$regions_sha256")"
    r2_load_keys
    [[ -n "$planet_file" ]] || planet_file="$(archive_source "$basemap")"
    [[ -n "$extras" ]] || extras="$(archive_source "$extras_name")"
    # The manifest's first extras are of the generation it gives them,
    # whether they were found here or named, as `publish` names them, and an
    # archive's name is never given to another build. Any other extras are
    # of no generation this knows.
    local generation="" extras_file_name="${extras#r2:}"
    if [[ "${extras_file_name##*/}" == "$extras_name.pmtiles" ]]; then
        generation="$(extras_generation)"
    fi
    echo "offline-countries: cutting build $build from $planet_file and $extras"
    prepare_tool
    local arguments=(build --planet "$planet_file" --extras "$extras" --build "$build"
        --outlines "$outline_file" --regions "$region_file"
        --countries "$repository_root/Scripts/lib/offline-countries.json"
        --out "$out" --margin-km "$margin"
        --server "https://tiles.openhikes.app/$basemap")
    [[ -z "$only" ]] || arguments+=(--only "$only")
    [[ -z "$generation" ]] || arguments+=(--extras-generation "$generation")
    "$tool" "${arguments[@]}"
    echo "offline-countries: built into $out"
}

upload() {
    [[ $# -ge 1 ]] || usage
    local dir="$1" dry_run=false
    shift
    [[ "${1:-}" != "--dry-run" ]] || dry_run=true
    [[ -f "$dir/manifest.json" ]] || die "no manifest.json in $dir"
    r2_load_keys
    prepare_tool
    local base listing
    base="$(r2_url)"
    listing="$("$tool" files "$dir/manifest.json")" || die "could not read $dir/manifest.json"
    [[ -n "$listing" ]] || die "$dir/manifest.json lists no files"
    local path bytes sha256 name local_size head status remote_size remote_sha256
    while IFS=$'\t' read -r path bytes sha256; do
        name="$(basename "$path")"
        [[ -f "$dir/$name" ]] || die "the manifest lists $name, which is not in $dir"
        local_size="$(stat -f %z "$dir/$name")"
        [[ "$local_size" == "$bytes" ]] || die "$name is $local_size bytes, and the manifest says $bytes"
        [[ "$(shasum -a 256 "$dir/$name" | cut -d ' ' -f 1)" == "$sha256" ]] \
            || die "$name is not the file the manifest describes"
        (( local_size <= 5 * 1024 * 1024 * 1024 )) || die "$name is over the 5 GiB R2 takes in one request"
        head="$(r2_curl -I "$base/$path" | tr -d '\r')"
        status="$(printf '%s\n' "$head" | head -n 1 | awk '{print $2}')"
        case "$status" in
            404) ;;
            200)
                # The manifest is about to promise the app these bytes, and an
                # app throws away a download whose SHA-256 is not the one
                # promised, so a name already taken is reused only for the same
                # bytes. An upload from here names its digest beside the
                # object; one put there without it is read back to be sure.
                remote_size="$(printf '%s\n' "$head" | awk 'tolower($1) == "content-length:" {print $2}')"
                [[ "$remote_size" == "$local_size" ]] \
                    || die "$path is in the bucket at $remote_size bytes; a build goes under a new date"
                remote_sha256="$(printf '%s\n' "$head" | awk 'tolower($1) == "x-amz-meta-sha256:" {print $2}')"
                if [[ -z "$remote_sha256" ]]; then
                    remote_sha256="$(r2_curl -f "$base/$path" | shasum -a 256 | cut -d ' ' -f 1)" \
                        || die "could not read $path back from the bucket"
                fi
                [[ "$remote_sha256" == "$sha256" ]] \
                    || die "$path is in the bucket with other bytes; a build goes under a new date"
                echo "offline-countries: $path is already there"
                continue
                ;;
            *) die "R2 answered $status when asked for $path" ;;
        esac
        if [[ "$dry_run" == true ]]; then
            echo "offline-countries: would upload $path ($local_size bytes)"
            continue
        fi
        status="$(r2_put -H "If-None-Match: *" \
            -H "Content-Type: application/octet-stream" -H "x-amz-meta-sha256: $sha256" \
            -T "$dir/$name" "$base/$path")"
        if [[ "$status" == 412 ]]; then
            # Taken since the HEAD above: by an attempt of ours that landed
            # after all, if the digest beside it is this file's.
            remote_sha256="$(r2_curl -I "$base/$path" | tr -d '\r' \
                | awk 'tolower($1) == "x-amz-meta-sha256:" {print $2}')"
            [[ "$remote_sha256" == "$sha256" ]] || die "$path reached the bucket from another upload first"
            status=200
        fi
        [[ "$status" == 200 ]] || die "R2 answered $status to the upload of $path"
        echo "offline-countries: uploaded $path ($local_size bytes)"
    done <<< "$listing"

    local server_manifest="$dir/.server-manifest.json" merged="$dir/.merged-manifest.json"
    status="$(r2_curl -o "$server_manifest" -w "%{http_code}" "$base/countries/manifest.json")"
    case "$status" in
        200) ;;
        404) rm -f "$server_manifest" ;;
        *) die "R2 answered $status when asked for the manifest" ;;
    esac
    "$tool" merge --server "$server_manifest" --build "$dir/manifest.json" --out "$merged"
    if [[ "$dry_run" == true ]]; then
        echo "offline-countries: would write the merged manifest ($merged)"
        return
    fi
    status="$(r2_put -H "Content-Type: application/json" -T "$merged" "$base/countries/manifest.json")"
    [[ "$status" == 200 ]] || die "R2 answered $status to the manifest"
    echo "offline-countries: wrote countries/manifest.json"
}

# What a cut reads an archive from, as `publish` records it: a file and its
# size, or the bucket's key.
source_identity() {
    if [[ -f "$1" ]]; then
        printf '%s, %s bytes\n' "$1" "$(stat -f %z "$1")"
    else
        printf '%s\n' "$1"
    fi
}

# `publish`: build and upload a batch at a time, as Usage says.
publish() {
    local only="" batch_size=20 planet_file="" extras_file="" margin=3
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --only) only="$2"; shift 2 ;;
            --batch) batch_size="$2"; shift 2 ;;
            --planet) planet_file="$2"; shift 2 ;;
            --extras) extras_file="$2"; shift 2 ;;
            --margin-km) margin="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    [[ "$batch_size" =~ ^[1-9][0-9]*$ ]] || usage
    local basemap extras work
    basemap="$(archive_name basemaps)"
    extras="$(archive_name extras)"
    work="$build_dir/publish-$basemap-$extras"
    # The areas listed done are one build, so every batch of it is cut from
    # the same two files along the same margin and goes to the same bucket.
    # The first run of a list writes down what it was given, and a run given
    # anything else is refused rather than mixed into the build.
    r2_load_keys
    [[ -n "$planet_file" ]] || planet_file="$(archive_source "$basemap")"
    [[ -n "$extras_file" ]] || extras_file="$(archive_source "$extras")"
    local settings
    settings="$(printf 'planet %s\nextras %s\nmargin %s km\nbucket %s/%s' \
        "$(source_identity "$planet_file")" "$(source_identity "$extras_file")" "$margin" \
        "$R2_ACCOUNT_ID" "$R2_BUCKET")"
    mkdir -p "$work"
    touch "$work/done.txt"
    if [[ ! -s "$work/done.txt" ]]; then
        printf '%s\n' "$settings" > "$work/settings.txt"
    elif [[ "$(cat "$work/settings.txt" 2>/dev/null)" != "$settings" ]]; then
        die "$work lists areas put up with other settings than these:
$settings
Go on with the ones it was started with, or delete it to start over:
$(cat "$work/settings.txt" 2>/dev/null || echo "(none recorded)")"
    fi
    # The list is read whole before it is used, so a tool that fails to
    # build or to read the outlines stops the run rather than reading as no
    # areas left to publish.
    local area_list id group wanted=",$only," remaining=()
    area_list="$(areas)" || die "could not list the areas; nothing was published"
    [[ -n "$area_list" ]] || die "the tool listed no areas; nothing was published"
    while IFS=$'\t' read -r id group; do
        [[ -z "$only" || "$wanted" == *",$id,"* || ( -n "$group" && "$wanted" == *",$group,"* ) ]] || continue
        grep -qx "$id" "$work/done.txt" || remaining+=("$id")
    done <<< "$area_list"
    echo "offline-countries: ${#remaining[@]} areas to publish, $(wc -l < "$work/done.txt" | tr -d ' ') already up"
    local start batch
    for (( start = 0; start < ${#remaining[@]}; start += batch_size )); do
        batch=("${remaining[@]:start:batch_size}")
        rm -rf "$work/batch"
        build --only "$(IFS=,; echo "${batch[*]}")" --out "$work/batch" \
            --planet "$planet_file" --extras "$extras_file" --margin-km "$margin"
        upload "$work/batch"
        printf '%s\n' "${batch[@]}" >> "$work/done.txt"
        rm -rf "$work/batch"
        echo "offline-countries: $(( start + ${#batch[@]} )) of ${#remaining[@]} published"
    done
    echo "offline-countries: every area is up; Scripts/offline-countries.sh prune deletes the older builds' files"
}

# `prune [--dry-run]`: the files of builds the server's manifest has moved
# past, deleted.
prune() {
    local dry_run=false
    [[ $# -eq 0 ]] || { [[ $# -eq 1 && "$1" == --dry-run ]] || usage; dry_run=true; }
    r2_load_keys
    prepare_tool
    mkdir -p "$build_dir"
    local manifest="$build_dir/.server-manifest.json" status
    status="$(r2_curl -o "$manifest" -w "%{http_code}" "$(r2_url countries/manifest.json)")"
    [[ "$status" == 200 ]] || die "R2 answered $status for countries/manifest.json; prune nothing without it"
    local listed objects keys path
    listed="$("$tool" files "$manifest" | cut -f 1)"
    [[ -n "$listed" ]] || die "countries/manifest.json lists no files; prune nothing without them"
    objects="$(r2_list countries/)"
    keys="$(cut -f 1 <<< "$objects")"
    while IFS= read -r path; do
        grep -qxF "$path" <<< "$keys" \
            || die "the manifest lists $path, which the bucket does not hold; prune nothing until it does"
    done <<< "$listed"
    # An upload puts an area's files in the bucket before the manifest that
    # lists them, so a file the manifest does not list may be on its way into
    # it. Only one of a build earlier than the one listed for its area goes:
    # an area's listed build only rises (`merge` refuses an earlier one), so
    # nothing lists that file again. A file of the listed build or a later
    # one, of an area not listed at all, or of a name no build gives is kept.
    # A file's area and build are read off its name,
    # `countries/<area>[-detail][-extras]-<build>.pmtiles`.
    local verdicts
    verdicts="$({ awk '{ print "listed\t" $0 }' <<< "$listed"; awk '{ print "object\t" $0 }' <<< "$objects"; } \
        | awk -F '\t' '
        function area_build(key,    stem, parts, count, i) {
            if (key !~ /^countries\/[^\/]+\.pmtiles$/) return 0
            stem = substr(key, 11, length(key) - 18)
            count = split(stem, parts, "-")
            if (count < 2 || parts[count] !~ /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$/) return 0
            build = parts[count--]
            if (count > 1 && parts[count] == "extras") count--
            if (count > 1 && parts[count] == "detail") count--
            area = parts[1]
            for (i = 2; i <= count; i++) area = area "-" parts[i]
            return 1
        }
        $1 == "listed" { isListed[$2] = 1; if (area_build($2)) listedBuild[area] = build; next }
        $2 !~ /\.pmtiles$/ || ($2 in isListed) { next }
        area_build($2) && (area in listedBuild) && build < listedBuild[area] { print "retired\t" $2 "\t" $3; next }
        { print "kept\t" $2 "\t" $3 }
    ')"
    local verdict key bytes doomed=0 spared=0
    while IFS=$'\t' read -r verdict key bytes; do
        case "$verdict" in
            retired)
                doomed=$(( doomed + 1 ))
                if [[ "$dry_run" == true ]]; then
                    echo "offline-countries: would delete $key ($bytes bytes)"
                else
                    r2_delete "$key"
                    echo "offline-countries: deleted $key ($bytes bytes)"
                fi
                ;;
            kept)
                spared=$(( spared + 1 ))
                echo "offline-countries: kept $key ($bytes bytes): no later build of its area is listed"
                ;;
        esac
    done <<< "$verdicts"
    echo "offline-countries: $doomed archives of builds the manifest has moved past$([[ "$dry_run" == true ]] \
        && echo ", none deleted"), and $spared it does not list kept"
}

areas() {
    prepare_tool
    "$tool" areas --countries "$repository_root/Scripts/lib/offline-countries.json" \
        --outlines "$(natural_earth_file "$outlines_url" "$outlines_sha256")" \
        --regions "$(natural_earth_file "$regions_url" "$regions_sha256")"
}

[[ $# -ge 1 ]] || usage
command="$1"
shift
case "$command" in
    publish) publish "$@" ;;
    build) build "$@" ;;
    areas) areas ;;
    upload) upload "$@" ;;
    prune) prune "$@" ;;
    inspect) prepare_tool; "$tool" inspect "$@" ;;
    selftest) prepare_tool; "$tool" selftest ;;
    *) usage ;;
esac
