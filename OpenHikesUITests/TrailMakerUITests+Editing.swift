//
//  TrailMakerUITests+Editing.swift
//  OpenHikesUITests
//
//  *Edit Route* on a saved drawn trail: the line editor, as on a recording or
//  an import. The maker keeps nothing of how a trail was drawn, so there are
//  no stops to reopen it on.
//

import XCTest

extension TrailMakerUITests {
    private static let drawnTrailName = "Drawn Ridge"
    private static let firstStopX = 0.45
    private static let firstStopY = 0.20
    private static let secondStopX = 0.65
    private static let secondStopY = 0.30
    private static let firstStop = CGVector(dx: firstStopX, dy: firstStopY)
    private static let secondStop = CGVector(dx: secondStopX, dy: secondStopY)

    @MainActor
    func testASavedTrailIsEditedLikeAnyLine() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))
        openTrailMaker(in: app)
        drawTrailPoints([Self.firstStop, Self.secondStop], on: map, in: app)
        element("trail-draft-save", in: app).tap()
        nameTheTrail(Self.drawnTrailName, in: app)
        XCTAssertTrue(
            app.navigationBars[Self.drawnTrailName].waitForExistence(timeout: UITestTimeout.navigation),
            "saving should open the trail it just made"
        )

        openEditRoute(in: app)
        XCTAssertTrue(
            element("route-trim-save", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "Edit Route should open the line editor, not the maker"
        )
    }
}
