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

        let isUITesting: Bool
        let startsWithExpandedSheet: Bool
        let usesLiveLocation: Bool
        let importedGPXFixtureName: String?

        init(arguments: [String]) {
            isUITesting = arguments.contains(Self.uiTestingArgument)
            startsWithExpandedSheet = isUITesting
                && arguments.contains(Self.expandedSheetArgument)
            usesLiveLocation = !isUITesting
                || arguments.contains(Self.liveLocationArgument)

            guard isUITesting,
                  let argument = arguments.first(where: { argument in
                      argument.hasPrefix(Self.importGPXPrefix)
                  }) else {
                importedGPXFixtureName = nil
                return
            }

            let name = String(argument.dropFirst(Self.importGPXPrefix.count))
            importedGPXFixtureName = name.isEmpty
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
