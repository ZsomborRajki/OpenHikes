//
//  ScreenshotUITests+Place.swift
//  OpenHikesUITests
//
//  App Store frame 09, a place on a saved hike, in a file of its own for the
//  reason frame 08 has one: `ScreenshotUITests.swift` is at the length the
//  linter allows, and an extension keeps it inside the one suite
//  `Scripts/screenshots.sh` runs.
//

import XCTest

extension ScreenshotUITests {
    /// The place the walk ends at, as the hiker would keep it.
    private static let placeName = "St. Bartholomä"
    private static let placeNote = "Boats back to Schönau every half hour."

    /// Where on the elevation chart the place is put, as a share of the
    /// chart element's width: near the far end, on the flat lakeside stretch
    /// into St. Bartholomä. The plot stops at about 0.88 of the element —
    /// the elevation labels stand to the right of it — and a tap on them
    /// selects nothing, which is how 0.97 failed.
    private static let placeChartPosition: CGFloat = 0.86

    /// Which of the stamped photographs the place is given, by where the
    /// system picker lists them: newest first, so the first and the eighth are
    /// the Obersee boathouse and the lake shore — the two of the eight that
    /// are of water, which is what this place is. The simulator's own stock
    /// photographs are older than any stamped one and come after them.
    private static let placePhotoIndexes = [0, 7]

    /// A place of the hiker's own, open on its screen with two photographs.
    ///
    /// Made the way a hiker makes one: *Add Place* from the map's pill, two
    /// pictures from the library, a name and a note, then *Add*. The pill puts
    /// the place where the elevation graph's tracker stands, so the chart is
    /// tapped first: a hike that has just been opened keeps it at the start,
    /// which is a car park in Schönau and reads "0 m along the route". The
    /// walk's end is on the lake, and is what the photographs are of.
    ///
    /// Nothing is seeded: the Königssee fixture carries no `<wpt>`,
    /// deliberately, because a place in it would stand on the map in every
    /// other frame too.
    ///
    /// The photographs are the stamped library the hero frames use, picked in
    /// the system's own picker. The form files them under the place, so the
    /// strip on the place screen is ``HikePhoto/placeID`` doing its job rather
    /// than the hike's gallery shown again.
    @MainActor
    func testCapturesAPlaceAndItsPhotos() throws {
        try XCTSkipUnless(Self.hasStampedLibrary, Self.noStampedLibrary)
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=KoenigsseeRinnkendlsteig",
            "--ui-test-weather",
        ])
        openHikeDetail(in: app, titled: "Königssee – Kühroint – Rinnkendlsteig – St. Bartholomä")

        let chart = element("elevation-chart", in: app)
        XCTAssertTrue(scrollIntoView(chart, in: app), "the hike should draw its elevation chart")
        let atStart = chart.value as? String ?? ""
        chart.coordinate(withNormalizedOffset: CGVector(dx: Self.placeChartPosition, dy: 0.5)).tap()
        XCTAssertTrue(
            waitUntilValueChanges(from: atStart, on: chart),
            "a tap on the chart should move the tracker to the walk's end"
        )

        let addPlace = element("map-add-place-button", in: app)
        XCTAssertTrue(
            addPlace.waitForExistence(timeout: UITestTimeout.navigation),
            "a hike's screen should offer Add Place"
        )
        addPlace.tap()
        XCTAssertTrue(
            element("hike-place-adder-title", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the pill should open the new place's form"
        )

        pickLibraryPhotos(Self.placePhotoIndexes, in: app)
        replaceText(of: app.textFields["hike-place-adder-name"], with: Self.placeName)
        replaceText(of: app.textFields["hike-place-adder-note"], with: Self.placeNote)

        // The picked photographs are still being read while the form shows a
        // spinner where *Add* goes, so the button is waited for, not assumed.
        let add = app.buttons["hike-place-adder-add"]
        XCTAssertTrue(
            add.waitForExistence(timeout: UITestTimeout.trace),
            "the form should offer Add once the picked photographs are read"
        )
        add.tap()

        let title = element("hike-place-title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: UITestTimeout.navigation), "adding should open the new place")
        XCTAssertEqual(title.label, Self.placeName)
        let thumbnails = element("hike-place-photos", in: app).images
        let bothFiled = NSPredicate { _, _ in thumbnails.count == Self.placePhotoIndexes.count }
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [expectation(for: bothFiled, evaluatedWith: thumbnails)],
                timeout: UITestTimeout.trace
            ),
            .completed,
            "both photographs should be filed under the place"
        )
        capture(as: .place)
    }

    /// Picks `indexes` of the library's photographs in the system picker the
    /// form presents, and confirms them.
    ///
    /// The picker runs out of process, but its grid and buttons reach the
    /// app's accessibility tree — `PhotoUITests` cancels it the same way. The
    /// photographs are its images whose label starts "Photo", in the order
    /// the grid lists them, which is newest first by the date the stamper
    /// wrote into each.
    @MainActor
    private func pickLibraryPhotos(_ indexes: [Int], in app: XCUIApplication) {
        element("hike-place-adder-library", in: app).tap()
        let photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'"))
        XCTAssertTrue(
            photos.firstMatch.waitForExistence(timeout: UITestTimeout.navigation),
            "the photo picker should list the stamped library — check that "
                + "Scripts/screenshots.sh added it"
        )
        let tiles = photos.allElementsBoundByIndex
        for index in indexes {
            XCTAssertTrue(tiles.indices.contains(index), "the library should hold photo \(index)")
            tiles[index].tap()
        }
        // By identifier alone. The picker's confirm button is identified
        // "Add" and labelled "Done", and the form's own *Add* behind it is
        // labelled "Add" — so `app.buttons["Add"]`, which matches either,
        // could find the button the picker is covering.
        let confirm = app.buttons.matching(NSPredicate(format: "identifier == 'Add'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: UITestTimeout.existence), "the picker should offer Add")
        confirm.tap()
        XCTAssertTrue(
            element("hike-place-adder-photos", in: app).waitForExistence(timeout: UITestTimeout.trace),
            "the picked photographs should wait in the form's strip"
        )
    }
}
