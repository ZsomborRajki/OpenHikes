//
//  MapModesSupport.swift
//  OpenHikesUITests
//
//  *Map Modes*, opened from the pill on the map, for every suite that needs a
//  map other than the default, or the hiking routes over it: the settings
//  tests, the trail maker's, the labels, the audit and the screenshot set.
//

import XCTest

extension XCTestCase {
    /// Opens *Map Modes* from the map's own button and waits for its cards.
    ///
    /// The button rides the sheet as far as its middle detent and is gone
    /// above it, so this is for a launch whose sheet rests at one of those.
    @MainActor
    func openMapModes(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        tapWhenReady(element("map-modes-button", in: app), file: file, line: line)
        XCTAssertTrue(
            element("map-modes-title", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the map-modes button should open Map Modes",
            file: file,
            line: line
        )
    }

    /// Drags the map sheet down from its large detent, which covers the
    /// map-modes button, and waits until the button can be tapped: for a
    /// test that comes back from a screen that raised the sheet.
    @MainActor
    func lowerSheetToMapModesButton(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(
            grabber.waitForExistence(timeout: UITestTimeout.navigation),
            "the sheet offers a grabber",
            file: file,
            line: line
        )
        let middle = CGVector(dx: Self.mapModesMiddle, dy: Self.mapModesMiddle)
        let foot = CGVector(dx: Self.mapModesMiddle, dy: Self.mapModesSheetFoot)
        grabber.coordinate(withNormalizedOffset: middle)
            .press(forDuration: Self.mapModesDragPress, thenDragTo: app.coordinate(withNormalizedOffset: foot))
        XCTAssertTrue(
            waitUntil { element("map-modes-button", in: app).isHittable },
            "the map-modes button should be in reach once the sheet is down",
            file: file,
            line: line
        )
    }

    /// Closes *Map Modes* with its ✕ and waits for it to be gone, so the
    /// next tap lands on what was under it.
    @MainActor
    func closeMapModes(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        element("map-modes-close", in: app).tap()
        XCTAssertTrue(
            waitUntil { !element("map-modes-title", in: app).exists },
            "the ✕ should close Map Modes",
            file: file,
            line: line
        )
    }

    /// Picks one of the catalog's maps on *Map Modes*, by its provider id,
    /// and closes the sheet again.
    ///
    /// A paid one is only offered to an entitled launch with its key bundled,
    /// which is what the failure says.
    @MainActor
    func selectMap(
        _ providerID: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openMapModes(in: app, file: file, line: line)
        let card = element("provider-row-\(providerID)", in: app)
        XCTAssertTrue(
            card.waitForExistence(timeout: UITestTimeout.navigation),
            "Map Modes should offer \(providerID) — a paid map needs --ui-test-entitled and its key in "
                + "OpenHikes/Secrets.plist",
            file: file,
            line: line
        )
        card.tap()
        XCTAssertTrue(
            waitUntilSelected(card),
            "the tapped map should become the selected one",
            file: file,
            line: line
        )
        closeMapModes(in: app, file: file, line: line)
    }

    /// Chooses one of the *Hiking Routes* pictures on *Map Modes* — the
    /// routes when `shown`, the clean map otherwise — and closes the sheet.
    @MainActor
    func chooseHikingRoutes(
        shown: Bool,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openMapModes(in: app, file: file, line: line)
        let picture = element(shown ? "hiking-routes-on" : "hiking-routes-off", in: app)
        XCTAssertTrue(
            picture.waitForExistence(timeout: UITestTimeout.navigation),
            "Map Modes should offer the hiking routes under its cards",
            file: file,
            line: line
        )
        picture.tap()
        XCTAssertTrue(
            waitUntilSelected(picture),
            "the tapped picture should become the chosen one",
            file: file,
            line: line
        )
        closeMapModes(in: app, file: file, line: line)
    }

    // The drag that lowers the sheet: a short press on the grabber, then down
    // to the foot of the window.
    private static let mapModesMiddle: CGFloat = 0.5
    private static let mapModesSheetFoot: CGFloat = 0.95
    private static let mapModesDragPress: TimeInterval = 0.1
}
