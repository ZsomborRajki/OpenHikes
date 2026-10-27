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
    /// The place, as the hiker would keep it: a viewpoint of their own, named
    /// for what it looks at rather than after the Archenkanzel a little way
    /// off the line, which the map labels where it really stands.
    private static var placeName: String { screenshotIsGerman ? "Über dem Königssee" : "Above the Königssee" }
    private static var placeNote: String {
        screenshotIsGerman
            ? "Der ganze See liegt unter dir, die Boote fahren nach St. Bartholomä."
            : "The whole lake below, and the boats in to St. Bartholomä."
    }

    /// Which of the stamped photographs the place is given, by where the
    /// system picker lists them: newest first, so the second and the third
    /// are the two taken from up here — the lake from above, once over the
    /// meadow and once from the platform. The simulator's own stock
    /// photographs are older than any stamped one and come after them.
    private static let placePhotoIndexes = [1, 2]

    /// Where a picker tile is tapped, as shares of its width and height: near
    /// its bottom-leading corner, clear of the toolbar the closed iPhone Duo's
    /// picker draws over the top of the grid's trailing column. Anywhere on a
    /// tile picks it.
    private static let tileTapX: CGFloat = 0.2
    private static let tileTapY: CGFloat = 0.8

    /// A place of the hiker's own, open on its screen with two photographs.
    ///
    /// Made the way a hiker makes one: *Add Place* from the map's pill, two
    /// pictures from the library, a name and a note, then *Add*. The pill puts
    /// the place where the elevation graph's tracker stands, so the chart is
    /// tapped first: a hike that has just been opened keeps it at the start,
    /// which is a car park in Schönau and reads "0 m along the route".
    ///
    /// A viewpoint, which is the kind the form starts at — so the frame
    /// changes nothing it does not have to. It used to be St. Bartholomä,
    /// which is a chapel and a landing and no kind the form offers, and came
    /// out labelled *Viewpoint* by default.
    ///
    /// Nothing is seeded: the Königssee fixture carries no `<wpt>`,
    /// deliberately, because a place in it would stand on the map in every
    /// other frame too.
    ///
    /// The photographs are the stamped library the hero frames use, picked in
    /// the system's own picker. The form files them under the place, so the
    /// strip on the place screen is ``HikePhoto/placeID`` doing its job rather
    /// than the hike's gallery shown again — and pins them at the place, under
    /// its own pin.
    @MainActor
    func testCapturesAPlaceAndItsPhotos() throws {
        try XCTSkipUnless(Self.hasStampedLibrary, Self.noStampedLibrary)
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(Self.routeFixture)",
            "--ui-test-weather",
            Self.routeHueArgument,
        ])
        openHikeDetail(in: app, titled: Self.routeTitle)

        // The viewpoint is three fifths of the way along this trail.
        selectChartProgress(60, in: app)

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
        // Brought into view before it is counted. The strip is a lazy stack,
        // which builds no thumbnails while it is off screen — and on a screen
        // shorter than the 6.9" one, the closed iPhone Duo's 678 points, it
        // starts below the fold. Where it is already in view this moves
        // nothing.
        let strip = element("hike-place-photos", in: app)
        XCTAssertTrue(
            strip.waitForExistence(timeout: UITestTimeout.trace),
            "the place should file the photographs it was given"
        )
        scrollIntoView(strip, in: app)
        let thumbnails = strip.images
        let bothFiled = NSPredicate { _, _ in thumbnails.count == Self.placePhotoIndexes.count }
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [expectation(for: bothFiled, evaluatedWith: thumbnails)],
                timeout: UITestTimeout.trace
            ),
            .completed,
            "both photographs should be filed under the place"
        )
        capture(as: .place, of: app)
    }

    /// Picks `indexes` of the library's photographs in the system picker the
    /// form presents, and confirms them.
    ///
    /// The picker runs out of process, but its grid and buttons reach the
    /// app's accessibility tree — `PhotoUITests` cancels it the same way. The
    /// photographs are its images labelled "Photo, " and a date, in the order
    /// the grid lists them, which is newest first by the date the stamper
    /// wrote into each.
    ///
    /// The comma is load-bearing. The form's own *Add Photos* glyph is an
    /// image labelled "Photo On A Rectangle", and on the closed iPhone Duo it
    /// stays in the tree under the picker: matched by "Photo" alone it stood
    /// in for the grid while the picker was still loading, and once the grid
    /// was in, it moved every index along by one.
    ///
    /// Each tile is found by its label, read before anything is picked, and
    /// tapped near its bottom-leading corner. A tile bound by index is
    /// resolved again at the tap, and picking one moved the rest along under
    /// it; and on the closed Duo the picker draws its own toolbar over the top
    /// of the grid's trailing column, where a tap at a tile's centre landed on
    /// the toolbar's glass and picked nothing.
    @MainActor
    private func pickLibraryPhotos(_ indexes: [Int], in app: XCUIApplication) {
        element("hike-place-adder-library", in: app).tap()
        let photos = app.images.matching(
            NSPredicate(format: "label BEGINSWITH %@", Self.screenshotIsGerman ? "Foto, " : "Photo, ")
        )
        // The out-of-process picker can show its toolbar while its grid is
        // still empty. Wait for every tile we need, not just its first image.
        let lastIndex = indexes.max() ?? 0
        guard waitUntil(timeout: UITestTimeout.trace, { photos.count > lastIndex }) else {
            let evidence = XCTAttachment(screenshot: screenshotDisplay(in: app).screen.screenshot())
            evidence.name = "Photo picker did not load its library"
            evidence.lifetime = .keepAlways
            add(evidence)
            XCTFail("the photo picker should list the stamped library — check that Scripts/screenshots.sh added it")
            return
        }
        let tiles = photos.allElementsBoundByIndex
        let labels = indexes.compactMap { index -> String? in
            XCTAssertTrue(tiles.indices.contains(index), "the library should hold photo \(index)")
            return tiles.indices.contains(index) ? tiles[index].label : nil
        }
        for label in labels {
            photos.matching(NSPredicate(format: "label == %@", label)).firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: Self.tileTapX, dy: Self.tileTapY))
                .tap()
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
