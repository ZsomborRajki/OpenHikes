//
//  AppLaunchEnvironmentTests.swift
//  OpenHikesTests
//

@testable import OpenHikes
import Testing

@Suite("App launch environment")
struct AppLaunchEnvironmentTests {
    @Test("normal launches keep live location and ignore test-only options")
    func normalLaunch() {
        let configuration = AppLaunchEnvironment.Configuration(
            arguments: [
                "OpenHikes",
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=ThumseeLoopFast",
            ]
        )

        #expect(!configuration.isUITesting)
        #expect(!configuration.startsWithExpandedSheet)
        #expect(configuration.usesLiveLocation)
        #expect(configuration.importedGPXFixtureName == nil)
    }

    @Test("UI-test launches opt into deterministic surfaces")
    func uiTestLaunch() {
        let configuration = AppLaunchEnvironment.Configuration(
            arguments: [
                "OpenHikes",
                "--ui-testing",
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
                "--ui-test-import-gpx=ThumseeLoopFast",
            ]
        )

        #expect(configuration.isUITesting)
        #expect(configuration.startsWithExpandedSheet)
        #expect(configuration.usesLiveLocation)
        #expect(
            configuration.importedGPXFixtureName
                == "ThumseeLoopFast"
        )
    }

    @Test("UI-test location stays off unless explicitly requested")
    func uiTestLocationDefaultsOff() {
        let configuration = AppLaunchEnvironment.Configuration(
            arguments: ["OpenHikes", "--ui-testing"]
        )

        #expect(!configuration.usesLiveLocation)
    }

    /// The launch that hosts this suite is the subject: both unit bundles run
    /// inside the app, which reaches `.onAppear` — and `locationManager.start()`
    /// with it — before the first test does.
    @Test("app-hosted test launches keep Core Location dormant")
    func hostedTestLaunchHasNoLiveLocation() {
        let configuration = AppLaunchEnvironment.Configuration(
            arguments: ["OpenHikes"],
            isHostingTests: true
        )

        #expect(!configuration.isUITesting)
        #expect(!configuration.usesLiveLocation)
    }

    /// The UI-test flag says "this launch wants the live feed"; hosting a test
    /// bundle says "this launch must not have it". A hosted launch cannot
    /// legitimately carry both, but the refusal is worth pinning: the flag is
    /// the only way `usesLiveLocation` was ever true under `--ui-testing`, and
    /// an ordering that let it win here would put an authorization alert in
    /// front of a suite.
    @Test("the live-location argument does not override a hosted launch")
    func hostedTestLaunchIgnoresLiveLocationArgument() {
        let configuration = AppLaunchEnvironment.Configuration(
            arguments: ["OpenHikes", "--ui-testing", "--ui-test-enable-location"],
            isHostingTests: true
        )

        #expect(!configuration.usesLiveLocation)
    }

    /// The one assertion here that reads the real process rather than a parsed
    /// argument list, because the bug this closes was in the wiring between the
    /// two: the configuration was right about arguments and never asked about
    /// hosting, so the app host started the real manager underneath every unit
    /// run. Running at all proves `isHostingTests`; the point is what follows
    /// from it.
    @Test("this very launch is hosted, and therefore uses no live location")
    func thisLaunchUsesNoLiveLocation() {
        #expect(AppLaunchEnvironment.isHostingTests)
        #expect(AppLaunchEnvironment.isRunningTests)
        #expect(!AppLaunchEnvironment.usesLiveLocation)
    }

    @Test("fixture names cannot escape the app bundle")
    func fixtureNameRejectsPaths() {
        let configuration = AppLaunchEnvironment.Configuration(
            arguments: [
                "OpenHikes",
                "--ui-testing",
                "--ui-test-import-gpx=../private",
            ]
        )

        #expect(configuration.importedGPXFixtureName == nil)
    }

    @Test("seeded counts are read and clamped")
    func seededCounts() {
        let configuration = AppLaunchEnvironment.Configuration(
            arguments: [
                "OpenHikes",
                "--ui-testing",
                "--ui-test-seed-photos=8",
                "--ui-test-seed-metrics=999",
                "--ui-test-seed-walks=HalfLoop",
            ]
        )

        #expect(configuration.seededPhotoCount == 8)
        #expect(configuration.seededWalkFixtureName == "HalfLoop")
        // Clamped rather than honoured: a scenario asking for a thousand
        // reports is a typo, and the store would evict all but sixteen anyway.
        #expect(configuration.seededMetricsReportCount == 8)
    }

    /// Absent and zero are different answers here, which is the whole reason
    /// this one is optional while the seeded counts are not: a scenario has to
    /// be able to ask for a library with nothing in it, and that is not the
    /// same as asking for the real one.
    @Test("an absent photo library argument is not an empty library")
    func stubbedLibraryDistinguishesAbsentFromEmpty() {
        let absent = AppLaunchEnvironment.Configuration(
            arguments: ["OpenHikes", "--ui-testing"]
        )
        let empty = AppLaunchEnvironment.Configuration(
            arguments: ["OpenHikes", "--ui-testing", "--ui-test-photo-library=0"]
        )
        let filled = AppLaunchEnvironment.Configuration(
            arguments: ["OpenHikes", "--ui-testing", "--ui-test-photo-library=4"]
        )
        let absurd = AppLaunchEnvironment.Configuration(
            arguments: ["OpenHikes", "--ui-testing", "--ui-test-photo-library=999"]
        )
        let unrequested = AppLaunchEnvironment.Configuration(
            arguments: ["OpenHikes", "--ui-test-photo-library=4"]
        )

        #expect(absent.stubbedLibraryPhotoCount == nil)
        #expect(empty.stubbedLibraryPhotoCount == 0)
        #expect(filled.stubbedLibraryPhotoCount == 4)
        #expect(absurd.stubbedLibraryPhotoCount == 24)
        // Without `--ui-testing` the stub is not reachable at all, so a stray
        // argument on a shipping launch still reads the walker's own library.
        #expect(unrequested.stubbedLibraryPhotoCount == nil)
    }

    @Test("the failure, weather and import-selection seams are opt-in")
    func failureAndWeatherSeams() {
        let requested = AppLaunchEnvironment.Configuration(
            arguments: [
                "OpenHikes",
                "--ui-testing",
                "--ui-test-fail-first-save",
                "--ui-test-lose-import-selection",
                "--ui-test-weather",
            ]
        )
        let quiet = AppLaunchEnvironment.Configuration(
            arguments: ["OpenHikes", "--ui-testing"]
        )

        #expect(requested.failsFirstSave)
        #expect(requested.losesImportSelection)
        #expect(requested.stubsWeather)
        #expect(!quiet.failsFirstSave)
        // An import takes the selection on every launch that did not ask for
        // the losing side of that race.
        #expect(!quiet.losesImportSelection)
        #expect(!quiet.stubsWeather)
    }

    /// Every test-only option is inert without `--ui-testing`, which is what
    /// stops a stray argument on a shipping launch from seeding a walker's
    /// diagnostics screen or faking their weather.
    @Test("test-only seams stay off on a normal launch")
    func seamsIgnoredWithoutUITesting() {
        let configuration = AppLaunchEnvironment.Configuration(
            arguments: [
                "OpenHikes",
                "--ui-test-seed-photos=8",
                "--ui-test-seed-metrics=2",
                "--ui-test-fail-first-save",
                "--ui-test-lose-import-selection",
                "--ui-test-weather",
            ]
        )

        #expect(configuration.seededPhotoCount == 0)
        #expect(configuration.seededMetricsReportCount == 0)
        #expect(!configuration.failsFirstSave)
        #expect(!configuration.losesImportSelection)
        #expect(!configuration.stubsWeather)
    }
}
