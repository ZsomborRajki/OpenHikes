//
//  ScreenshotUITests+Alignment.swift
//  OpenHikesUITests
//
//  Title and footer framing share the same bounded drag loop. Stop if the
//  scroll limit leaves the element unchanged, retaining the actual display
//  as evidence instead of spending every remaining gesture on that limit.
//

import XCTest

enum ScreenshotViewportEdge {
    case bottom
    case top
}

extension ScreenshotUITests {
    @MainActor
    func attachScreenshotEvidence(named name: String, in app: XCUIApplication) {
        let evidence = XCTAttachment(screenshot: screenshotDisplay(in: app).screen.screenshot())
        evidence.name = name
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor
    func alignInScreenshotViewport(
        _ element: XCUIElement,
        edge: ScreenshotViewportEdge,
        tolerance: CGFloat,
        in app: XCUIApplication,
        named name: String,
        leadingDrag: Bool = false
    ) {
        let container = scrollContainer(in: app)
        let display = screenshotDisplay(in: app)
        var previous: CGRect?
        for _ in 0..<12 {
            let viewport = container.frame.intersection(windowFrame(of: app)).insetBy(dx: 0, dy: 12)
            let frame = element.frame
            let delta = edge == .top ? viewport.minY - frame.minY : viewport.maxY - frame.maxY
            let aligned = edge == .top ? delta <= 0 && delta > -tolerance : delta >= 0 && delta < tolerance
            if aligned, frame.minY >= viewport.minY, frame.maxY <= viewport.maxY { return }
            if frame == previous { break }
            previous = frame
            let reach = viewport.height / 2
            let requested = min(max(delta, -reach), reach)
            let distance = abs(requested) < 24 ? (requested < 0 ? -24.0 : 24.0) : requested
            let start = CGPoint(x: leadingDrag ? container.frame.minX + 8 : viewport.midX, y: viewport.midY)
            XCTAssertTrue(ScreenshotDisplayGesture.drag(
                from: start, to: CGPoint(x: start.x, y: start.y + distance), on: display
            ))
        }
        attachScreenshotEvidence(named: "\(name) did not settle", in: app)
        XCTFail("\(name) should align with the visible scrolling viewport")
    }
}
