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

    /// Taps the map at each offset, answers the callout, and waits for the
    /// point to be listed.
    ///
    /// **Two gestures per point**, and that is the canvas rather than the
    /// helper: a tap drops a provisional pin and asks, and the button in its
    /// callout is what draws — see ``TrailDraftPinAction``. Which verb is
    /// offered follows from how much line there is, which is why the name is
    /// computed from the index rather than passed in: a helper that had to be
    /// told would hide the rule it is exercising.
    ///
    /// Waiting on the row rather than tapping three times and asserting once:
    /// a tap that missed is indistinguishable from one the app has not
    /// processed yet, and only the wait tells them apart. No fixed sleep —
    /// each point is its own effect to wait on.
    @MainActor
    func drawTrailPoints(_ offsets: [CGVector], on map: XCUIElement, in app: XCUIApplication) {
        for (index, offset) in offsets.enumerated() {
            map.coordinate(withNormalizedOffset: offset).tap()
            confirmDroppedPin(trailDraftPinVerb(forPointAt: index), in: app)
            let row = element("trail-draft-point-\(index + 1)", in: app)
            XCTAssertTrue(
                row.waitForExistence(timeout: UITestTimeout.navigation),
                "the callout should put point \(index + 1) down"
            )
        }
    }

    /// The identifier of the verb a callout offers for the *n*th point.
    ///
    /// Mirrors ``TrailDraftPinAction/offered(forWaypointCount:)``, spelled out
    /// rather than read from it: these suites are the ones that press buttons,
    /// and a helper that computed the identifier from the same source as the
    /// app would be green on a build where the button never appeared.
    @MainActor
    func trailDraftPinVerb(forPointAt index: Int) -> String {
        switch index {
        case 0: "trail-draft-pin-start-here"
        case 1: "trail-draft-pin-set-as-destination"
        default: "trail-draft-pin-make-destination"
        }
    }

    /// Presses one of the buttons inside the pin's callout.
    ///
    /// The buttons are a `UIStackView` this app owns inside MapKit's own
    /// callout, so unlike a `Menu`'s contents they keep their identifiers —
    /// see ``TrailDraftPinAction/accessibilityIdentifier``.
    @MainActor
    func confirmDroppedPin(_ identifier: String, in app: XCUIApplication) {
        let button = element(identifier, in: app)
        XCTAssertTrue(
            button.waitForExistence(timeout: UITestTimeout.navigation),
            "a tap on the map should open a callout offering \(identifier)"
        )
        button.tap()
    }
}
