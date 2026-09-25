//
//  TrailMakerUITests+Editing.swift
//  OpenHikesUITests
//
//  *Edit Route*: a saved drawn trail reopens in the maker on its own stops,
//  and saving writes back into the same trail rather than a second one.
//

import XCTest

extension TrailMakerUITests {
    private static let editedTrailName = "Edited Ridge"
    private static let firstStopX = 0.45
    private static let firstStopY = 0.20
    private static let secondStopX = 0.65
    private static let secondStopY = 0.30
    private static let addedStopX = 0.50
    private static let addedStopY = 0.42
    private static let firstStop = CGVector(dx: firstStopX, dy: firstStopY)
    private static let secondStop = CGVector(dx: secondStopX, dy: secondStopY)
    private static let addedStop = CGVector(dx: addedStopX, dy: addedStopY)

    @MainActor
    func testEditingASavedTrailWritesBackIntoIt() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))
        openTrailMaker(in: app)
        drawTrailPoints([Self.firstStop, Self.secondStop], on: map, in: app)
        element("trail-draft-save", in: app).tap()
        nameTheTrail(Self.editedTrailName, in: app)
        XCTAssertTrue(
            app.navigationBars[Self.editedTrailName].waitForExistence(timeout: UITestTimeout.navigation),
            "saving should open the trail it just made"
        )

        let editRoute = element("hike-edit-route", in: app)
        XCTAssertTrue(
            editRoute.waitForExistence(timeout: UITestTimeout.existence),
            "a trail drawn in the maker should offer Edit Route"
        )
        // In the list that closes the card, below the fold.
        scrollToTap(editRoute, in: app, attempts: 12)
        XCTAssertTrue(
            app.navigationBars["Edit Trail"].waitForExistence(timeout: UITestTimeout.navigation),
            "Edit Route should open the maker on the trail"
        )
        XCTAssertTrue(
            element("trail-draft-point-2", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "with the stops it was drawn from"
        )

        drawTrailPoints([Self.addedStop], on: map, in: app)
        XCTAssertTrue(element("trail-draft-point-3", in: app).waitForExistence(timeout: UITestTimeout.existence))
        // No name prompt: an edit keeps the name it has.
        element("trail-draft-save", in: app).tap()
        XCTAssertTrue(
            app.navigationBars[Self.editedTrailName].waitForExistence(timeout: UITestTimeout.navigation),
            "saving the edit should come back to the same trail"
        )

        popScreen(in: app)
        awaitHikeRow(titled: Self.editedTrailName, in: app)
        let rows = app.descendants(matching: .any)
            .matching(identifier: "hike-row")
            .matching(NSPredicate(format: "label BEGINSWITH %@", Self.editedTrailName))
        XCTAssertEqual(rows.count, 1, "an edit writes into the trail, never beside it")
    }
}
