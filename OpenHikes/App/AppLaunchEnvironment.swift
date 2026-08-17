//
//  AppLaunchEnvironment.swift
//  OpenHikes
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
        private static let offlineArgument = "--ui-test-offline"
        private static let seedPhotosPrefix = "--ui-test-seed-photos="
        /// Enough to fill the strip and force it to scroll, and few enough
        /// that a scenario seeding them does not spend its budget encoding.
        private static let maximumSeededPhotos = 24

        let isUITesting: Bool
        let startsWithExpandedSheet: Bool
        let usesLiveLocation: Bool
        let importedGPXFixtureName: String?
        let trailGraphFixtureName: String?
        let performanceLogScenario: String?
        let simulatesOffline: Bool
        let seededPhotoCount: Int

        init(arguments: [String]) {
            isUITesting = arguments.contains(Self.uiTestingArgument)
            startsWithExpandedSheet = isUITesting
                && arguments.contains(Self.expandedSheetArgument)
            usesLiveLocation = !isUITesting
                || arguments.contains(Self.liveLocationArgument)
            simulatesOffline = isUITesting
                && arguments.contains(Self.offlineArgument)
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
            seededPhotoCount = Self.fixtureName(
                in: arguments,
                prefix: Self.seedPhotosPrefix,
                isUITesting: isUITesting
            )
            .flatMap(Int.init)
            .map { count in min(max(0, count), Self.maximumSeededPhotos) } ?? 0
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
                  }) else { return nil }

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
        "tappium.com.OpenHikes.UITesting"

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

    /// How many synthetic photos to attach to the hike a launch imports.
    ///
    /// The photo pipeline is the one part of the app a UI test cannot reach
    /// on its own: the camera is unavailable on the Simulator and the library
    /// picker is a system process. Without seeding, every scenario measures a
    /// hike with an empty gallery — which is how the photo feature shipped
    /// without appearing in a single performance number.
    ///
    /// These go through ``HikePhotoImport``, so what is measured afterwards is
    /// the real store, the real files on disk and the real decode path; only
    /// the pixels are invented.
    static let seededPhotoCount = configuration.seededPhotoCount

    /// Whether this launch should behave as though it has no connection at
    /// all, regardless of what the simulator's network is doing.
    ///
    /// The offline-first claim is the one thing about this app that a UI test
    /// on a connected machine cannot otherwise check: a scenario that pans the
    /// map will happily fetch tiles, and "it worked" proves nothing about
    /// whether it *needed* to. With this set, ``TileCache`` is held offline,
    /// so a scenario that still draws its map drew it from what was already
    /// on the device — and any tile traffic at all is a failure rather than a
    /// number to interpret.
    static let simulatesOffline = configuration.simulatesOffline

    /// A per-launch, empty pair of tile directories for the offline scenario.
    ///
    /// Without this the scenario is decided by history rather than by the
    /// policy: the app's tile cache outlives a UI-test launch, so after any
    /// earlier run has browsed the same region every tile is already on disk,
    /// no fetch is attempted, and "no network traffic" is true for the wrong
    /// reason. A cold root makes every visible tile a real miss, which is what
    /// turns the assertion into a test of ``TileNetworkPolicy`` rather than of
    /// what the machine happened to have lying around.
    static func isolatedTileRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OpenHikesOfflineTiles-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

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
                "OpenHikesUITesting-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
    }
}
