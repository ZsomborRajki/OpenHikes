#!/usr/bin/env bash
#
# offline-countries.sh — cut the countries the app downloads out of the planet
# the OpenHikes map draws, and put them beside it on the tile server.
#
# A country is two PMTiles archives: the Protomaps basemap's tiles and the
# extras' (Scripts/vector-extras.sh), cut along the country's Natural Earth
# outline grown by a margin, to the zoom the map is drawn from. They are read
# out of the archives already in the R2 bucket `openhikes-tiles` with signed
# HTTP ranges, so nothing downloads the planet, and each is read back through
# the app's own reader and held to the source before it is listed.
# `countries/manifest.json` lists them, with each file's size and SHA-256 and
# the outline the map draws; the app reads it from tiles.openhikes.app.
# *The offline countries* in AGENTS.md is the procedure, and
# OpenHikes/Tiles/Countries/OfflineCountryManifest.swift the format.
#
# It is a development tool and is in no gate, though its parts are:
# Scripts/run-script-tests.sh builds the tool and runs `selftest`.
#
# Usage:
#   Scripts/offline-countries.sh build [--only AT,CH] [--out <dir>] [--extras <file>]
#                                      [--max-zoom <z>] [--margin-km <km>]
#   Scripts/offline-countries.sh upload <dir> [--dry-run]
#   Scripts/offline-countries.sh inspect <file.pmtiles>...
#   Scripts/offline-countries.sh selftest
#
#   build     Cut the countries in Scripts/lib/offline-countries.json, or only
#             those --only names, into <dir> (default .build/offline-countries/out)
#             with its manifest.json. The planet build is the one
#             VectorTileSource.openHikesPlanet names; --extras reads the extras
#             from a local copy rather than from the bucket. Zoom 15 and a
#             3 km margin by default.
#   upload    Put <dir>'s files in the bucket under countries/, each with its
#             SHA-256 beside it, skipping any already there with the same bytes
#             and refusing one there with others, then merge its manifest into
#             the server's and write that last, so the app never lists a file
#             that is not there yet.
#   inspect   Print an archive's header.
#   selftest  Cut a made-up archive and read it back.
#
# Environment:
#   OPENHIKES_R2_ENV  The bucket's S3 keys (default
#                     ~/.config/openhikes/r2-openhikes-tiles.env: R2_ACCOUNT_ID,
#                     R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET), as for
#                     Scripts/vector-extras.sh.
#   OPENHIKES_OFFLINE_COUNTRIES_BUILD  Where the tool is compiled to.
#
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${OPENHIKES_OFFLINE_COUNTRIES_BUILD:-$repository_root/.build/offline-countries}"
tool="$build_dir/offline-countries"
cache="$HOME/Library/Caches/OpenHikes/offline-countries"

# Natural Earth's 1:50m countries, public domain, pinned to a release.
outlines_url="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_50m_admin_0_countries.geojson"
outlines_sha256="3e458fc036ad0a66411f2c1e6cac49c5d7bfb81cb1123bc513b22511a2b7fdeb"

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
tool_sources() {
    printf '%s\n' "$repository_root"/Scripts/lib/offline-countries/*.swift \
        "$repository_root/OpenHikes/General/PackedBytes.swift" \
        "$repository_root/OpenHikes/Tiles/Countries/PMTilesFile.swift" \
        "$repository_root/OpenHikes/Tiles/Countries/PMTilesArchive.swift" \
        "$repository_root/OpenHikes/Tiles/Countries/OfflineCountryManifest.swift"
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

load_keys() {
    local env_file="${OPENHIKES_R2_ENV:-$HOME/.config/openhikes/r2-openhikes-tiles.env}"
    [[ -f "$env_file" ]] || die "no R2 keys at $env_file"
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
}

# The planet build the app draws, read out of the app rather than spelled here.
planet_build() {
    local source="$repository_root/OpenHikes/Tiles/Vector/VectorTileSource.swift" build
    build="$(sed -n 's|.*tiles.openhikes.app/planet-\([0-9]\{8\}\)".*|\1|p' "$source" | head -n 1)"
    [[ -n "$build" ]] || die "could not read the planet build out of $source"
    printf '%s\n' "$build"
}

outlines() {
    local file="$cache/ne_50m_admin_0_countries-5.1.2.geojson"
    if [[ ! -f "$file" ]]; then
        mkdir -p "$cache"
        curl -sSfL -o "$file.part" "$outlines_url" || die "could not download the outlines"
        mv "$file.part" "$file"
    fi
    [[ "$(shasum -a 256 "$file" | cut -d ' ' -f 1)" == "$outlines_sha256" ]] \
        || die "$file is not the pinned Natural Earth release; delete it and build again"
    printf '%s\n' "$file"
}

build() {
    local out="$repository_root/.build/offline-countries/out" extras="" only="" max_zoom=15 margin=3
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out) out="$2"; shift 2 ;;
            --extras) extras="$2"; shift 2 ;;
            --only) only="$2"; shift 2 ;;
            --max-zoom) max_zoom="$2"; shift 2 ;;
            --margin-km) margin="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    local planet
    planet="$(planet_build)"
    [[ -n "$extras" ]] || extras="r2:extras-$planet.pmtiles"
    local outline_file
    outline_file="$(outlines)"
    load_keys
    prepare_tool
    local arguments=(build --planet "r2:planet-$planet.pmtiles" --extras "$extras" --build "$planet"
        --outlines "$outline_file" --countries "$repository_root/Scripts/lib/offline-countries.json"
        --out "$out" --max-zoom "$max_zoom" --margin-km "$margin"
        --server "https://tiles.openhikes.app/planet-$planet")
    [[ -z "$only" ]] || arguments+=(--only "$only")
    "$tool" "${arguments[@]}"
    echo "offline-countries: built into $out"
}

r2_curl() {
    curl -s --aws-sigv4 "aws:amz:auto:s3" --user "$R2_ACCESS_KEY_ID:$R2_SECRET_ACCESS_KEY" \
        -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" "$@"
}

upload() {
    [[ $# -ge 1 ]] || usage
    local dir="$1" dry_run=false
    shift
    [[ "${1:-}" != "--dry-run" ]] || dry_run=true
    [[ -f "$dir/manifest.json" ]] || die "no manifest.json in $dir"
    load_keys
    prepare_tool
    local base="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com/$R2_BUCKET"
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
        status="$(r2_curl -o /dev/null -w "%{http_code}" -H "If-None-Match: *" \
            -H "Content-Type: application/octet-stream" -H "x-amz-meta-sha256: $sha256" \
            -T "$dir/$name" "$base/$path")"
        [[ "$status" == 200 ]] || die "R2 answered $status to the upload of $path"
        echo "offline-countries: uploaded $path ($local_size bytes)"
    done < <("$tool" files "$dir/manifest.json")

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
    status="$(r2_curl -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" \
        -T "$merged" "$base/countries/manifest.json")"
    [[ "$status" == 200 ]] || die "R2 answered $status to the manifest"
    echo "offline-countries: wrote countries/manifest.json"
}

[[ $# -ge 1 ]] || usage
command="$1"
shift
case "$command" in
    build) build "$@" ;;
    upload) upload "$@" ;;
    inspect) prepare_tool; "$tool" inspect "$@" ;;
    selftest) prepare_tool; "$tool" selftest ;;
    *) usage ;;
esac
