#!/bin/sh

# Xcode Cloud runs this automatically after it clones the repository and before
# it resolves packages, for every workflow — so both `OpenHikes | Default` and
# `OpenHikes | Default | Archive - iOS` pick it up.
#
# Why it exists: the app, widget and test targets use SwiftLintPlugins'
# SwiftLintBuildToolPlugin, and Xcode refuses to run a build tool plugin whose
# package fingerprint has not been trusted. On a developer machine that trust is
# recorded once, per user, in ~/Library/org.swift.swiftpm/security/plugins.json
# when Xcode offers "Trust & Enable". An Xcode Cloud VM is fresh: it has no such
# file and nobody to answer the dialog, so `xcodebuild archive` failed with
#
#   Plugin "SwiftLintBuildToolPlugin" from package "SwiftLintPlugins" must be
#   enabled before it can be used.
#
# GitHub Actions avoids this by passing -skipPackagePluginValidation to every
# xcodebuild call (.github/workflows/ci.yml). Xcode Cloud composes its own
# xcodebuild invocation, so that flag is unreachable, and it does not consult the
# checked-in project.xcworkspace/xcshareddata/swiftpm/configuration/AllowedPackagePlugins.json
# either. Setting the preference is the remaining hook.
#
# Lint results are still owned by Scripts/lint.sh and the CI `quality` job, which
# pin SwiftLint to .swiftlint-version; this only suppresses the trust prompt.

set -eu

# "Validatation" is Apple's own typo in the preference key. Do not correct it —
# the correctly spelled key is read by nothing.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

# Same class of prompt for any Swift macro a dependency introduces later. Set now
# so a future package does not fail the archive the same way.
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

echo "Disabled package plugin and macro fingerprint validation for this build."
