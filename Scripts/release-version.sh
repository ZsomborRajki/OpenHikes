#!/usr/bin/env bash
#
# Decides the version and build number a TestFlight upload carries, and the
# tag that names it.
#
# The version is the person's: they type it into the TestFlight workflow. The
# build is not, because App Store Connect refuses a build number no higher
# than one it already has for that version, and nothing in this repository
# asks it which those are. So the build is one past the highest this
# repository knows for the same version: its `v<version>-<build>` tags
# (*Releasing* in AGENTS.md tags every archived commit) and any
# `CURRENT_PROJECT_VERSION` committed beside that `MARKETING_VERSION` in the
# project, whichever is higher. A build uploaded from Xcode and never tagged
# is invisible here. App Store Connect then refuses the upload by name, and
# `--build` is the way past it.
#
# Each version starts again at build 1, by the owner's choice. App Store
# Connect allows it for an iOS app, whose builds have to climb only within a
# version (Apple's TN2420), and this app's uploads from Xcode restarted at 1
# the same way. A Mac app's builds would have to keep climbing across
# versions.
#
# A `--build` has to beat the same highest build. One that does not is
# refused here, naming the next free build, because App Store Connect would
# refuse it only after the archive. A build chosen past an untagged upload is
# above everything known here too. When the project cannot be read, no build
# is picked, since one could fall at or below a committed build, but a
# `--build` is still taken, checked against the version's tags alone.
#
# The tag must not exist yet. Two uploads cannot share one, and a tag that
# moved would map an Organizer crash report to the wrong revision.
#
# Prints three `name=value` lines, the shape `$GITHUB_OUTPUT` takes:
#   version=1.5
#   build=7
#   tag=v1.5-7
#
# Exit status:
#   0  the version and build are usable, and the tag is free
#   1  the tag already exists, the build is no higher than one the version
#      has, or no build could be chosen
#   2  a usage error: a missing or malformed version or build

set -euo pipefail

default_project="OpenHikes.xcodeproj/project.pbxproj"

usage() {
    cat <<EOF
Usage: Scripts/release-version.sh --version <version> [--build <number>] [--project <pbxproj>]

Prints the version, build number and tag a TestFlight upload carries.

Options:
  --version <version>  The marketing version, one to three numbers (1.5, 1.5.1)
  --build <number>     The build number (default: one past the highest build
                       tagged or committed for this version, or 1)
  --project <pbxproj>  The project whose committed build counts
                       (default: $default_project)
  -h, --help           Show this help
EOF
}

version=""
build=""
project="$default_project"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|--build|--project)
            if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
                echo "error: missing value for $1." >&2
                exit 2
            fi
            case "$1" in
                --version) version="$2" ;;
                --build) build="$2" ;;
                --project) project="$2" ;;
            esac
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

if [[ -z "$version" ]]; then
    echo "error: --version is required." >&2
    usage >&2
    exit 2
fi

# What `CFBundleShortVersionString` accepts, without leading zeros: "1.05"
# would read as 1.5 in one place and as itself in the tag.
number='(0|[1-9][0-9]*)'
if [[ ! "$version" =~ ^$number(\.$number){0,2}$ ]]; then
    echo "error: '$version' is not a version. Use one to three numbers, such as 1.5 or 1.5.1." >&2
    exit 2
fi

if [[ -n "$build" && ! "$build" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: '$build' is not a build number. Use a whole number above zero." >&2
    exit 2
fi

# Tags are read from the repository holding the project, so a fixture
# repository can stand in for this one.
repository="$(dirname "$project")"
if ! tags="$(git -C "$repository" tag --list 'v*' 2>&1)"; then
    echo "error: could not read the tags beside $project: $tags" >&2
    exit 1
fi

# The highest build this repository knows for the version and where it is
# written, and why the project cannot say, if it cannot.
highest=0
highest_from=""
unreadable=""
if [[ ! -f "$project" ]]; then
    unreadable="$project does not exist"
else
    # Each build configuration commits a version and a build together, and an
    # archive from Xcode carries the pair, so a committed build counts only
    # beside the version being shipped. The four shipping targets should
    # agree; if they do not, the highest is the one an upload has to beat.
    setting='^[[:space:]]*(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = "?([^";]*)"?;'
    settings_end='^[[:space:]]*};'
    configurations=0
    committed_version=""
    committed_build=""
    while IFS= read -r line; do
        if [[ "$line" =~ $setting ]]; then
            case "${BASH_REMATCH[1]}" in
                MARKETING_VERSION) committed_version="${BASH_REMATCH[2]}" ;;
                CURRENT_PROJECT_VERSION) committed_build="${BASH_REMATCH[2]}" ;;
            esac
        elif [[ "$line" =~ $settings_end ]]; then
            if [[ -n "$committed_version" && -n "$committed_build" ]]; then
                configurations=$(( configurations + 1 ))
                if [[ "$committed_version" == "$version" ]]; then
                    if [[ ! "$committed_build" =~ ^[0-9]+$ ]]; then
                        unreadable="$project has CURRENT_PROJECT_VERSION = $committed_build beside $version, which is not a whole number"
                        break
                    fi
                    if (( 10#$committed_build > highest )); then
                        highest="$(( 10#$committed_build ))"
                        highest_from="committed in $project"
                    fi
                fi
            fi
            committed_version=""
            committed_build=""
        fi
    done < "$project"
    if [[ -z "$unreadable" ]] && (( configurations == 0 )); then
        unreadable="$project commits no MARKETING_VERSION beside a CURRENT_PROJECT_VERSION"
    fi
fi
if [[ -n "$unreadable" ]]; then
    if [[ -z "$build" ]]; then
        echo "error: $unreadable. Pass --build." >&2
        exit 1
    fi
    echo "warning: $unreadable, so build $build is checked against $version's tags alone." >&2
    highest=0
    highest_from=""
fi
# Only this version's tags of the shape this script makes count. Anything
# else — a `v2-beta`, a `vacation`, another version's tag — names no build
# of it.
while IFS= read -r tag; do
    tagged="${tag#"v$version-"}"
    if [[ "$tagged" != "$tag" && "$tagged" =~ ^[0-9]+$ ]] && (( 10#$tagged > highest )); then
        highest="$(( 10#$tagged ))"
        highest_from="tagged $tag"
    fi
done <<< "$tags"
next="$(( highest + 1 ))"
if [[ -z "$build" ]]; then
    build="$next"
fi

tag="v$version-$build"
if git -C "$repository" rev-parse -q --verify "refs/tags/$tag" > /dev/null; then
    echo "error: $tag already exists, so $version ($build) was uploaded before. The next free build is $next." >&2
    exit 1
fi
# More digits is higher, since a build has no leading zero. Shell arithmetic
# would wrap a build past 2^63 instead, and could find it lower.
if (( ${#build} <= ${#highest} && build <= highest )); then
    echo "error: $version already has build $highest, $highest_from, so App Store Connect would refuse $version ($build) after the archive. The next free build is $next." >&2
    exit 1
fi

printf 'version=%s\nbuild=%s\ntag=%s\n' "$version" "$build" "$tag"
