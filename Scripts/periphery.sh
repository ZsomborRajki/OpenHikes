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
# **It builds the index itself, into a folder of this checkout's own**, and
# hands Periphery that index with `--index-store-path`. Left to build on its
# own, Periphery puts every scan of this project in the same
# `~/Library/Caches/com.github.peripheryapp/DerivedData-<hash>`, and the hash
# is of neither the checkout's path nor the build arguments — measured with
# 3.8.0, an absolute `--project` and an extra build setting both land in the
# same folder as a bare scan. The index store in there keeps the units of
# every checkout that ever scanned into it, and Periphery reads all of them:
# a scan of one worktree reported 135 unused declarations in files that
# existed only in another checkout's copy of `main`, and a reference kept
# alive by another checkout's code hides a finding just as silently. Two
# sessions scanning at once would also be building into one derived-data
# folder, which stalls rather than fails. `.build/periphery` is gitignored,
# hidden from SwiftLint's `**/.*` exclude, and goes when the worktree does.
#
# Exit status:
#   0  the scan ran against .periphery.yml; anything it found is above
#   1  the build failed, Periphery could not run, or it ran without reading
#      .periphery.yml
#   2  an option this script does not take
#
# `Scripts/periphery.sh --help` prints the options.
#
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
    cat <<'EOF'
Usage: Scripts/periphery.sh [--exclude-tests] [--derived-data <path>]

Scans for unreferenced declarations with the configuration in .periphery.yml,
at the version pinned in .periphery-version. Findings are candidates to read,
not a verdict — see the comments in .periphery.yml before acting on one.

Options:
  --derived-data <path>
                  Build the index here rather than in .build/periphery. Each
                  checkout needs its own: Periphery reads every unit in the
                  index store it is given, whichever checkout wrote it
  --exclude-tests Report the declarations only the tests reach, at the cost of
                  listing every deliberate test seam alongside them
  -h, --help      Show this help

Exit status:
  0   the scan ran against .periphery.yml; anything it found is above
  1   the build failed, Periphery could not run, or it ran without reading
      .periphery.yml

The scan builds the project with indexing enabled into .build/periphery, this
checkout's own folder, and takes minutes on a cold one, which is why it is
neither part of the build nor of CI.
EOF
}

exclude_tests=false
show_help=false
derived_data=".build/periphery"
# Every argument, not just the first, and --help only after the whole line has
# been read — the rule Scripts/lint.sh follows, for the reason it gives.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --exclude-tests)
            exclude_tests=true
            shift
            ;;
        --derived-data)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "error: --derived-data needs a path." >&2
                usage >&2
                exit 2
            fi
            derived_data="$2"
            shift 2
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

index_store="$derived_data/Index.noindex/DataStore"
scan_arguments=(scan --quiet --disable-update-check --index-store-path "$index_store")
if [[ "$exclude_tests" == true ]]; then
    scan_arguments+=(--exclude-tests)
fi

echo "Building the index into $derived_data. This takes minutes on a cold folder."

# Periphery's own build, as 3.8.0 runs it, pointed at this checkout's folder.
# The settings after `build-for-testing` are the ones Periphery adds to turn
# indexing on and signing off. The last three are this project's:
#
#   - `-skipPackagePluginValidation`, because a fresh derived-data folder
#     re-resolves packages and hits the SwiftLintPlugins fingerprint check that
#     every xcodebuild call in .github/workflows/ci.yml has to skip. Without it
#     the build fails before anything is indexed.
#   - The simulator destination, because with none xcodebuild resolves the
#     scheme against "Any iOS Device" and then cannot find a test host for
#     OpenWidgetTests, which is built for the simulator like everything else
#     here.
#
# The log goes to a file, because the build's warnings (every SwiftLint
# warning the build-tool plugin prints among them) are not what this script
# reports on, and a failed build is shown from its tail.
build_log="$derived_data/periphery-build.log"
mkdir -p "$derived_data"
set +e
xcodebuild -project OpenHikes.xcodeproj -scheme OpenHikes -parallelizeTargets \
    -derivedDataPath "$derived_data" -quiet build-for-testing \
    CODE_SIGNING_ALLOWED=NO ENABLE_BITCODE=NO DEBUG_INFORMATION_FORMAT=dwarf \
    COMPILER_INDEX_STORE_ENABLE=YES INDEX_ENABLE_DATA_STORE=YES \
    -skipPackagePluginValidation -destination 'generic/platform=iOS Simulator' \
    > "$build_log" 2>&1
build_status=$?
set -e

if [[ "$build_status" != 0 ]]; then
    tail -n 40 "$build_log" >&2
    echo "error: the build Periphery reads its index from failed (exit $build_status)." >&2
    echo "       Nothing was scanned. The whole log is $build_log." >&2
    exit 1
fi

echo "Scanning with periphery $installed."

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
