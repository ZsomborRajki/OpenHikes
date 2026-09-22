//
//  TrailMakerSupport.swift
//  OpenHikesUITests
//
//  Opening the trail maker and drawing on it, for the two suites that do.
//
//  Its own file rather than a few more members on `UITestSupport.swift`, which
//  is at the length the linter allows — and rather than a copy in each suite,
//  which is two things to keep in step with a screen that has changed in every
//  phase of #607. ``TrailMakerUITests`` is what presses every button on the
//  maker; ``AccessibilityUITests`` needs only the way in and a line to sweep.
//

import XCTest

extension XCTestCase {
    /// Opens the trail maker from the map's own pill, which is the only way
    /// in.
    @MainActor
    func openTrailMaker(in app: XCUIApplication) {
        let pill = element("map-trail-maker-button", in: app)
        XCTAssertTrue(
            pill.waitForExistence(timeout: UITestTimeout.existence),
            "the search screen should offer to make a trail"
        )
        pill.tap()
        XCTAssertTrue(
            element("trail-draft-save", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "tapping the pill should open the maker"
        )
    }

    /// Puts a stop down at each offset, through the place sheet a tap on the
    /// map opens. The first two fill the start and the destination; every
    /// later one goes into the leg nearest to it, as *Add Stop* does.
    ///
    /// **Two gestures per point**, and that is the canvas rather than the
    /// helper: a tap drops a pin and asks, and the sheet's *Add Stop* is what
    /// draws — see ``TrailPlaceSheet``.
    ///
    /// Waiting on the row rather than tapping three times and asserting once:
    /// a tap that missed is indistinguishable from one the app has not
    /// processed yet, and only the wait tells them apart. No fixed sleep —
    /// each point is its own effect to wait on.
    @MainActor
    func drawTrailPoints(_ offsets: [CGVector], on map: XCUIElement, in app: XCUIApplication) {
        for (index, offset) in offsets.enumerated() {
            map.coordinate(withNormalizedOffset: offset).tap()
            tapInPlaceSheet("trail-place-add-stop", in: app)
            let row = element("trail-draft-point-\(index + 1)", in: app)
            XCTAssertTrue(
                row.waitForExistence(timeout: UITestTimeout.navigation),
                "Add Stop should put point \(index + 1) down"
            )
        }
    }

    /// Presses a button on the place sheet a tap on the map opened, and waits
    /// for the sheet to go if the button closes it — so the next tap lands on
    /// the map rather than on a sheet on its way out.
    @MainActor
    func tapInPlaceSheet(_ identifier: String, in app: XCUIApplication) {
        let button = element(identifier, in: app)
        XCTAssertTrue(
            button.waitForExistence(timeout: UITestTimeout.navigation),
            "a tap on the map should open the place sheet offering \(identifier)"
        )
        button.tap()
        XCTAssertTrue(
            waitUntil { !element("trail-place-sheet", in: app).exists },
            "\(identifier) should close the place sheet"
        )
    }
}
