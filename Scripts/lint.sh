#!/bin/bash
#
# Runs the same SwiftLint the CI `quality` job runs, at the same pinned
# version and with the same flags.
#
# It exists because that job is the one that keeps breaking `main`: SwiftLint
# is not part of the Xcode build, so nothing tells you about a violation until
# CI does, ten minutes after the push. Both this script and `.github/workflows/
# ci.yml` read the version from `.swiftlint-version`, so the two cannot drift.
#
# Usage:
#   Scripts/lint.sh              # lint everything, strictly
#   Scripts/lint.sh --fix        # apply the violations SwiftLint can correct
#
set -euo pipefail

cd "$(dirname "$0")/.."

pinned="$(cat .swiftlint-version)"

if ! command -v swiftlint >/dev/null 2>&1; then
    echo "error: swiftlint is not installed. Expected version $pinned." >&2
    echo "       brew install swiftlint, or see the pinned installer in .github/workflows/ci.yml" >&2
    exit 1
fi

installed="$(swiftlint version)"
if [[ "$installed" != "$pinned" ]]; then
    # A warning, not an error: a developer on a slightly different build should
    # still be able to lint. CI installs the pin exactly, so it is the version
    # that decides whether the push is green.
    echo "warning: swiftlint $installed installed, but CI runs $pinned." >&2
    echo "         Rules differ between versions; CI is the authority." >&2
fi

if [[ "${1:-}" == "--fix" ]]; then
    swiftlint lint --fix --quiet
    echo "Applied every violation SwiftLint can correct. Re-linting:"
fi

swiftlint lint --strict --quiet
echo "SwiftLint clean ($pinned, --strict)."
