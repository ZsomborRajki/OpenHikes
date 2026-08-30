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
    /// Everything a `--ui-test-*` argument can say about a launch.
    ///
    /// The parsing below is compiled **only into `DEBUG` builds**. That was
    /// documented long before it was true: the flags were all inert without
    /// `--ui-testing`, and a Store-installed app cannot be handed launch
    /// arguments, so nothing was reachable — but "there is no way in" is a
    /// weaker statement than "the door is not built", and the two documents
    /// describing this made the stronger one. A release build now gets
    /// ``production`` and never looks at `ProcessInfo.arguments` at all.
    struct Configuration: Equatable, Sendable {
        let isUITesting: Bool
        let startsWithExpandedSheet: Bool
        let usesLiveLocation: Bool
        let importedGPXFixtureName: String?
        let trailGraphFixtureName: String?
        let performanceLogScenario: String?
        let simulatesOffline: Bool
        let seededPhotoCount: Int
        let seededMetricsReportCount: Int
        let failsFirstSave: Bool
        let stubsWeather: Bool
        let grantsPaidMaps: Bool
        /// `nil` when the real photo library should be read — see
        /// ``AppLaunchEnvironment/stubbedLibraryPhotoCount``.
        let stubbedLibraryPhotoCount: Int?

        // periphery:ignore - read only from the `#else` branch below, which
        // a Debug-configuration scan never compiles.
        /// What every shipping launch gets, and what a debug launch with no
        /// arguments parses to.
        static let production = Self()

        // periphery:ignore - as above: only the `#else` branch reads this.
        /// What a release-configuration launch that is hosting a test bundle
        /// gets. Production in every respect except that Core Location stays
        /// dormant — see ``usesLiveLocation``.
        static let hostedTests = Self(usesLiveLocation: false)

        private init(usesLiveLocation: Bool = true) {
            isUITesting = false
            startsWithExpandedSheet = false
            self.usesLiveLocation = usesLiveLocation
            importedGPXFixtureName = nil
            trailGraphFixtureName = nil
            performanceLogScenario = nil
            simulatesOffline = false
            seededPhotoCount = 0
            seededMetricsReportCount = 0
            failsFirstSave = false
            stubsWeather = false
            grantsPaidMaps = false
            stubbedLibraryPhotoCount = nil
        }

        #if DEBUG
        private static let uiTestingArgument = "--ui-testing"
        private static let expandedSheetArgument = "--ui-test-expanded-sheet"
        private static let liveLocationArgument = "--ui-test-enable-location"
        private static let importGPXPrefix = "--ui-test-import-gpx="
        private static let trailGraphPrefix = "--ui-test-trail-graph="
        private static let performanceLogPrefix = "--ui-test-performance-log="
        private static let offlineArgument = "--ui-test-offline"
        private static let seedPhotosPrefix = "--ui-test-seed-photos="
        private static let seedMetricsPrefix = "--ui-test-seed-metrics="
        private static let failFirstSaveArgument = "--ui-test-fail-first-save"
        private static let stubWeatherArgument = "--ui-test-weather"
        private static let entitledArgument = "--ui-test-entitled"
        private static let photoLibraryPrefix = "--ui-test-photo-library="
        /// Enough to fill the review grid and force it to scroll.
        private static let maximumStubbedLibraryPhotos = 24
        /// Enough to fill the strip and force it to scroll, and few enough
        /// that a scenario seeding them does not spend its budget encoding.
        private static let maximumSeededPhotos = 24
        /// One metrics digest and one diagnostic report is already both shapes
        /// the screen draws; past that a scenario is only re-reading itself.
        private static let maximumSeededMetricsReports = 8

        /// - Parameters:
        ///   - arguments: the process arguments to parse.
        ///   - isHostingTests: whether this process was launched to host a
        ///     test bundle. Not derivable from `arguments` — it is an
        ///     environment variable — so it is passed in, which is also what
        ///     lets a suite parse a hosted launch without being one.
        init(arguments: [String], isHostingTests: Bool = false) {
            isUITesting = arguments.contains(Self.uiTestingArgument)
            startsWithExpandedSheet = isUITesting
                && arguments.contains(Self.expandedSheetArgument)
            // A hosted test bundle never drives the real Core Location stack.
            // Both unit bundles are hosted by the app, so the host reaches
            // `.onAppear` before any test runs: it would put an authorization
            // alert in front of the run, and re-arm significant-change
            // monitoring against whatever the developer's own defaults say the
            // last selected trail was. UI tests are the opposite case — they
            // drive a real app out of process, and the scenarios that record a
            // hike ask for the live feed by name.
            usesLiveLocation = !isHostingTests
                && (!isUITesting || arguments.contains(Self.liveLocationArgument))
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
            seededPhotoCount = Self.count(
                in: arguments,
                prefix: Self.seedPhotosPrefix,
                isUITesting: isUITesting,
                limit: Self.maximumSeededPhotos
            )
            seededMetricsReportCount = Self.count(
                in: arguments,
                prefix: Self.seedMetricsPrefix,
                isUITesting: isUITesting,
                limit: Self.maximumSeededMetricsReports
            )
            failsFirstSave = isUITesting
                && arguments.contains(Self.failFirstSaveArgument)
            stubsWeather = isUITesting
                && arguments.contains(Self.stubWeatherArgument)
            grantsPaidMaps = isUITesting
                && arguments.contains(Self.entitledArgument)
            // `nil` rather than 0 when absent: zero is a real answer — a
            // library with nothing in it — and the empty state is one of the
            // things a scenario needs to be able to ask for.
            stubbedLibraryPhotoCount = isUITesting && arguments.contains(where: { argument in
                argument.hasPrefix(Self.photoLibraryPrefix)
            })
                ? Self.count(
                    in: arguments,
                    prefix: Self.photoLibraryPrefix,
                    isUITesting: isUITesting,
                    limit: Self.maximumStubbedLibraryPhotos
                )
                : nil
        }

        /// A bounded count read out of a `--flag=N` argument. Clamped rather
        /// than validated: the only caller that should ever set one is the UI
        /// test runner, and a scenario asking for a thousand of anything is a
        /// typo, not a request.
        private static func count(
            in arguments: [String],
            prefix: String,
            isUITesting: Bool,
            limit: Int
        ) -> Int {
            fixtureName(
                in: arguments,
                prefix: prefix,
                isUITesting: isUITesting
            )
            .flatMap(Int.init)
            .map { count in min(max(0, count), limit) } ?? 0
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
        #endif
    }

    private static let configuration: Configuration = {
        #if DEBUG
        Configuration(
            arguments: ProcessInfo.processInfo.arguments,
            isHostingTests: isHostingTests
        )
        #else
        isHostingTests ? .hostedTests : .production
        #endif
    }()
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
    /// Whether this launch should drive the real Core Location stack.
    ///
    /// False for a hosted test launch and for any UI-test launch that did not
    /// ask for the live feed. A launch this is false for gets no fixes *and*
    /// no live manager: see ``DormantLocationSource``, which is what the app
    /// composes in place of `CLLocationManager`. Not calling `start()` is a
    /// weaker guarantee than not having one — the background tracker arms
    /// itself from `UserDefaults` in its own `init`, with nobody calling
    /// anything.
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

    /// How many synthetic MetricKit reports to write before Settings is
    /// opened.
    ///
    /// MetricKit reports nothing on a Simulator — `mxSignpost` attaches the
    /// literal `NO_METRICS` there and no payload is ever delivered — so the
    /// only state Device Reports could reach in automation was the empty one.
    /// That left the report screen, the export screen, the share sheet and
    /// the delete button unreachable: four screens' worth of rows whose whole
    /// job is to say what a number means, and no way to check that any of
    /// them says anything at all.
    ///
    /// The reports go through the real ``FieldMetricsStore``, so what a test
    /// reads afterwards is the shipping decode, retention and export path;
    /// only the numbers are invented.
    static let seededMetricsReportCount = configuration.seededMetricsReportCount

    /// Whether the first attempt to save a recording should fail.
    ///
    /// The retry path is the one branch of the recording screen that a test
    /// cannot reach by doing anything a walker does: it needs SwiftData to
    /// refuse a write. The recorder already takes its save as a closure — the
    /// seam exists for the unit suites — so this is that closure, failing
    /// once, and everything downstream of it is the shipping state machine.
    static let failsFirstSave = configuration.failsFirstSave

    /// Whether the weather badge should be drawn from a fixed reading.
    ///
    /// WeatherKit needs an entitlement, a network round trip and a working
    /// token; none of the three is a thing a UI test should be deciding on,
    /// and `CurrentWeather` cannot be constructed to stand in for them.
    /// ``WeatherSnapshot`` is what the badge actually draws, and this
    /// publishes one.
    static let stubsWeather = configuration.stubsWeather

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

    /// Whether this launch should behave as though the Pro maps unlock has
    /// been purchased.
    ///
    /// A UI test cannot buy anything: `Product.purchase()` needs a StoreKit
    /// configuration and a sandbox account, and a test that had one would be
    /// testing the App Store rather than this app. This grants the entitlement
    /// directly, so a scenario can check that a paid source becomes selectable
    /// and that the paywall stops being offered — the two things the gate is
    /// actually for. Without it the app resolves the real entitlement, which
    /// on a fresh simulator is always "not entitled", so the locked path is
    /// the default a test gets for free.
    static let grantsPaidMaps = configuration.grantsPaidMaps

    /// How many photographs a stubbed photo library should hold, or `nil` when
    /// the real one should be read.
    ///
    /// The photo library is the one dependency of this app that automation
    /// must not touch at all: reading it means a system permission alert about
    /// somebody's private data, and what is behind that alert is whatever the
    /// last person to use the Simulator left there. Neither is a thing a test
    /// should be deciding. See ``PhotoLibrarySource`` for what stands in.
    ///
    /// Zero is a real value and distinct from absent — it is the library with
    /// nothing in it, which is the empty state the review sheet has to be able
    /// to draw.
    static let stubbedLibraryPhotoCount = configuration.stubbedLibraryPhotoCount

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

    /// A per-launch directory for seeded MetricKit reports, so automation
    /// never writes into — or reads — the reports a real device left in
    /// Application Support.
    ///
    /// Per-launch rather than merely separate: a seeded report that outlived
    /// its scenario would make the *next* run's "no reports yet" assertion
    /// fail, and the empty state is the one every user sees for their first
    /// day.
    static func fieldMetricsDirectory() -> URL? {
        guard isUITesting else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OpenHikesUITestingMetrics-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
    }
}
