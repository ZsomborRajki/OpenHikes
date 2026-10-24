//
//  ScrollSupport.swift
//  OpenHikesUITests
//
//  Bringing an element into reach by scrolling, for every class in this bundle.
//  Out of `UITestSupport.swift` for length, beside the reachability test and
//  the container lookup it is built on, which stay there.
//

import XCTest

extension XCTestCase {
    /// Swipes the screen's scrolling container until the target is reachable.
    ///
    /// A row below the fold is not merely off-screen: SwiftUI builds `List`
    /// and `Form` rows lazily, so it may be absent from the element tree
    /// altogether, which is why this waits on `exists` rather than assuming it.
    ///
    /// A swipe is a fling, and it can carry a target straight past the part of
    /// the container that shows anything: on the closed iPhone Duo, 678 points
    /// tall, *Find Photos* went from just under the bottom edge to under the
    /// hike screen's pinned header in one swipe, and every swipe after that
    /// only took it further up. So a target that has gone above the container
    /// is drawn back down by a drag that does not fling, rather than swiped
    /// past again.
    ///
    /// **Drawn back until it is below the container's top edge, before it is
    /// asked whether it is in reach.** The hike screen's header is pinned over
    /// the top of its scroll view in glass, and XCUITest counts a row under
    /// glass as hittable — so the elevation chart, drawn back only as far as
    /// the header, answered yes, and the tap aimed at its middle landed on
    /// *Details | History*. A target that is in reach before anything has
    /// moved — a button in that same header — is left where it is.
    @MainActor
    @discardableResult func scrollIntoView(
        _ target: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 8
    ) -> Bool {
        let container = scrollContainer(in: app)
        var drawingBack = false
        for _ in 0..<attempts {
            let shown = shownArea(of: container)
            let isAbove = shown.map { target.exists && target.frame.minY < $0.minY } ?? false
            if !(drawingBack && isAbove), isReachable(target, in: app) { return true }
            if let shown, isAbove {
                drawingBack = true
                drawBack(target, into: shown, of: container)
            } else {
                container.swipeUp()
            }
        }
        return isReachable(target, in: app)
    }

    /// The container's frame, or `nil` once it has gone — measured through a
    /// snapshot for the reason ``scrollContainer(in:)`` gives.
    @MainActor
    private func shownArea(of container: XCUIElement) -> CGRect? {
        guard let frame = try? container.snapshot().frame, frame.height > 0 else { return nil }
        return frame
    }

    /// Drags the content down until `target` is a third of the way into
    /// `shown`, at most ``drawBackReach`` of it per gesture.
    ///
    /// Pressed, dragged slowly and held before it lets go, which is what keeps
    /// it from being a fling: the content moves by the drag and stops there.
    /// It starts in the screen's own margin, where no row, chart or control
    /// begins a gesture of its own — a drag that began on the elevation chart
    /// would scrub it instead of scrolling — and the content cannot be at its
    /// top, since the target is above it, so the drag scrolls rather than
    /// lowering the sheet.
    @MainActor
    private func drawBack(_ target: XCUIElement, into shown: CGRect, of container: XCUIElement) {
        let wanted = shown.minY + shown.height * Self.drawBackLanding - target.frame.minY
        let distance = min(wanted, shown.height * Self.drawBackReach)
        let start = container.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: Self.drawBackStart))
            .withOffset(CGVector(dx: Self.drawBackMarginInset, dy: 0))
        start.press(
            forDuration: Self.drawBackPress,
            thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
            withVelocity: .slow,
            thenHoldForDuration: Self.drawBackPress
        )
    }

    /// Where in the container a drawn-back target is aimed: a third of the
    /// way down, clear of the edge it came in from.
    private static let drawBackLanding: CGFloat = 1.0 / 3
    /// The most of the container one drawing-back drag covers, so it starts
    /// and ends inside it.
    private static let drawBackReach: CGFloat = 0.6
    /// Where that drag starts, as a share of the container's height.
    private static let drawBackStart: CGFloat = 0.2
    /// And how far in from the container's leading edge: inside the margin the
    /// app's scrolling screens keep, which on the hike screen is sixteen
    /// points.
    private static let drawBackMarginInset: CGFloat = 8
    /// How long it presses before moving and holds before letting go — long
    /// enough to be a drag and to leave no fling behind.
    private static let drawBackPress: TimeInterval = 0.2
}
