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
    private static let compactCaptureMargin: CGFloat = 12
    private static let compactGallerySlack: CGFloat = 12
    private static let compactGalleryMinimumDrag: CGFloat = 24
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
        let container = scrollContainer(in: app)
        let display = screenshotDisplay(in: app)
        for _ in 0..<12 {
            let viewport = container.frame.intersection(windowFrame(of: app))
                .insetBy(dx: 0, dy: Self.compactCaptureMargin)
            let delta = viewport.maxY - footer.frame.maxY
            if delta >= 0, delta < Self.compactGallerySlack, footer.frame.minY >= viewport.minY { return true }
            let reach = viewport.height / 2
            let requested = min(max(delta, -reach), reach)
            let distance = abs(requested) < Self.compactGalleryMinimumDrag
                ? (requested < 0 ? -Self.compactGalleryMinimumDrag : Self.compactGalleryMinimumDrag) : requested
            let start = CGPoint(x: viewport.midX, y: viewport.midY)
            XCTAssertTrue(ScreenshotDisplayGesture.drag(
                from: start, to: CGPoint(x: start.x, y: start.y + distance), on: display
            ))
        }
        let evidence = XCTAttachment(screenshot: display.screen.screenshot())
        evidence.name = "Compact gallery did not settle"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTFail("the gallery footer should sit above the bottom edge of the cover's viewport")
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
