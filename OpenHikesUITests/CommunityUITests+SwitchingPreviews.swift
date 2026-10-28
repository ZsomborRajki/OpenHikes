//
//  CommunityUITests+SwitchingPreviews.swift
//  OpenHikesUITests
//
//  One stranger's preview replaced by another's, from the map behind it.
//
//  A pin tapped over an open preview replaces it rather than stacking on it —
//  see ``SheetPresentation/showCommunityHike(_:)``. The path went from `[A]` to
//  `[B]`, and the screen took the new title and kept everything else: the
//  route, the photographs and the Add button were still A's until the hiker
//  backed out and opened B again.
//

import XCTest

extension CommunityUITests {
    private static let pinClearance: CGFloat = 12
    /// A downward pan on open map, to the right of the search pill and pins.
    private static let pinPanX: CGFloat = 0.8
    private static let pinPanStartY: CGFloat = 0.18
    private static let pinPanEndY: CGFloat = 0.36
    private static let pinPanStart = CGVector(dx: pinPanX, dy: pinPanStartY)
    private static let pinPanEnd = CGVector(dx: pinPanX, dy: pinPanEndY)
    private static let pinPanPress: TimeInterval = 0.1

    /// The ridge from its row, then the lake from its pin: the page is the
    /// lake's.
    ///
    /// The strip is the tell, counted rather than looked for, because both
    /// hikes have one: the ridge's own two photographs, and the three Cass
    /// contributed to the lake. A third tile is the lake's page; a page that
    /// kept the ridge's answer never draws one.
    ///
    /// That way round because it is the one the map allows: the ridge's
    /// framing leaves the lake's pin above the sheet, and the scramble's —
    /// the hike with no photographs at all — leaves it under it.
    @MainActor
    func testOpeningAnotherHikesPinOverAPreviewShowsThatHike() {
        XCUIDevice.shared.orientation = .portrait
        let app = launchCommunity(scenario: .seeded)
        let isPortrait = waitUntil(timeout: UITestTimeout.navigation) {
            let window = app.windows.firstMatch
            return window.exists && window.frame.height > window.frame.width
        }
        guard isPortrait else {
            XCTFail("precondition: this above-sheet pin scenario needs a portrait window")
            return
        }
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: app)
        let lastLakePhoto = communityPhotoTile(at: SeededContribution.photoCount - 1, in: app)
        XCTAssertTrue(
            communityPhotoTile(at: SeededHike.ridgePhotoCount - 1, in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "precondition: the ridge's preview shows its photographs"
        )
        XCTAssertFalse(lastLakePhoto.exists, "precondition: and only its own two")

        let lakePin = app.descendants(matching: .any)
            .matching(identifier: "community-hike-pin")
            .matching(NSPredicate(format: "label CONTAINS %@", SeededHike.lakeTitle))
            .firstMatch
        guard revealCommunityPin(lakePin, in: app) else {
            XCTFail("precondition: the lake's entire marker is clear of the top controls and sheet")
            return
        }
        XCTAssertTrue(
            app.navigationBars[SeededHike.ridgeTitle].exists,
            "precondition: revealing the lake marker keeps the ridge's preview open"
        )
        tapWhenReady(lakePin)
        tapWhenReady(element("community-pin-open", in: app))

        XCTAssertTrue(
            app.navigationBars[SeededHike.lakeTitle].waitForExistence(timeout: UITestTimeout.navigation),
            "the lake's pin should open the lake's preview"
        )
        XCTAssertTrue(
            lastLakePhoto.waitForExistence(timeout: UITestTimeout.trace),
            "the lake's page shows Cass's three photographs; two is the ridge's page under the lake's title"
        )
    }

    /// The ridge's framing can leave the lake marker beside the Dynamic
    /// Island. XCUITest reports it hittable there even when the native callout
    /// does not open. Move it into open map before the test's one pin tap,
    /// waiting on the marker's actual frame rather than a pan duration.
    @MainActor
    private func revealCommunityPin(_ pin: XCUIElement, in app: XCUIApplication) -> Bool {
        guard pin.waitForExistence(timeout: UITestTimeout.navigation) else { return false }
        let window = windowFrame(of: app)
        let search = element("community-search-this-area", in: app)
        let sheet = element("map-sheet", in: app)
        guard search.waitForExistence(timeout: UITestTimeout.navigation),
              sheet.waitForExistence(timeout: UITestTimeout.navigation) else { return false }
        let searchFrame = search.frame
        let sheetFrame = sheet.frame
        guard !searchFrame.isEmpty, !sheetFrame.isEmpty else { return false }
        let top = max(searchFrame.maxY, window.minY) + Self.pinClearance
        let clearMap = CGRect(
            x: window.minX + Self.pinClearance,
            y: top,
            width: window.width - 2 * Self.pinClearance,
            height: sheetFrame.minY - Self.pinClearance - top
        )
        guard !clearMap.isEmpty else { return false }
        if clearMap.contains(pin.frame), isReachable(pin, in: app) { return true }

        let map = element("trail-map", in: app)
        map.coordinate(withNormalizedOffset: Self.pinPanStart)
            .press(forDuration: Self.pinPanPress, thenDragTo: map.coordinate(withNormalizedOffset: Self.pinPanEnd))
        return waitUntil(timeout: UITestTimeout.navigation) {
            pin.exists && clearMap.contains(pin.frame) && isReachable(pin, in: app)
        }
    }
}
