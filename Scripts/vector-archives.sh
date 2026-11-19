#!/bin/bash
#
# vector-archives.sh — the archives the OpenHikes map is drawn from, and the
# manifest that names them.
#
# The app draws the OpenStreetMap style from a basemap archive and an extras
# archive on tiles.openhikes.app, and learns which from the server's manifest,
# `manifest.json` at its root (`VectorTileArchiveManifest`). That manifest is
# OpenHikes/Tiles/Vector/VectorTileArchiveManifest.json: the app bundles it,
# and this puts it on the server. *Tiles* in AGENTS.md has the whole refresh,
# extras and countries included.
#
# `basemap` copies Protomaps' newest daily build of the schema the app reads
# (the manifest's first basemap's) into the R2 bucket `openhikes-tiles` as
# `planet-YYYYMMDD.pmtiles`, or that day's build when given one. It downloads
# the build into ~/Library/Caches/OpenHikes/vector-archives, resuming where a
# dropped connection left it, where Scripts/offline-countries.sh cuts the
# countries from it, and sends it up in the parts Protomaps uploaded it in, so
# that the bucket's ETag must come out as Protomaps' own: a copy that differs
# by a byte is abandoned before it is written. A build the bucket already
# holds under Protomaps' ETag is left as it is, and not downloaded.
#
# `use` puts an archive in the bucket at the head of its list in the manifest,
# and raises `revision` above the server's, once however many archives it
# names before the next publish: a basemap (`planet-…`) of the schema of the one it
# replaces, extras (`extras-…`) of the generation of the ones they replace,
# unless --schema or --generation says otherwise. It drops what no build would
# draw from any more, the archives behind it of the same schema or of the same
# or a later generation, and keeps the first of each other one for the builds
# that read only that. Then `publish`, and commit the file.
#
# `check` asks the server for every archive the manifest names, and fails on
# any it does not have: an app told to draw from one would fall back to
# openstreetmap.org. `publish` checks, refuses a revision no higher than the
# server's (an app never moves to a lower one), puts the file in the bucket as
# `manifest.json`, and reads it back through the server.
#
# `prune` deletes every archive at the bucket's root that neither the server's
# manifest nor this one names, so an archive uploaded and not yet published is
# kept. An archive leaves the manifest before it leaves the bucket: an app
# that asks for a deleted one gets a 410, reads the manifest again and moves,
# so prune once the apps have had the publish, or at once while no build
# that reads the server is in anybody's hands. A build from before the
# manifest (TestFlight 1.6 (1)) names its archives in code and never moves.
#
# It signs with R2's S3 keys (Scripts/lib/r2.sh), read from OPENHIKES_R2_ENV
# (default ~/.config/openhikes/r2-openhikes-tiles.env). It is a development
# tool and is in no gate.
#
# Usage:
#   Scripts/vector-archives.sh basemap [<YYYYMMDD>]
#   Scripts/vector-archives.sh use <name> [--schema <n> | --generation <n>]
#   Scripts/vector-archives.sh check
#   Scripts/vector-archives.sh publish
#   Scripts/vector-archives.sh prune [--dry-run]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${OPENHIKES_VECTOR_ARCHIVE_MANIFEST:-$REPO_ROOT/OpenHikes/Tiles/Vector/VectorTileArchiveManifest.json}"
SERVER="${OPENHIKES_TILE_SERVER:-https://tiles.openhikes.app}"
PROTOMAPS="${OPENHIKES_PROTOMAPS_BUILDS:-https://build.protomaps.com}"
PROTOMAPS_INDEX="${OPENHIKES_PROTOMAPS_INDEX:-https://build-metadata.protomaps.dev/builds.json}"
ARCHIVES="${OPENHIKES_VECTOR_ARCHIVES_CACHE:-$HOME/Library/Caches/OpenHikes/vector-archives}"
TAB=$'\t'
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/vector-archives.XXXXXX")"

# shellcheck source=lib/r2.sh
source "$REPO_ROOT/Scripts/lib/r2.sh"

usage() {
  sed -n '/^# Usage:/,/^#$/p' "${BASH_SOURCE[0]}" | sed '1d;$d' | sed 's/^#  /usage:/' >&2
  exit 2
}

die() {
  echo "vector-archives: $*" >&2
  exit 1
}

trap 'rm -rf "$SCRATCH"' EXIT

# One value of a JSON file, by key path (`basemaps.0.name`); an array's count.
value() {
  plutil -extract "$1" raw -o - "$2" 2>/dev/null
}

# Each archive a manifest names, a line each.
archive_names() {
  local list count index
  for list in basemaps extras; do
    count="$(value "$list" "$1")" || continue
    for (( index = 0; index < count; index++ )); do
      value "$list.$index.name" "$1"
    done
  done
}

# Whether the tile server serves an archive: its TileJSON answers.
served() {
  [[ "$(curl -s -o /dev/null -w "%{http_code}" "$SERVER/$1.json")" == 200 ]]
}

check() {
  [[ -f "$MANIFEST" ]] || die "no manifest at $MANIFEST"
  [[ "$(value version "$MANIFEST")" == 1 ]] || die "$MANIFEST is not a version 1 manifest"
  [[ "$(value revision "$MANIFEST")" =~ ^[1-9][0-9]*$ ]] || die "$MANIFEST has no revision"
  local names=() list count index name
  for list in basemaps extras; do
    count="$(value "$list" "$MANIFEST")" || die "$MANIFEST has no $list"
    for (( index = 0; index < count; index++ )); do
      name="$(value "$list.$index.name" "$MANIFEST")" || die "$list $index in $MANIFEST has no name"
      [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "'$name' is not a name the app reads"
      names+=("$name")
    done
  done
  (( $(value basemaps "$MANIFEST") > 0 )) || die "$MANIFEST names no basemap"
  local status missing=0
  for name in "${names[@]}"; do
    status="$(curl -s -o /dev/null -w "%{http_code}" "$SERVER/$name.json")"
    if [[ "$status" == 200 ]]; then
      echo "vector-archives: $SERVER has $name"
    else
      echo "vector-archives: $SERVER answered $status for $name" >&2
      missing=1
    fi
  done
  (( missing == 0 )) || die "upload every archive the manifest names before publishing it"
}

publish() {
  check
  r2_load_keys
  local revision live_revision status served_manifest="$SCRATCH/served.json"
  revision="$(value revision "$MANIFEST")"
  status="$(curl -s -o "$served_manifest" -w "%{http_code}" "$SERVER/manifest.json")"
  case "$status" in
    200)
      if cmp -s "$MANIFEST" "$served_manifest"; then
        echo "vector-archives: $SERVER already has revision $revision"
        return
      fi
      live_revision="$(value revision "$served_manifest")" || die "the manifest on $SERVER has no revision"
      (( revision > live_revision )) \
        || die "revision $revision is not above $live_revision, which $SERVER has; raise it"
      ;;
    404) ;;
    *) die "$SERVER answered $status for manifest.json" ;;
  esac
  status="$(r2_curl -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" -T "$MANIFEST" "$(r2_url manifest.json)")"
  [[ "$status" == 200 ]] || die "R2 answered $status to the upload"
  status="$(curl -s -o "$served_manifest" -w "%{http_code}" "$SERVER/manifest.json")"
  [[ "$status" == 200 ]] && cmp -s "$MANIFEST" "$served_manifest" \
    || die "uploaded, but $SERVER does not serve it back ($status)"
  echo "vector-archives: published revision $revision to $SERVER"
}

# `basemap [<YYYYMMDD>]`: Protomaps' build into the bucket, by way of the
# local copy the countries are cut from.
basemap() {
  local day="${1:-}"
  [[ -z "$day" || "$day" =~ ^[0-9]{8}$ ]] || usage
  local schema index_file="$SCRATCH/builds.json" count index key version size=""
  schema="$(value basemaps.0.schema "$MANIFEST")" || die "$MANIFEST names no basemap to take the schema from"
  curl -sf -o "$SCRATCH/builds.list" "$PROTOMAPS_INDEX" || die "could not read $PROTOMAPS_INDEX"
  # The index is a bare array, which plutil reads only under a key.
  { printf '{"builds":'; cat "$SCRATCH/builds.list"; printf '}'; } > "$index_file"
  count="$(value builds "$index_file")" || die "$PROTOMAPS_INDEX is not a list of builds"
  for (( index = count - 1; index >= 0; index-- )); do
    key="$(value "builds.$index.key" "$index_file")"
    version="$(value "builds.$index.version" "$index_file")"
    if [[ -n "$day" ]]; then
      [[ "$key" == "$day.pmtiles" ]] || continue
      [[ "${version%%.*}" == "$schema" ]] \
        || die "Protomaps built $day with basemaps $version, and the app reads schema $schema"
    else
      [[ "${version%%.*}" == "$schema" && "$key" =~ ^[0-9]{8}\.pmtiles$ ]] || continue
    fi
    size="$(value "builds.$index.size" "$index_file")"
    break
  done
  [[ -n "$size" ]] || die "Protomaps lists no ${day:-build} of schema $schema"
  day="${key%.pmtiles}"
  local name="planet-$day" head status etag length parts
  echo "vector-archives: Protomaps' $day build, basemaps $version, $size bytes"
  head="$(curl -sI "$PROTOMAPS/$key" | tr -d '\r')"
  status="$(printf '%s\n' "$head" | head -n 1 | awk '{print $2}')"
  [[ "$status" == 200 ]] || die "$PROTOMAPS answered ${status:-nothing} for $key"
  etag="$(printf '%s\n' "$head" | awk 'tolower($1) == "etag:" {gsub(/"/, "", $2); print $2}')"
  length="$(printf '%s\n' "$head" | awk 'tolower($1) == "content-length:" {print $2}')"
  [[ "$length" == "$size" ]] || die "$PROTOMAPS serves $key at $length bytes, and its index says $size"
  [[ "$etag" =~ ^[0-9a-f]{32}-([0-9]+)$ ]] \
    || die "$key's ETag ($etag) is not a multipart one, so the copy could not be held to it"
  parts="${BASH_REMATCH[1]}"
  # The part size Protomaps uploaded in, in whole MiB, as the parts' count
  # allows only one of.
  local mib=$(( 1024 * 1024 )) part_mib
  part_mib=$(( (size + parts * mib - 1) / (parts * mib) ))
  (( (size + part_mib * mib - 1) / (part_mib * mib) == parts )) \
    || die "$key's $parts parts are no whole number of MiB each"
  r2_load_keys
  if [[ "$(r2_etag "$name.pmtiles")" == "$etag" ]]; then
    echo "vector-archives: $R2_BUCKET already has $name as $etag"
  else
    local copy="$ARCHIVES/$name.pmtiles"
    download "$PROTOMAPS/$key" "$copy" "$size"
    r2_put_parts "$copy" "$name.pmtiles" "$part_mib" "$etag"
  fi
  echo "vector-archives: next, Scripts/vector-archives.sh use $name"
}

# A file of a known size, downloaded beside itself and resumed where a dropped
# connection left it, then moved into place once whole.
download() {
  local url="$1" file="$2" size="$3" partial="$2.part" attempt have
  if [[ -f "$file" && "$(stat -f %z "$file")" == "$size" ]]; then
    echo "vector-archives: $file is already here"
    return
  fi
  mkdir -p "$(dirname "$file")"
  for attempt in $(seq 1 "${OPENHIKES_DOWNLOAD_ATTEMPTS:-40}"); do
    have="$(stat -f %z "$partial" 2>/dev/null || echo 0)"
    (( have <= size )) || { rm -f "$partial"; have=0; }
    if (( have == size )); then
      mv "$partial" "$file"
      echo "vector-archives: downloaded $file"
      return
    fi
    echo "vector-archives: downloading $url from byte $have (attempt $attempt)"
    # A connection that stalls is dropped after a minute under 1 KB/s, and
    # the next attempt resumes where it was.
    curl -sSf -C - --speed-limit 1024 --speed-time 60 -o "$partial" "$url" || sleep 2
  done
  die "could not download $url whole"
}

# `use <name> [--schema <n> | --generation <n>]`
use() {
  [[ $# -eq 1 || $# -eq 3 ]] || usage
  local name="$1" list key override=""
  case "$name" in
    planet-*) list=basemaps key=schema ;;
    extras-*) list=extras key=generation ;;
    *) die "'$name' is neither a basemap (planet-…) nor extras (extras-…)" ;;
  esac
  if [[ $# -eq 3 ]]; then
    [[ "$2" == "--$key" && "$3" =~ ^[1-9][0-9]*$ ]] || usage
    override="$3"
  fi
  [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "'$name' is not a name the app reads"
  served "$name" || die "$SERVER does not serve $name; upload it first"
  [[ "$(value "$list.0.name" "$MANIFEST")" != "$name" ]] \
    || { echo "vector-archives: $name is already the manifest's first of its $list"; return; }
  local zoom_key=maximumZoom
  [[ "$list" == basemaps ]] || zoom_key=minimumZoom
  local level zoom
  level="${override:-$(value "$list.0.$key" "$MANIFEST")}" || die "$MANIFEST has no $list to take the $key from"
  zoom="$(value "$list.0.$zoom_key" "$MANIFEST")" || die "$MANIFEST has no $list to take the $zoom_key from"
  # The new archive first, then of the rest only the first of each schema
  # other than its own, or each generation earlier than its own: the builds
  # that would draw the rest draw the new one instead.
  local entries=("$name$TAB$level$TAB$zoom") seen=" $level " count index other other_level
  count="$(value "$list" "$MANIFEST")"
  for (( index = 0; index < count; index++ )); do
    other="$(value "$list.$index.name" "$MANIFEST")"
    other_level="$(value "$list.$index.$key" "$MANIFEST")"
    [[ "$other" != "$name" && "$seen" != *" $other_level "* ]] || continue
    [[ "$list" == basemaps ]] || (( other_level < level )) || continue
    seen+="$other_level "
    entries+=("$other$TAB$other_level$TAB$(value "$list.$index.$zoom_key" "$MANIFEST")")
  done
  local revision live_revision=0 basemaps extras
  revision="$(value revision "$MANIFEST")"
  case "$(curl -s -o "$SCRATCH/served.json" -w "%{http_code}" "$SERVER/manifest.json")" in
    200) live_revision="$(value revision "$SCRATCH/served.json")" || die "the manifest on $SERVER has no revision" ;;
    404) ;;
    *) die "$SERVER would not give its manifest, whose revision this one must pass" ;;
  esac
  (( revision > live_revision )) || revision=$(( live_revision + 1 ))
  if [[ "$list" == basemaps ]]; then
    basemaps="$(entry_lines basemaps schema maximumZoom "${entries[@]}")"
    extras="$(current_lines extras generation minimumZoom)"
  else
    basemaps="$(current_lines basemaps schema maximumZoom)"
    extras="$(entry_lines extras generation minimumZoom "${entries[@]}")"
  fi
  printf '{\n  "version": 1,\n  "revision": %s,\n  "basemaps": [\n%s\n  ],\n  "extras": [\n%s\n  ]\n}\n' \
    "$revision" "$basemaps" "$extras" > "$SCRATCH/manifest.json"
  mv "$SCRATCH/manifest.json" "$MANIFEST"
  echo "vector-archives: $name heads the $list at revision $revision; next, Scripts/vector-archives.sh publish"
}

# A list's entries as the manifest lays them out, from `name<TAB>level<TAB>zoom`.
entry_lines() {
  local key="$2" zoom_key="$3" line name level zoom separator=""
  shift 3
  for line in "$@"; do
    IFS=$'\t' read -r name level zoom <<< "$line"
    printf '%s    { "name": "%s", "%s": %s, "%s": %s }' "$separator" "$name" "$key" "$level" "$zoom_key" "$zoom"
    separator=$',\n'
  done
}

# A list as the manifest has it now.
current_lines() {
  local list="$1" key="$2" zoom_key="$3" entries=() count index
  count="$(value "$list" "$MANIFEST")" || count=0
  for (( index = 0; index < count; index++ )); do
    entries+=("$(value "$list.$index.name" "$MANIFEST")$TAB$(value "$list.$index.$key" "$MANIFEST")$TAB$(value "$list.$index.$zoom_key" "$MANIFEST")")
  done
  (( count == 0 )) || entry_lines "$list" "$key" "$zoom_key" "${entries[@]}"
}

# `prune [--dry-run]`
prune() {
  local dry_run=false
  [[ $# -eq 0 ]] || { [[ $# -eq 1 && "$1" == --dry-run ]] || usage; dry_run=true; }
  local served_manifest="$SCRATCH/served.json" status
  status="$(curl -s -o "$served_manifest" -w "%{http_code}" "$SERVER/manifest.json")"
  [[ "$status" == 200 ]] || die "$SERVER answered $status for manifest.json; prune nothing without it"
  local kept name
  kept=" $(archive_names "$served_manifest" | tr '\n' ' ') $(archive_names "$MANIFEST" | tr '\n' ' ') "
  r2_load_keys
  local objects key bytes doomed=0
  objects="$(r2_list "" /)"
  for name in $(archive_names "$served_manifest"); do
    grep -q "^$name\.pmtiles$TAB" <<< "$objects" \
      || die "$SERVER's manifest names $name, which $R2_BUCKET does not hold; prune nothing until it does"
  done
  while IFS=$'\t' read -r key bytes; do
    [[ "$key" == *.pmtiles ]] || continue
    name="${key%.pmtiles}"
    [[ "$kept" != *" $name "* ]] || continue
    doomed=$(( doomed + 1 ))
    if [[ "$dry_run" == true ]]; then
      echo "vector-archives: would delete $key ($bytes bytes)"
    else
      r2_delete "$key"
      echo "vector-archives: deleted $key ($bytes bytes)"
    fi
  done <<< "$objects"
  (( doomed > 0 )) || echo "vector-archives: $R2_BUCKET holds only archives a manifest names"
}

[[ $# -ge 1 ]] || usage
COMMAND="$1"
shift
case "$COMMAND" in
  basemap) [[ $# -le 1 ]] || usage; basemap "$@" ;;
  use) use "$@" ;;
  check) [[ $# -eq 0 ]] || usage; check ;;
  publish) [[ $# -eq 0 ]] || usage; publish ;;
  prune) prune "$@" ;;
  *) usage ;;
esac
