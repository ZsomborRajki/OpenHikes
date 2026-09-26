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
        /// `nil` unless a launch asked for a stand-in public database — see
        /// ``AppLaunchEnvironment/communityScenarioName``.
        let communityScenarioName: String?
        /// `nil` unless a launch asked for a stand-in place search — see
        /// ``AppLaunchEnvironment/trailPointScenarioName``.
        let trailPointScenarioName: String?
        let simulatesOffline: Bool
        let seededPhotoCount: Int
        /// How many bare hikes a launch asked for — see
        /// ``AppLaunchEnvironment/seededLibraryHikeCount``.
        let seededLibraryHikeCount: Int
        /// `nil` unless a launch asked for a walk fixture — see
        /// ``AppLaunchEnvironment/seededWalkFixtureName``.
        let seededWalkFixtureName: String?
        let failsFirstSave: Bool
        let losesImportSelection: Bool
        let stubsWeather: Bool
        let grantsPaidMaps: Bool
        /// Whether the trail maker may ask Apple and Stadia — see
        /// ``AppLaunchEnvironment/asksLiveMakerServices``.
        let asksLiveMakerServices: Bool
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
            communityScenarioName = nil
            trailPointScenarioName = nil
            simulatesOffline = false
            seededPhotoCount = 0
            seededLibraryHikeCount = 0
            seededWalkFixtureName = nil
            failsFirstSave = false
            losesImportSelection = false
            stubsWeather = false
            grantsPaidMaps = false
            asksLiveMakerServices = false
            stubbedLibraryPhotoCount = nil
        }

        #if DEBUG
        private static let uiTestingArgument = "--ui-testing"
        private static let expandedSheetArgument = "--ui-test-expanded-sheet"
        private static let liveLocationArgument = "--ui-test-enable-location"
        private static let importGPXPrefix = "--ui-test-import-gpx="
        private static let trailGraphPrefix = "--ui-test-trail-graph="
        private static let communityPrefix = "--ui-test-community="
        private static let trailPointsPrefix = "--ui-test-trail-points="
        private static let offlineArgument = "--ui-test-offline"
        private static let seedPhotosPrefix = "--ui-test-seed-photos="
        private static let seedHikesPrefix = "--ui-test-seed-hikes="
        private static let seedWalksPrefix = "--ui-test-seed-walks="
        private static let failFirstSaveArgument = "--ui-test-fail-first-save"
        private static let loseImportSelectionArgument =
            "--ui-test-lose-import-selection"
        private static let stubWeatherArgument = "--ui-test-weather"
        private static let entitledArgument = "--ui-test-entitled"
        private static let liveMakerArgument = "--ui-test-live-maker"
        private static let photoLibraryPrefix = "--ui-test-photo-library="
        /// Enough to fill the review grid and force it to scroll.
        private static let maximumStubbedLibraryPhotos = 24
        /// Enough to fill the strip and force it to scroll, and few enough
        /// that a scenario seeding them does not spend its budget encoding.
        private static let maximumSeededPhotos = 24
        /// Enough to drag one row past several others and still see both
        /// ends of the list, and few enough that seeding them is not what a
        /// scenario spends its time on.
        private static let maximumSeededLibraryHikes = 12

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
                in: arguments, prefix: Self.importGPXPrefix, isUITesting: isUITesting
            )
            trailGraphFixtureName = Self.fixtureName(
                in: arguments, prefix: Self.trailGraphPrefix, isUITesting: isUITesting
            )
            communityScenarioName = Self.fixtureName(
                in: arguments, prefix: Self.communityPrefix, isUITesting: isUITesting
            )
            trailPointScenarioName = Self.fixtureName(
                in: arguments, prefix: Self.trailPointsPrefix, isUITesting: isUITesting
            )
            seededPhotoCount = Self.count(
                in: arguments,
                prefix: Self.seedPhotosPrefix,
                isUITesting: isUITesting,
                limit: Self.maximumSeededPhotos
            )
            seededLibraryHikeCount = Self.count(
                in: arguments,
                prefix: Self.seedHikesPrefix,
                isUITesting: isUITesting,
                limit: Self.maximumSeededLibraryHikes
            )
            seededWalkFixtureName = Self.fixtureName(
                in: arguments,
                prefix: Self.seedWalksPrefix,
                isUITesting: isUITesting
            )
            failsFirstSave = isUITesting
                && arguments.contains(Self.failFirstSaveArgument)
            losesImportSelection = isUITesting
                && arguments.contains(Self.loseImportSelectionArgument)
            stubsWeather = isUITesting
                && arguments.contains(Self.stubWeatherArgument)
            grantsPaidMaps = isUITesting
                && arguments.contains(Self.entitledArgument)
            asksLiveMakerServices = isUITesting
                && arguments.contains(Self.liveMakerArgument)
            stubbedLibraryPhotoCount = Self.stubbedLibraryPhotoCount(
                in: arguments,
                isUITesting: isUITesting
            )
        }

        /// How many photos to put in the stand-in library, or `nil` to read
        /// the real one.
        ///
        /// `nil` rather than 0 when the argument is absent: zero is a real
        /// answer — a library with nothing in it — and the empty state is one
        /// of the things a scenario needs to be able to ask for.
        private static func stubbedLibraryPhotoCount(
            in arguments: [String],
            isUITesting: Bool
        ) -> Int? {
            let isAsked = isUITesting && arguments.contains { argument in
                argument.hasPrefix(Self.photoLibraryPrefix)
            }
            guard isAsked else { return nil }
            return count(
                in: arguments,
                prefix: Self.photoLibraryPrefix,
                isUITesting: isUITesting,
                limit: Self.maximumStubbedLibraryPhotos
            )
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

    /// Which stand-in public database this launch asked for, or `nil` for
    /// every launch that did not — which is all of them but the scenarios that
    /// name one.
    ///
    /// The community feature is the one part of the app with no sandbox to
    /// test against: a submission made from a test is a submission, in the
    /// developer's own container, waiting in a reviewer's queue. So the rule
    /// stays what it always was — a launch running tests gets no transport at
    /// all — and this is the single, explicit exception a scenario has to
    /// spell out by name. See ``SeededCommunityTransport``.
    static let communityScenarioName = configuration.communityScenarioName

    /// Which stand-in OpenStreetMap place search this launch asked for, or
    /// `nil` for every launch that did not.
    ///
    /// The same shape as ``communityScenarioName`` and for the same reason one
    /// service over: a launch running tests gets no place source at all, so
    /// *Places Around Trail* and the recording sheet's *Mapped Here* are
    /// absent from every suite unless a scenario names this. See
    /// ``SeededTrailPointSource``.
    static let trailPointScenarioName = configuration.trailPointScenarioName

    /// How many synthetic photos to attach to the hike a launch imports.
    ///
    /// The photo pipeline is the one part of the app a UI test cannot reach on
    /// its own: the camera is unavailable on the Simulator and the library
    /// picker is a system process. Without seeding, every test sees a hike
    /// with an empty gallery — which is how the photo feature once shipped
    /// without appearing in a single performance number.
    ///
    /// These go through ``HikePhotoImport``, so what a test reads afterwards
    /// is the real store, the real files on disk and the real decode path;
    /// only the pixels are invented.
    static let seededPhotoCount = configuration.seededPhotoCount
    /// How many plain hikes to put in the library before anything else runs.
    ///
    /// A list scenario needs *several* hikes and does not care what is in
    /// them — the GPX fixture makes exactly one, and importing it repeatedly
    /// would spend a scenario's budget parsing the same file. See
    /// ``SeededLibraryFixture``.
    static let seededLibraryHikeCount = configuration.seededLibraryHikeCount

    /// The name of a walk fixture to attach to the hike a launch imports, or
    /// `nil` for none — see `SeededWalkFixture` for the names.
    ///
    /// A walk is a record of a stroll, and a stroll in the Simulator is a
    /// minute of simulated fixes per scenario. The history and the summary
    /// are about what a *finished* walk looks like, and this puts one in
    /// front of them in the time it takes to import a GPX. The row goes
    /// through the real store, so what is read afterwards is the shipping
    /// query and the shipping cascade; only the walk is invented.
    static let seededWalkFixtureName = configuration.seededWalkFixtureName

    /// Whether the first attempt to save a recording should fail.
    ///
    /// The retry path is the one branch of the recording screen that a test
    /// cannot reach by doing anything a hiker does: it needs SwiftData to
    /// refuse a write. The recorder already takes its save as a closure — the
    /// seam exists for the unit suites — so this is that closure, failing
    /// once, and everything downstream of it is the shipping state machine.
    static let failsFirstSave = configuration.failsFirstSave

    /// Whether an import should give up the selection it would otherwise
    /// take.
    ///
    /// The gate in `OpenHikesView` decides whether an import that started a
    /// moment ago may still take over the map when its parse finishes, and
    /// losing that decision is unreachable from automation: it needs a tap to
    /// land inside the milliseconds a parse takes. Everything that happens to
    /// the imported hike *after* the gate — the launch fixture photographing
    /// it, for one — has to work on the losing side too, and this is how a
    /// scenario gets to stand there. The hike is persisted either way; only
    /// its claim on the map is dropped.
    static let losesImportSelection = configuration.losesImportSelection

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

    /// Whether the trail maker should ask Apple Maps for directions and
    /// Stadia for heights, as a shipping launch does, rather than being
    /// handed the no-route answer and no climb every other test launch gets.
    ///
    /// For one caller: the App Store frame of a drawn trail, which is a
    /// picture of a Walking route following the Rinnkendlsteig and is not
    /// that picture with straight legs. Nothing asserts on what comes back —
    /// the frame waits for *a* route and *a* climb and shoots whatever they
    /// are — so the reason the other launches are stubbed, that an assertion
    /// would be about Apple's map data rather than this app, does not reach
    /// it. The billed half is one Stadia call per run, and only with the Pro
    /// grant beside it, since ``StadiaElevationSource`` checks that too.
    ///
    /// The hiking router is not part of this: it asks a volunteer-run
    /// Overpass server, and no launch under automation may.
    static let asksLiveMakerServices = configuration.asksLiveMakerServices

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
}
