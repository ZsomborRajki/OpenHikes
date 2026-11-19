//
//  OfflineMapsSupport.swift
//  OpenHikesUITests
//
//  *Offline Maps*, opened from the row at the foot of *Map Modes*, for the
//  suites that need its list: `OfflineMapsUITests` and the audit. A launch
//  lists nothing unless it names the stand-in list
//  (``OfflineMapsFixture/seededArguments``), and even then it has no download
//  session, so nothing downloads.
//

import XCTest

nonisolated enum OfflineMapsFixture {
    /// The ten areas of `OfflineCountriesSeed.json`.
    static let seededArguments = ["--ui-test-offline-countries=seeded"]
    /// A list that cannot be loaded.
    static let refusedArguments = ["--ui-test-offline-countries=refused"]
}

extension XCTestCase {
    /// Opens *Map Modes*, then *Offline Maps* from the row at its foot, and
    /// waits for the list's title.
    @MainActor
    func openOfflineMaps(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openMapModes(in: app, file: file, line: line)
        scrollToTap(element("map-modes-offline-maps", in: app), in: app)
        XCTAssertTrue(
            app.navigationBars["Offline Maps"].waitForExistence(timeout: UITestTimeout.navigation),
            "the row at the foot of Map Modes should open Offline Maps",
            file: file,
            line: line
        )
    }

    /// Keeps a picture of the screen in the result bundle, pass or fail, so a
    /// run can be looked at as well as read.
    @MainActor
    func keepScreenshot(_ name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
