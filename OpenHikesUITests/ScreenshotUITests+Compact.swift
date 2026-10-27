//
//  ScreenshotUITests+Compact.swift
//  OpenHikesUITests
//
//  The Duo's cover has less vertical space than the other capture windows.
//  Compose the gallery around its footer, without the next section or half
//  an action row, and return the maker from its search-expanded sheet to the
//  middle detent so the route it made can be seen.
//

import XCTest

extension ScreenshotUITests {
    private static let compactCaptureHeight: CGFloat = 750
    private static let compactMakerExpandedTarget: CGFloat = 0.1
    private static let compactMakerExpandedTop: CGFloat = 0.25
    private static let compactMakerDragTarget: CGFloat = 0.55
    private static let compactMakerTopRange: ClosedRange<CGFloat> = 0.35...0.65

    @MainActor
    private func isCompactCapture(in app: XCUIApplication) -> Bool {
        windowFrame(of: app).height < Self.compactCaptureHeight && !element("map-side-panel", in: app).exists
    }

    @MainActor
    func positionCompactScreenshotGallery(in app: XCUIApplication) -> Bool {
        guard isCompactCapture(in: app) else { return false }
        let footer = app.staticTexts[screenshotText("Tap a photo to see it, and where on the trail it was taken.")]
        XCTAssertTrue(scrollIntoView(footer, in: app), "the gallery footer should be reachable")
        alignInScreenshotViewport(footer, edge: .bottom, tolerance: 12, in: app, named: "Compact gallery")
        return true
    }

    @MainActor
    func expandCompactMakerForSearch(in app: XCUIApplication) {
        guard isCompactCapture(in: app) else { return }
        let window = windowFrame(of: app)
        dragSheet(in: app, to: Self.compactMakerExpandedTarget)
        let sheet = element("map-sheet", in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                sheet.frame.minY < window.height * Self.compactMakerExpandedTop
            },
            "the maker should expand before searching so Add Stop stays clear of the cover’s bottom edge"
        )
    }

    @MainActor
    func restoreCompactMakerDetent(in app: XCUIApplication) {
        guard isCompactCapture(in: app) else { return }
        let window = windowFrame(of: app)
        dragSheet(in: app, to: Self.compactMakerDragTarget)
        let sheet = element("map-sheet", in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                Self.compactMakerTopRange.contains(sheet.frame.minY / window.height)
            },
            "the maker should return to its middle detent so its route is visible"
        )
    }
}
