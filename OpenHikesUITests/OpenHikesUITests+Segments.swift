//
//  OpenHikesUITests+Segments.swift
//  OpenHikesUITests
//
//  The segments a hike's pauses cut it into, on the saved hike (#1470).
//
//  A segment needs no recording of this app's to exist: a GPX file with two
//  `<trkseg>` is a walk with a break in it, and its hike shows the two.
//

import XCTest

extension OpenHikesUITests {
    private static let shopStopFixture = "ThumseeShopStop"
    private static let shopStopTitle = "Thumsee Shop Stop (simulated)"

    /// A walk to the shop, twenty minutes inside, and the walk home: two
    /// segments, and the stop between them by its length.
    @MainActor
    func testAHikeWithAPauseShowsItsSegments() {
        let app = launchApp(
            arguments: ["--ui-test-expanded-sheet", "--ui-test-import-gpx=\(Self.shopStopFixture)"]
        )
        openHikeDetail(in: app, titled: Self.shopStopTitle)

        let segments = app.descendants(matching: .any).matching(identifier: "hike-segment")
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) { segments.count == 2 },
            "a hike with one pause should show two segments; found \(segments.count)"
        )
        let first = segments.element(boundBy: 0)
        XCTAssertEqual(first.label, "Segment 1")
        let spoken = first.value as? String ?? ""
        XCTAssertTrue(
            spoken.contains("10 minutes"),
            "a segment is spoken with its own time; it said \"\(spoken)\""
        )
        XCTAssertEqual(segments.element(boundBy: 1).label, "Segment 2")
        // Read by its spoken value, as the segment above is: the drawn "20m"
        // is shorthand the row hands VoiceOver in words.
        let stop = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND value BEGINSWITH %@", "Paused", "20 minutes"))
            .firstMatch
        XCTAssertTrue(stop.exists, "the stop between the two is spoken by its length")
    }

    /// A hike in one piece has no card at all: one segment is the hike, which
    /// the figures above already are.
    @MainActor
    func testAHikeInOnePieceShowsNoSegments() {
        let app = launchApp(
            arguments: ["--ui-test-expanded-sheet", "--ui-test-import-gpx=\(UITestFixture.gpxName)"]
        )
        openHikeDetail(in: app)

        // Waited for by something the same pass draws, so that "no segments"
        // is read off a card that has its figures.
        XCTAssertTrue(app.staticTexts["Statistics"].waitForExistence(timeout: UITestTimeout.existence))
        // By the rows' own identifier, never by the absence of a caption:
        // XCUI lists drawn text that VoiceOver never stops on.
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "hike-segment").count, 0)
    }
}
