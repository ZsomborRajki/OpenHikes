#!/bin/bash
#
# Runs the same SwiftLint the CI `quality` job runs, at the same pinned
# version and with the same flags.
#
# It exists because that job is the one that keeps breaking `main`. The Xcode
# build does lint — SwiftLintBuildToolPlugin is attached to OpenHikes,
# OpenWidgetExtension, OpenHikesWatch, OpenHikesTests and OpenWidgetTests — but
# it runs `swiftlint lint --quiet --force-exclude` with no `--strict`, so it
# only stops a build on a violation the configuration marks `error`. Every
# warning-severity rule is invisible there and would otherwise show up for the
# first time in CI, ten minutes after the push. The version is the
# SwiftLintPlugins pin in the project's Package.resolved, which is the
# SwiftLint that plugin runs. This script reads it, and
# `.github/workflows/ci.yml` asks this script for it (`--pinned-version`), so
# the three cannot drift, and the bump Dependabot opens for the plugin moves
# all of them.
#
# Exit status:
#   0  clean
#   2  SwiftLint ran and found violations
#   1  SwiftLint could not run, or did not run against this configuration
#
# `Scripts/lint.sh --help` prints the options.
#
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
    cat <<'EOF'
Usage: Scripts/lint.sh [--fix | --pinned-version]

Runs strict SwiftLint over the roots .swiftlint.yml includes, at the
version Package.resolved pins for SwiftLintPlugins. The CI `quality` job runs
this same script, so a clean run here is a clean run there.

Options:
  --fix              Apply the violations SwiftLint can correct, then re-lint
  --pinned-version   Print the pinned version and exit, without linting
  -h, --help         Show this help

Exit status:
  0   clean
  2   SwiftLint ran and found violations
  1   SwiftLint could not run, or did not run against this configuration

The Xcode build lints too, through SwiftLintBuildToolPlugin, but without
--strict — so it only stops a build on a rule configured at error severity.
This script is what a change has to pass.
EOF
}

fix=false
show_help=false
print_pinned=false
# Every argument, not just the first. Reading one and ignoring the rest let a
# typo ride along with a valid option: `--fix --not-a-real-option` linted
# without fixing and still exited 0, which reads exactly like a clean --fix run
# that corrected nothing, and `--help --not-a-real-option` printed the help that
# promises unknown options are rejected while doing the opposite.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix)
            fix=true
            shift
            ;;
        --pinned-version)
            print_pinned=true
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

# After the loop, not inside it: --help is only honoured once the whole command
# line has been checked, so a bad token anywhere still fails the run.
if [[ "$show_help" == true ]]; then
    usage
    exit 0
fi
if [[ "$print_pinned" == true && "$fix" == true ]]; then
    echo "error: --pinned-version prints the version and lints nothing; it takes no --fix." >&2
    exit 2
fi

# The SwiftLint the project pins: the version of SwiftLintPlugins, whose
# releases carry SwiftLint's own numbers, in the app's Package.resolved.
# OPENHIKES_SWIFTLINT_RESOLVED names another Package.resolved: the seam
# Scripts/run-script-tests.sh reads a fixture through, which nothing else sets.
resolved="OpenHikes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
resolved="${OPENHIKES_SWIFTLINT_RESOLVED:-$resolved}"
pinned=""
index=0
while identity="$(/usr/bin/plutil -extract "pins.$index.identity" raw -o - -- "$resolved" 2>/dev/null)"; do
    if [[ "$identity" == swiftlintplugins ]]; then
        pinned="$(/usr/bin/plutil -extract "pins.$index.state.version" raw -o - -- "$resolved" 2>/dev/null || true)"
        break
    fi
    index=$((index + 1))
done
if [[ -z "$pinned" ]]; then
    echo "error: $resolved pins no version of SwiftLintPlugins, and that pin is" >&2
    echo "       the SwiftLint version this lints with." >&2
    exit 1
fi

if [[ "$print_pinned" == true ]]; then
    printf '%s\n' "$pinned"
    exit 0
fi

if ! command -v swiftlint >/dev/null 2>&1; then
    echo "error: swiftlint is not installed. Expected version $pinned." >&2
    echo "       brew install swiftlint, or see the pinned installer in .github/workflows/ci.yml" >&2
    exit 1
fi

installed="$(swiftlint version)"
# The verdict below names the version that produced it, never the pin: the
# warning this branch prints is that rules differ between versions, and a
# result credited to the version that did not run contradicts it. When they
# differ the pin is worth naming in the same line, so a local pass cannot be
# read as the CI-authoritative one.
verdict_scope="$installed, --strict"
if [[ "$installed" != "$pinned" ]]; then
    # A warning, not an error: a developer on a slightly different build should
    # still be able to lint. CI installs the pin exactly, so it is the version
    # that decides whether the push is green.
    echo "warning: swiftlint $installed installed, but CI runs $pinned." >&2
    echo "         Rules differ between versions; CI is the authority." >&2
    verdict_scope="$installed, --strict; CI pins $pinned"
fi

# `--force-exclude` makes `excluded:` authoritative. It is inert while no paths
# are passed, and is what would keep an in-repo git worktree out of the lint if
# one ever were: `included:` is ignored the moment a path appears on the command
# line, and `excluded:` is ignored too unless this flag is set.
if [[ "$fix" == true ]]; then
    swiftlint lint --fix --quiet --force-exclude
    echo "Applied every violation SwiftLint can correct. Re-linting:"
fi

# Run the lint outside `set -e` so its three outcomes can be told apart.
# SwiftLint exits 2 when it found violations and 1 for everything else — an
# unreadable path, no lintable files, a crash — and reporting the second as if
# it were the first is how a broken lint gets mistaken for a dirty tree.
set +e
output="$(swiftlint lint --strict --quiet --force-exclude 2>&1)"
status=$?
set -e

if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
fi

# A .swiftlint.yml that does not parse is a warning here, not an error:
# SwiftLint says so and then lints with its own default configuration. That
# default has no `included:` list, so it walks the whole repository — every
# in-repo git worktree with it — and it applies rules this project does not use.
# Its verdict is not this project's verdict, in either direction.
if grep -qE 'Falling back to default configuration|is not a valid rule identifier|Invalid configuration' <<<"$output"; then
    echo "error: SwiftLint did not use .swiftlint.yml as written (see above)." >&2
    echo "       It lints with its default configuration when this file is bad, so" >&2
    echo "       neither a pass nor a failure here means anything. Fix the config." >&2
    exit 1
fi

case "$status" in
    0)
        echo "SwiftLint clean ($verdict_scope)."
        ;;
    2)
        echo "error: SwiftLint found violations ($verdict_scope)." >&2
        exit 2
        ;;
    *)
        echo "error: SwiftLint could not run the lint (exit $status). This is not a" >&2
        echo "       report about the code — nothing was checked." >&2
        exit 1
        ;;
esac
