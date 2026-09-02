#!/bin/bash
#
# Runs Periphery's unused-code scan against .periphery.yml, at the version
# pinned in .periphery-version, and fails when the scan did not read that file.
#
# The scan itself is not a pass/fail signal — .periphery.yml says why, and this
# script exits 0 whether or not it found anything. What it does decide is
# whether the run was a report at all. Periphery treats a configuration it does
# not understand as a warning and scans on regardless, which is the same shape
# `Scripts/lint.sh` guards against for `.swiftlint.yml`: a run that read none of
# the configuration still prints a tidy result, and on this project it prints
# the tidiest one there is.
#
# The version check is an error rather than the warning `Scripts/lint.sh`
# settles for, because Periphery 2.x does not read this configuration in three
# ways at once and stays silent about the worst of them:
#
#   - `--targets` was still required for an .xcodeproj, so a bare scan aborts.
#   - `retain_equatable_properties` and `retain_hashable_properties` did not
#     exist until 3.8.0. 2.x reports both as `invalid key` and drops them.
#   - Every target in OpenHikes.xcodeproj is an Xcode synchronized folder group
#     rather than a list of file references. 2.x cannot enumerate one, so with
#     `--targets` supplied by hand it indexes no Swift file in OpenHikes or
#     OpenWidgetExtension at all and reports "No unused code detected" having
#     read none of the code.
#
# Exit status:
#   0  the scan ran against .periphery.yml; anything it found is above
#   1  Periphery could not run, or ran without reading .periphery.yml
#
# `Scripts/periphery.sh --help` prints the options.
#
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
    cat <<'EOF'
Usage: Scripts/periphery.sh [--exclude-tests]

Scans for unreferenced declarations with the configuration in .periphery.yml,
at the version pinned in .periphery-version. Findings are candidates to read,
not a verdict — see the comments in .periphery.yml before acting on one.

Options:
  --exclude-tests Report the declarations only the tests reach, at the cost of
                  listing every deliberate test seam alongside them
  -h, --help      Show this help

Exit status:
  0   the scan ran against .periphery.yml; anything it found is above
  1   Periphery could not run, or ran without reading .periphery.yml

The scan rebuilds the project with indexing enabled and takes minutes, which is
why it is neither part of the build nor of CI.
EOF
}

exclude_tests=false
show_help=false
# Every argument, not just the first, and --help only after the whole line has
# been read — the rule Scripts/lint.sh follows, for the reason it gives.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --exclude-tests)
            exclude_tests=true
            shift
            ;;
        -h|--help)
            show_help=true
            shift
            ;;
        *)
            echo "error: unknown option '$1'." >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$show_help" == true ]]; then
    usage
    exit 0
fi

pinned="$(cat .periphery-version)"

if ! command -v periphery >/dev/null 2>&1; then
    echo "error: periphery is not installed. Expected version $pinned or newer." >&2
    echo "       brew install periphery" >&2
    exit 1
fi

installed="$(periphery version)"
if [[ "$installed" != "$pinned" ]]; then
    oldest="$(printf '%s\n%s\n' "$installed" "$pinned" | sort -V | head -1)"
    if [[ "$oldest" == "$installed" ]]; then
        echo "error: periphery $installed installed, but .periphery.yml needs $pinned or newer." >&2
        echo "       $installed reads none of this configuration and still reports a" >&2
        echo "       result — on this project, a clean one it reached without indexing" >&2
        echo "       a single Swift file. brew upgrade periphery." >&2
        exit 1
    fi
    # Newer than the pin is only a warning: a release can add findings, and the
    # report is read rather than enforced.
    echo "warning: periphery $installed installed, .periphery-version names $pinned." >&2
fi

scan_arguments=(scan --quiet --disable-update-check)
if [[ "$exclude_tests" == true ]]; then
    scan_arguments+=(--exclude-tests)
fi

echo "Scanning with periphery $installed. This rebuilds the project and takes minutes."

# Outside `set -e` so a build that failed can be told apart from a scan that
# ran: both leave Periphery's own diagnostics in the output, and only the second
# is a report about this project's code.
set +e
output="$(periphery "${scan_arguments[@]}" 2>&1)"
status=$?
set -e

if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
fi

if grep -qE "invalid key|Unknown option '|option is required" <<<"$output"; then
    echo "error: Periphery did not read .periphery.yml as written (see above)." >&2
    echo "       It scans on with whatever it did understand, so neither a finding" >&2
    echo "       nor a clean result here means anything. Fix the config." >&2
    exit 1
fi

if [[ "$status" != 0 ]]; then
    echo "error: Periphery could not complete the scan (exit $status). This is not a" >&2
    echo "       report about the code — nothing was analysed." >&2
    exit 1
fi

echo "Periphery scan complete ($installed). Read a finding before acting on it."
