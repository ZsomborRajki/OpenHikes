//
//  OpenHikesUITests+DeleteFromScreen.swift
//  OpenHikesUITests
//
//  *Delete Hike* at the foot of a hike's own screen, which deletes the hike
//  while that screen is still up: the pop that takes it away draws it once
//  more, over a row the store no longer holds. 1.7.1 (3) crashed there when
//  the hike had a change not yet saved, in the action row's Share payload,
//  reading the deleted hike's photographs — see
//  ``Hike/resolveDecodedColumns()``. The list's swipe never met this, because
//  no screen about the hike is up when the list is — see
//  `testDeletingAHikeClearsItsScreenAndItsRow`.
//

import XCTest

extension OpenHikesUITests {
    /// A change of the hike's own that the deletion commits first. On a
    /// device that is what opening a new hike writes, its surface and
    /// difficulty, which no UI launch fetches; *Follow* is the one-tap write
    /// of the same kind.
    @MainActor
    func testDeletingAHikeFromItsOwnScreen() {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
        ])
        openHikeDetail(in: app)

        let follow = element("follow-trail-toggle", in: app)
        XCTAssertTrue(follow.waitForExistence(timeout: UITestTimeout.existence))
        let following = follow.value as? String
        follow.tap()
        XCTAssertTrue(
            waitUntilValueChanges(from: following, on: follow),
            "Follow should switch, which writes the hike"
        )

        scrollToTap(element("hike-delete", in: app), in: app, attempts: 15)
        confirmDestructive(
            "Delete Hike",
            in: app,
            failureMessage: "Delete Hike should ask before taking the hike"
        )

        let screen = app.navigationBars[UITestFixture.importedHikeTitle]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: screen)
        waitForExpectations(timeout: UITestTimeout.existence)
        XCTAssertTrue(
            element("map-sheet", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the sheet should be back at its root once the hike's screen has gone"
        )
        XCTAssertEqual(
            app.state,
            .runningForeground,
            "deleting a hike from its own screen must not take the app down"
        )
    }
}
