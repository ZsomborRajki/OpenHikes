//
//  WalkShareSupport.swift
//  OpenHikesUITests
//
//  The way onto a walk's share card, for the two suites that go there.
//
//  Its own file for the reason `PlaceSupport.swift` is one: ``WalkUITests``
//  is what drags the boxes about, and ``AccessibilityUITests`` needs only the
//  way in.
//

import XCTest

extension XCTestCase {
    /// The fixture hike with one walk along half of it and two photographs to
    /// put the card on.
    @MainActor
    func launchWalkShare() -> XCUIApplication {
        launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            "--ui-test-seed-walks=HalfLoop",
            "--ui-test-seed-photos=2",
        ])
    }

    /// From the hike's walk history to *Share* on the walk's summary, which
    /// opens on choosing a photograph.
    @MainActor
    func openWalkShare(in app: XCUIApplication) {
        openHikeDetail(in: app)
        app.segmentedControls["walk-segment"].buttons["History"].tap()
        let row = app.descendants(matching: .any).matching(identifier: "walk-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: UITestTimeout.existence))
        row.tap()

        let share = app.buttons["walk-share"]
        XCTAssertTrue(share.waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertTrue(
            share.wait(for: \.isEnabled, toEqual: true, timeout: UITestTimeout.existence),
            "Share waits only for the trail's profile"
        )
        share.tap()

        XCTAssertTrue(
            app.buttons["walk-share-photo-0"].waitForExistence(timeout: UITestTimeout.navigation),
            "the hike's photos are offered"
        )
    }

    /// The editor, opened from the photo chooser on the hike's first
    /// photograph. Returns the stats box, which is there once the card is.
    @MainActor
    @discardableResult func openWalkShareEditor(in app: XCUIApplication) -> XCUIElement {
        app.buttons["walk-share-photo-0"].tap()
        let stats = walkShareBox(.stats, in: app)
        XCTAssertTrue(stats.waitForExistence(timeout: UITestTimeout.navigation), "the editor opens on the photo")
        return stats
    }

    @MainActor
    func walkShareBox(_ box: WalkShareBoxIdentifier, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "walk-share-box-\(box.rawValue)").firstMatch
    }
}

/// The two boxes on the card, by the name their identifiers carry.
nonisolated enum WalkShareBoxIdentifier: String {
    case route = "route"
    case stats = "stats"
}
