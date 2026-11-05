//
//  OrientationUITests+CommunityPreview.swift
//  OpenHikesUITests
//
//  A shared hike's preview through a turn of the phone: the page it loaded,
//  and the chart's marker where the hiker left it, both ways round.
//
//  An `extension` for the reason `OrientationUITests+Gallery` is one.
//

import XCTest

extension OrientationUITests {
    /// Where on the chart the marker is put: anywhere but the trailhead, where
    /// a preview built afresh puts it.
    private static let scrubbedFraction = 0.5

    /// Turning the phone with a shared hike's preview open keeps the page it
    /// had loaded, with the chart's marker where the hiker left it.
    ///
    /// The preview is drawn in the sheet in portrait and in the side panel in
    /// landscape, so a turn builds it again. While what it had loaded was its
    /// own state, the screen built in the new host asked for the hike again,
    /// downloaded its photographs a second time, and put the marker back at
    /// the trailhead (#1336).
    ///
    /// Read once the other host's copy has gone. For a moment after a turn to
    /// landscape both are up, and the one going still holds what it had.
    @MainActor
    func testACommunityPreviewKeepsItsChartThroughRotation() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        XCUIDevice.shared.orientation = .portrait
        let app = launchCommunity(scenario: .seeded)
        XCTAssertTrue(waitForPortrait(app), "the app should have started upright")
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: app)

        let chart = element("elevation-chart", in: app)
        XCTAssertTrue(scrollUntilVisible(chart, in: app), "precondition: the preview draws its chart")
        let atTrailhead = chart.value as? String
        chart.coordinate(withNormalizedOffset: CGVector(dx: Self.scrubbedFraction, dy: 0.5)).tap()
        XCTAssertTrue(waitUntilValueChanges(from: atTrailhead, on: chart), "precondition: a tap moves the marker")
        let scrubbed = chart.value as? String

        let charts = app.descendants(matching: .any).matching(identifier: "elevation-chart")
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(orientation == .portrait ? waitForPortrait(app) : waitForLandscape(app))
            XCTAssertTrue(
                waitUntil(timeout: UITestTimeout.navigation) { charts.count == 1 },
                "the preview is still open, in one host"
            )
            XCTAssertEqual(chart.value as? String, scrubbed, "with the marker where it was left")
        }
    }
}
