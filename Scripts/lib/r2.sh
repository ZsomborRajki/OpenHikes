#!/usr/bin/env bash
#
# The R2 bucket `openhikes-tiles`, through its S3 endpoint, sourced by
# Scripts/vector-archives.sh and Scripts/offline-countries.sh. Not executable
# on its own.
#
# Every request is signed with the bucket's S3 keys, read from
# OPENHIKES_R2_ENV (default ~/.config/openhikes/r2-openhikes-tiles.env:
# R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET), by curl's
# own Signature Version 4 with an unsigned payload, as Scripts/vector-extras.sh
# signs its upload.
#
# A file of up to 5 GiB goes up in one request (`r2_put`). A larger one, a
# basemap of the planet or the extras, goes up in parts (`r2_put_parts`), and
# comes out under the ETag S3 gives a multipart object: the MD5 of its parts'
# MD5s and their count. Cut in the parts its source was uploaded in, the same
# file carries the source's ETag, which is what lets a copy of Protomaps' build
# be held to Protomaps' own, end to end, without reading it back.
#
# OPENHIKES_R2_MIB_PER_SECOND caps how fast the bucket is sent to and read
# from, in MiB a second, so a world of uploads leaves the connection usable.
# Parts sent side by side share the cap.

# The caller's own `die` reports, so a failure here reads as the caller's.
r2_fail() {
    if declare -F die >/dev/null; then
        die "$1"
    fi
    echo "r2: $1" >&2
    exit 1
}

r2_load_keys() {
    local env_file="${OPENHIKES_R2_ENV:-$HOME/.config/openhikes/r2-openhikes-tiles.env}"
    [[ -f "$env_file" ]] || r2_fail "no R2 keys at $env_file"
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
    R2_RATE_BYTES=""
    if [[ -n "${OPENHIKES_R2_MIB_PER_SECOND:-}" ]]; then
        [[ "$OPENHIKES_R2_MIB_PER_SECOND" =~ ^[1-9][0-9]*$ ]] \
            || r2_fail "OPENHIKES_R2_MIB_PER_SECOND is $OPENHIKES_R2_MIB_PER_SECOND, not a whole number of MiB"
        R2_RATE_BYTES=$(( OPENHIKES_R2_MIB_PER_SECOND * 1024 * 1024 ))
    fi
}

# The S3 URL of a key, or of the bucket itself for none.
r2_url() {
    printf 'https://%s.r2.cloudflarestorage.com/%s%s\n' "$R2_ACCOUNT_ID" "$R2_BUCKET" "${1:+/$1}"
}

r2_curl() {
    local rate=()
    [[ -z "${R2_RATE_BYTES:-}" ]] || rate=(--limit-rate "$R2_RATE_BYTES")
    curl -s --aws-sigv4 "aws:amz:auto:s3" --user "$R2_ACCESS_KEY_ID:$R2_SECRET_ACCESS_KEY" \
        -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" ${rate[@]+"${rate[@]}"} "$@"
}

# A PUT to the bucket, asked again when R2 answers a server error or the
# connection fails: across a world of uploads, a 500 now and then is R2's.
# Prints the last status. A retry after an attempt that did land meets
# If-None-Match and answers 412, which the caller settles by the digest.
r2_put() {
    local attempt status
    for attempt in 1 2 3 4; do
        status="$(r2_curl -o /dev/null -w "%{http_code}" "$@")"
        case "$status" in
            5??|000) sleep $(( attempt * ${OPENHIKES_R2_RETRY_SECONDS:-2} )) ;;
            *) break ;;
        esac
    done
    printf '%s\n' "$status"
}

# A key's ETag, unquoted, or nothing when the bucket has no such key. Fails
# on any other answer.
r2_etag() {
    local head status
    head="$(r2_curl -I "$(r2_url "$1")" | tr -d '\r')"
    status="$(printf '%s\n' "$head" | head -n 1 | awk '{print $2}')"
    case "$status" in
        200) printf '%s\n' "$head" | awk 'tolower($1) == "etag:" {gsub(/"/, "", $2); print $2}' ;;
        404) ;;
        *) r2_fail "R2 answered ${status:-nothing} when asked for $1" ;;
    esac
}

# Every key under a prefix and its size, a line each (`key<TAB>bytes`); with a
# second argument of `/`, only those directly under it, not those in the
# folders below.
r2_list() {
    local prefix="$1" delimiter="${2:-}" token="" page query
    while :; do
        query="list-type=2&prefix=$(r2_encode "$prefix")"
        [[ -z "$delimiter" ]] || query="$query&delimiter=$(r2_encode "$delimiter")"
        [[ -z "$token" ]] || query="$query&continuation-token=$(r2_encode "$token")"
        page="$(r2_curl -f "$(r2_url)?$query")" || r2_fail "R2 would not list $prefix"
        # One element a line: a key is followed by its size, and an S3 key
        # holds no `<`, which XML escapes.
        printf '%s\n' "$page" | tr '<' '\n' | awk -F '>' '$1 == "Key" { key = $2 } $1 == "Size" { print key "\t" $2 }'
        token="$(printf '%s\n' "$page" | tr '<' '\n' | awk -F '>' '$1 == "NextContinuationToken" { print $2 }')"
        [[ -n "$token" ]] || break
    done
}

r2_delete() {
    local status
    status="$(r2_curl -o /dev/null -w "%{http_code}" -X DELETE "$(r2_url "$1")")"
    [[ "$status" == 204 || "$status" == 200 ]] || r2_fail "R2 answered $status to deleting $1"
}

# A query value, percent-encoded as S3 signs it.
r2_encode() {
    local value="$1" encoded="" character index
    for (( index = 0; index < ${#value}; index++ )); do
        character="${value:index:1}"
        case "$character" in
            [A-Za-z0-9._~-]) encoded+="$character" ;;
            *) encoded+="$(printf '%%%02X' "'$character")" ;;
        esac
    done
    printf '%s\n' "$encoded"
}

# `r2_put_parts <file> <key> <part MiB> [<ETag>]`: the file under the key, in
# parts of that many MiB sent OPENHIKES_R2_PARALLEL (8) at a time, each held
# to its own MD5 as it lands. With an ETag, the parts' own must come to it
# before the upload is completed, or the upload is abandoned and nothing is
# written. A key already holding that ETag is left as it is; one holding
# anything else is refused, since an archive is never replaced in place. The
# upload is completed on condition that the key is still free
# (`If-None-Match: *`), which R2 checks as the write commits, so of two
# uploads to one key that both found it free, the second is refused rather
# than written over the first.
r2_put_parts() {
    local file="$1" key="$2" part_mib="$3" expected="${4:-}"
    local size part_bytes parts existing url created upload_id work etag combined body number status
    [[ -f "$file" ]] || r2_fail "no file at $file"
    size="$(stat -f %z "$file")"
    part_bytes=$(( part_mib * 1024 * 1024 ))
    parts=$(( (size + part_bytes - 1) / part_bytes ))
    (( parts <= 10000 )) || r2_fail "$file needs $parts parts of $part_mib MiB, and S3 takes 10,000"
    existing="$(r2_etag "$key")"
    if [[ -n "$existing" ]]; then
        [[ -n "$expected" && "$existing" == "$expected" ]] \
            || r2_fail "$key is already in $R2_BUCKET as $existing; upload under a new name"
        echo "r2: $key is already in $R2_BUCKET as $existing"
        return
    fi
    url="$(r2_url "$key")"
    created="$(r2_curl -f -X POST "$url?uploads")" || r2_fail "R2 would not start an upload of $key"
    upload_id="$(printf '%s\n' "$created" | sed -nE 's:.*<UploadId>([^<]+)</UploadId>.*:\1:p')"
    [[ -n "$upload_id" ]] || r2_fail "R2 started an upload of $key without naming it"
    url="$url?uploadId=$(r2_encode "$upload_id")"
    work="$(mktemp -d "${TMPDIR:-/tmp}/r2-parts.XXXXXX")"
    echo "r2: sending $key in $parts parts of $part_mib MiB"
    local parallel="${OPENHIKES_R2_PARALLEL:-8}" part_rate=""
    [[ -z "${R2_RATE_BYTES:-}" ]] || part_rate=$(( R2_RATE_BYTES / parallel ))
    export -f r2_curl _r2_put_part
    export R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY OPENHIKES_R2_RETRY_SECONDS
    if ! seq 1 "$parts" | R2_RATE_BYTES="$part_rate" xargs -P "$parallel" -I {} \
        bash -c '_r2_put_part "$@" || exit 255' _ "$file" "$url" "$part_mib" {} "$work" "$parts"; then
        _r2_abandon "$url" "$work"
        r2_fail "the upload of $key stopped; nothing was written"
    fi
    combined="$(for (( number = 1; number <= parts; number++ )); do cat "$work/$number.md5"; done \
        | tr -d '\n' | xxd -r -p | md5 -q)-$parts"
    if [[ -n "$expected" && "$combined" != "$expected" ]]; then
        _r2_abandon "$url" "$work"
        r2_fail "$file comes to $combined in parts of $part_mib MiB, not $expected; nothing was written"
    fi
    body="<CompleteMultipartUpload>"
    for (( number = 1; number <= parts; number++ )); do
        body+="<Part><PartNumber>$number</PartNumber><ETag>\"$(cat "$work/$number.md5")\"</ETag></Part>"
    done
    body+="</CompleteMultipartUpload>"
    status="$(r2_curl -o /dev/null -w "%{http_code}" -X POST -H "If-None-Match: *" \
        -H "Content-Type: application/xml" --data-binary "$body" "$url")"
    if [[ "$status" != 200 ]]; then
        _r2_abandon "$url" "$work"
        [[ "$status" != 412 ]] || r2_fail "$key reached $R2_BUCKET from another upload first; upload under a new name"
        r2_fail "R2 answered $status to completing the upload of $key"
    fi
    rm -rf "$work"
    etag="$(r2_etag "$key")"
    [[ "$etag" == "$combined" ]] || r2_fail "$key is in $R2_BUCKET as ${etag:-nothing}, not $combined"
    echo "r2: uploaded $key ($size bytes) as $etag"
}

# An upload left uncompleted keeps its parts, unseen and billed, until R2
# expires them, so one that fails is abandoned at once.
_r2_abandon() {
    r2_curl -o /dev/null -X DELETE "$1" || true
    rm -rf "$2"
}

# One part: copied out of the file, sent until R2 names it by the MD5 it has
# here, and its MD5 kept for the whole's. A send that stalls is given up
# after a quarter of an hour and sent again.
_r2_put_part() {
    local file="$1" url="$2" part_mib="$3" number="$4" work="$5" parts="$6"
    local piece="$work/$number.part" md5 etag attempt
    dd if="$file" of="$piece" bs=1048576 skip=$(( (number - 1) * part_mib )) count="$part_mib" 2>/dev/null \
        || return 1
    md5="$(md5 -q "$piece")"
    for attempt in 1 2 3 4; do
        etag="$(r2_curl -o /dev/null -D - --max-time 900 -T "$piece" "$url&partNumber=$number" | tr -d '\r' \
            | awk 'tolower($1) == "etag:" {gsub(/"/, "", $2); print $2}')"
        [[ "$etag" != "$md5" ]] || break
        sleep $(( attempt * ${OPENHIKES_R2_RETRY_SECONDS:-2} ))
    done
    rm -f "$piece"
    if [[ "$etag" != "$md5" ]]; then
        echo "r2: part $number of $parts did not land" >&2
        return 1
    fi
    printf '%s\n' "$md5" > "$work/$number.md5"
    echo "r2: part $number of $parts"
}
