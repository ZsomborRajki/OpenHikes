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
            ]
        )

        #expect(configuration.seededPhotoCount == 8)
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

    @Test("the failure and weather seams are opt-in")
    func failureAndWeatherSeams() {
        let requested = AppLaunchEnvironment.Configuration(
            arguments: [
                "OpenHikes",
                "--ui-testing",
                "--ui-test-fail-first-save",
                "--ui-test-weather",
            ]
        )
        let quiet = AppLaunchEnvironment.Configuration(
            arguments: ["OpenHikes", "--ui-testing"]
        )

        #expect(requested.failsFirstSave)
        #expect(requested.stubsWeather)
        #expect(!quiet.failsFirstSave)
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
                "--ui-test-weather",
            ]
        )

        #expect(configuration.seededPhotoCount == 0)
        #expect(configuration.seededMetricsReportCount == 0)
        #expect(!configuration.failsFirstSave)
        #expect(!configuration.stubsWeather)
    }
}
