//
//  HikeOrderUITests.swift
//  OpenHikesUITests
//
//  Dragging a hike up the list, and the list still saying so afterwards.
//
//  Out of process because the question is about a *gesture*: whether a long
//  press and a drag reorder a `List` at all outside edit mode. `HikeListOrder`
//  has the arithmetic under test in the unit bundle — what cannot be asserted
//  there is that SwiftUI ever calls it.
//

import XCTest

/// Enough rows to drag past several and still see both ends of the list.
///
/// At file scope rather than on the class: a stored property makes the class
/// main-actor isolated under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and
/// `XCTestCase`'s initialisers are not.
private let seededHikeCount = 4

nonisolated final class HikeOrderUITests: XCTestCase {
    @MainActor
    func testALongPressDragMovesAHikeUpTheList() {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-seed-hikes=\(seededHikeCount)",
        ])

        // Seeded newest-first, so "Seeded Trail 1" is the row on top and
        // "Seeded Trail 3" is two below it.
        let top = awaitHikeRow(titled: "Seeded Trail 1", in: app)
        let third = awaitHikeRow(titled: "Seeded Trail 3", in: app)
        XCTAssertLessThan(
            top.frame.minY,
            third.frame.minY,
            "the seeded hikes should start in date order, newest first"
        )

        // Hold the row, take the offer to reorder, then drag. Two steps
        // rather than one, and both of them are findings rather than taste:
        // `List` only reorders in edit mode — a press-and-drag without it
        // leaves the row where it started — and a bare long-press gesture on
        // these rows fires the button under it, so the app pushed the hike
        // instead. The context menu is the press that does neither.
        third.press(forDuration: 1.0)
        let reorder = app.buttons["Reorder Hikes"]
        XCTAssertTrue(
            reorder.waitForExistence(timeout: UITestTimeout.existence),
            "a long press should offer to reorder the list"
        )
        reorder.tap()
        XCTAssertTrue(
            app.buttons["hike-order-done-button"].waitForExistence(timeout: UITestTimeout.existence),
            "taking the offer should put the list into reorder mode"
        )
        // Coordinates and a slow drag with a hold at the end, rather than
        // element-to-element. A reorder is committed on the *drop*, and a
        // synthesised flick from one element to another is over before the
        // list has decided anything — the first version of this test read as
        // "the row did not move" when what had happened was "the gesture was
        // too fast to be a drag". The trailing edge is where the grabber is.
        let grabber = third.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        let above = top.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.0))
        grabber.press(
            forDuration: 0.8,
            thenDragTo: above,
            withVelocity: .slow,
            thenHoldForDuration: 0.8
        )

        _ = waitUntil(timeout: UITestTimeout.navigation) {
            hikeRow(titled: "Seeded Trail 3", in: app).frame.minY
                < hikeRow(titled: "Seeded Trail 1", in: app).frame.minY
        }

        let moved = hikeRow(titled: "Seeded Trail 3", in: app)
        let displaced = hikeRow(titled: "Seeded Trail 1", in: app)
        XCTAssertLessThan(
            moved.frame.minY,
            displaced.frame.minY,
            "the dragged hike should have come to rest above the row it was dropped on"
        )

        // Leaving reorder mode, which is also the only way back to tapping a
        // row: while it is on, the same control is *Done* rather than the sort
        // menu, and asserting the menu without this fails on a list that is
        // working perfectly.
        app.buttons["hike-order-done-button"].tap()

        // The way back appears only once the order is the hiker's own, which
        // is also the only sign the list is no longer in date order.
        XCTAssertTrue(
            app.buttons["hike-order-button"].waitForExistence(timeout: UITestTimeout.existence),
            "a hand-ordered list should offer the way back to date order"
        )
        // And the drag outlived the mode it was made in.
        XCTAssertLessThan(
            hikeRow(titled: "Seeded Trail 3", in: app).frame.minY,
            hikeRow(titled: "Seeded Trail 1", in: app).frame.minY,
            "the order should survive leaving reorder mode"
        )
    }
}
