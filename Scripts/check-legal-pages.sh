#!/usr/bin/env bash
#
# Checks that every page of the published site the app links to is published
# from `docs/`, in its own language, and that each translation takes effect
# with its original.
#
# The app opens the privacy policy and the terms in its own language
# (`MapPurchaseLinks.PageLanguage`), and GitHub Pages serves `docs/` at
# `/OpenHikes/`, so each of those links is a file in this checkout: a folder's
# page is its `index.html`. The cost of publishing two copies is the one
# nobody updates — the English page changes, and the German goes on promising
# what the app no longer does — so each page states the date it took effect in
# a single `<time datetime>`, and a translation has to state its original's.
#
# A script rather than a suite, because the mistakes it catches are made in
# pull requests that touch nothing but `docs/`, and those skip every job that
# builds the app (*CI* in `AGENTS.md`). It needs bash and grep, so its job
# runs on every pull request in seconds.
#
# The pages it checks are the ones the app links: every quoted
# `https://zsomborrajki.github.io/OpenHikes/…` URL in
# `OpenHikes/Purchases/MapPurchaseLinks.swift`. `MapPurchaseLinksTests` holds
# each `PageLanguage` URL to a literal there, so the list cannot leave out a
# page the app opens. A linked path whose first folder, taken off, leaves
# another linked path is that path's translation into the language the folder
# names (`de/privacy/` translates `privacy/`); every other linked page is an
# original, in English, the language of the site's root.
#
# Exit status:
#   0  every linked page is published, in its language, with its original's date
#   1  a page is missing, mislabelled or out of date, or no link was found
#   2  usage error

set -euo pipefail

site_url="https://zsomborrajki.github.io/OpenHikes/"
links_file="OpenHikes/Purchases/MapPurchaseLinks.swift"
original_language="en"

usage() {
    cat <<EOF
Usage: Scripts/check-legal-pages.sh [--root <dir>]

Checks that every page the app links on ${site_url} is published from
docs/ in its own language, and that each translation carries its original's
effective date.

Options:
  --root <dir>  The checkout to read ${links_file} and docs/ from
                (default: the repository this script is in)
  -h, --help    Show this help
EOF
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo "error: --root needs a directory" >&2; exit 2; }
            root="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ ! -f "$root/$links_file" ]]; then
    echo "error: $root/$links_file does not exist, so there is nothing to say which pages the app links." >&2
    exit 1
fi

# The path under the site of each quoted URL, such as `de/privacy/`. A URL
# built some other way would be missed, which is why the suite holds every
# `PageLanguage` URL to a literal here.
linked=()
while IFS= read -r path; do
    linked+=("$path")
done < <(grep -o "\"${site_url}[^\"]*\"" "$root/$links_file" \
    | sed -e "s|^\"${site_url}||" -e 's|"$||' | sort -u)

if [[ ${#linked[@]} -eq 0 ]]; then
    echo "error: $links_file links no page on $site_url; read it before trusting a pass here." >&2
    exit 1
fi

is_linked() {
    local candidate="$1" path
    for path in "${linked[@]}"; do
        [[ "$path" == "$candidate" ]] && return 0
    done
    return 1
}

problems=0
problem() {
    echo "  FAIL  $1" >&2
    problems=$(( problems + 1 ))
}

# The `datetime` of the page's one `<time>` element, or nothing when the page
# states none or more than one.
effective_date() {
    local file="$1" dates
    dates="$(grep -o '<time datetime="[^"]*"' "$file" | sed -e 's/^<time datetime="//' -e 's/"$//' || true)"
    if [[ -n "$dates" && "$(printf '%s\n' "$dates" | wc -l | tr -d ' ')" == 1 ]]; then
        printf '%s' "$dates"
    fi
}

for path in "${linked[@]}"; do
    before=$problems
    file="docs/${path}index.html"
    first="${path%%/*}"
    rest="${path#*/}"
    if [[ "$path" == */* && -n "$rest" ]] && is_linked "$rest"; then
        language="$first"
        original="docs/${rest}index.html"
    else
        language="$original_language"
        original=""
    fi

    if [[ ! -f "$root/$file" ]]; then
        problem "$file is missing, and the app links ${site_url}${path}"
        continue
    fi

    if ! grep -q "<html lang=\"${language}\">" "$root/$file"; then
        problem "$file is not marked <html lang=\"${language}\">"
    fi

    date="$(effective_date "$root/$file")"
    if [[ -z "$date" ]]; then
        problem "$file should state exactly one effective date in a <time datetime>"
        continue
    fi

    if [[ -n "$original" && -f "$root/$original" ]]; then
        original_date="$(effective_date "$root/$original")"
        # An original with no single date is reported on its own pass.
        if [[ -n "$original_date" && "$date" != "$original_date" ]]; then
            problem "$file takes effect $date, and its original $original took effect $original_date; update the translation with it"
        fi
    fi

    (( problems > before )) || echo "  ok    $file ($language, $date)"
done

if (( problems > 0 )); then
    echo "$problems problem(s) with the pages the app links." >&2
    exit 1
fi
echo "Every page the app links is published in its language, with its original's date."
