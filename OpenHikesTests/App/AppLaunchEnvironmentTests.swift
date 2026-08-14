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
}
