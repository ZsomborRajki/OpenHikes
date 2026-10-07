//
//  WalkUITests+Share.swift
//  OpenHikesUITests
//
//  Sharing a walk as a picture: *Share* on the summary, a photograph chosen
//  from the hike's own, and the card editor over it — a box that moves when
//  dragged, its options when tapped, and the share item ready to send.
//

import XCTest

extension WalkUITests {
    @MainActor
    func testSharingAWalkPutsItsFiguresOverAChosenPhoto() {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            "--ui-test-seed-walks=HalfLoop",
            "--ui-test-seed-photos=2",
        ])
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

        let photo = app.buttons["walk-share-photo-0"]
        XCTAssertTrue(photo.waitForExistence(timeout: UITestTimeout.navigation), "the hike's photos are offered")
        XCTAssertTrue(app.buttons["walk-share-library"].exists, "and the library beside them")
        photo.tap()

        let stats = app.descendants(matching: .any).matching(identifier: "walk-share-box-stats").firstMatch
        XCTAssertTrue(stats.waitForExistence(timeout: UITestTimeout.navigation), "the editor opens on the photo")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "walk-share-box-route").firstMatch.exists)
        attachScreenshot(of: app, named: "Share card, as opened")

        // Down and to the left, far enough from the middle not to snap to it
        // and nowhere near an edge, so the box should land exactly there.
        let before = stats.frame
        let move = CGVector(dx: -Self.shareDragAcross, dy: Self.shareDragDown)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let grab = origin.withOffset(CGVector(dx: before.midX, dy: before.midY))
        grab.press(forDuration: Self.shareDragPress, thenDragTo: grab.withOffset(move))
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) {
                abs(stats.frame.midX - (before.midX + move.dx)) < 2
                    && abs(stats.frame.midY - (before.midY + move.dy)) < 2
            },
            "a dragged box stays where it was let go"
        )

        let controls = app.descendants(matching: .any).matching(identifier: "walk-share-controls").firstMatch
        XCTAssertTrue(
            controls.waitForExistence(timeout: UITestTimeout.existence),
            "the box just moved shows its options"
        )
        attachScreenshot(of: app, named: "Share card, stats moved and selected")
        stats.tap()
        XCTAssertTrue(controls.waitForNonExistence(timeout: UITestTimeout.existence), "a second tap puts them away")
        stats.tap()
        XCTAssertTrue(controls.waitForExistence(timeout: UITestTimeout.existence), "and a third brings them back")
        XCTAssertTrue(app.buttons["walk-share-send"].isEnabled, "the card is ready to send")
    }

    private static let shareDragAcross: CGFloat = 60
    private static let shareDragDown: CGFloat = 250
    private static let shareDragPress: TimeInterval = 0.2

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
