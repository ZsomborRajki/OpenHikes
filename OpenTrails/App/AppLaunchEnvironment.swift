//
//  AppLaunchEnvironment.swift
//  OpenTrails
//
//  Facts about *how this process was launched* that app-scoped startup work
//  has to branch on. One definition, because two copies of the same guard
//  drift and only one of them gets fixed.
//

import Foundation

nonisolated enum AppLaunchEnvironment {
    struct Configuration: Equatable, Sendable {
        private static let uiTestingArgument = "--ui-testing"
        private static let expandedSheetArgument = "--ui-test-expanded-sheet"
        private static let liveLocationArgument = "--ui-test-enable-location"
        private static let importGPXPrefix = "--ui-test-import-gpx="
        private static let trailGraphPrefix = "--ui-test-trail-graph="
        private static let performanceLogPrefix = "--ui-test-performance-log="

        let isUITesting: Bool
        let startsWithExpandedSheet: Bool
        let usesLiveLocation: Bool
        let importedGPXFixtureName: String?
        let trailGraphFixtureName: String?
        let performanceLogScenario: String?

        init(arguments: [String]) {
            isUITesting = arguments.contains(Self.uiTestingArgument)
            startsWithExpandedSheet = isUITesting
                && arguments.contains(Self.expandedSheetArgument)
            usesLiveLocation = !isUITesting
                || arguments.contains(Self.liveLocationArgument)
            importedGPXFixtureName = Self.fixtureName(
                in: arguments,
                prefix: Self.importGPXPrefix,
                isUITesting: isUITesting
            )
            trailGraphFixtureName = Self.fixtureName(
                in: arguments,
                prefix: Self.trailGraphPrefix,
                isUITesting: isUITesting
            )
            performanceLogScenario = Self.fixtureName(
                in: arguments,
                prefix: Self.performanceLogPrefix,
                isUITesting: isUITesting
            )
        }

        /// Reads a name out of a launch argument, for a bundled fixture or a
        /// file this process will write. A name that could escape the bundle
        /// or the container is refused rather than sanitized, because the only
        /// caller that should ever set one is the UI test runner.
        private static func fixtureName(
            in arguments: [String],
            prefix: String,
            isUITesting: Bool
        ) -> String? {
            guard isUITesting,
                  let argument = arguments.first(where: { argument in
                      argument.hasPrefix(prefix)
                  }) else {
                return nil
            }

            let name = String(argument.dropFirst(prefix.count))
            return name.isEmpty
                || name.contains("/")
                || name.contains("\\")
                ? nil
                : name
        }
    }

    private static let configuration = Configuration(
        arguments: ProcessInfo.processInfo.arguments
    )
    private static let uiTestingDefaultsSuite =
        "tappium.com.OpenTrails.UITesting"

    /// Whether this process was launched to host a test bundle.
    ///
    /// Both test bundles are hosted by the app, so it launches — and runs its
    /// `init`s and `.task`s — before a single test does. Startup work that
    /// writes shared state (a widget payload in the App Group, a recovered
    /// recording journal) therefore lands underneath suites whose whole
    /// subject is that state. It's a race no test can win, so the writers
    /// stay behind this flag.
    static let isHostingTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// UI tests run in a separate runner, so the app process does not carry
    /// `XCTestConfigurationFilePath`; the launch argument is its explicit flag.
    static let isUITesting = configuration.isUITesting

    static let isRunningTests = isHostingTests || isUITesting
    static let startsWithExpandedSheet =
        configuration.startsWithExpandedSheet
    static let usesLiveLocation = configuration.usesLiveLocation
    static let importedGPXFixtureName =
        configuration.importedGPXFixtureName
    /// Name of the bundled trail graph UI automation records against, so a
    /// review section does not depend on reaching Overpass.
    static let trailGraphFixtureName =
        configuration.trailGraphFixtureName

    /// Name of the scenario whose render marks, main-thread stalls and
    /// resource samples this launch should write to a file — see
    /// ``PerformanceLog``. `nil` for every launch that is not being measured,
    /// which is what keeps the diagnostics off an ordinary run.
    static let performanceLogScenario =
        configuration.performanceLogScenario

    /// Gives UI automation fresh settings without erasing the normal
    /// simulator app's preferences.
    static func makeDefaults() -> UserDefaults {
        guard isUITesting else { return .standard }
        guard let defaults = UserDefaults(
            suiteName: uiTestingDefaultsSuite
        ) else {
            preconditionFailure("Could not create UI-testing defaults.")
        }
        defaults.removePersistentDomain(forName: uiTestingDefaultsSuite)
        return defaults
    }

    /// Recording UI tests use the real Core Location source but keep their
    /// crash-recovery journal out of the app's durable recording directory.
    static func recordingJournalDirectory() -> URL? {
        guard isUITesting else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OpenTrailsUITesting-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
    }
}
