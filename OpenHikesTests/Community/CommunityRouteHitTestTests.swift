//
//  CommunityRouteHitTestTests.swift
//  OpenHikesTests
//
//  Which shared trail a thumb landed on, without a map in the room.
//
//  The geometry is separated from the map for exactly this: a tap on a
//  polyline is the one interaction MapKit gives nothing for, so the rule about
//  what counts as a hit is this app's own and is worth stating in numbers a
//  test can hold. `MapCoordinatorTests+CommunityRoutes.swift` covers the half
//  that needs a real `MKMapView` — that the lines are installed and that a tap
//  reaches this at all.
//

import CoreGraphics
@testable import OpenHikes
import Testing

/// Point-to-polyline distance in screen points, and the pick that follows.
@Suite("Community route hit test")
struct CommunityRouteHitTestTests {
    /// A fingertip, the same number the map uses.
    private static let tolerance: CGFloat = 22

    /// A horizontal line across the middle of a notional screen.
    private static let across = [CGPoint(x: 0, y: 100), CGPoint(x: 300, y: 100)]

    @Test("a tap on the line hits it")
    func aTapOnTheLineHits() {
        let index = CommunityRouteHitTest.nearest(
            to: CGPoint(x: 150, y: 100),
            among: [Self.across],
            tolerance: Self.tolerance
        )

        #expect(index == 0)
    }

    /// The affordance the tolerance is: a line three points wide that had to
    /// be hit exactly would not be tappable at all.
    @Test("a tap near the line hits it")
    func aTapNearTheLineHits() {
        let index = CommunityRouteHitTest.nearest(
            to: CGPoint(x: 150, y: 115),
            among: [Self.across],
            tolerance: Self.tolerance
        )

        #expect(index == 0)
    }

    /// And the other half of it: a tap on the map is still a tap on the map.
    @Test("a tap well away from the line misses")
    func aDistantTapMisses() {
        let index = CommunityRouteHitTest.nearest(
            to: CGPoint(x: 150, y: 200),
            among: [Self.across],
            tolerance: Self.tolerance
        )

        #expect(index == nil)
    }

    /// Clamped to the segment rather than to the infinite line through it.
    /// Without this, tapping empty map a hundred points past the end of a
    /// trail would open it.
    @Test("a tap past the end of the line misses")
    func aTapBeyondTheEndMisses() {
        let index = CommunityRouteHitTest.nearest(
            to: CGPoint(x: 400, y: 100),
            among: [Self.across],
            tolerance: Self.tolerance
        )

        #expect(index == nil)
    }

    /// Two published trails sharing a valley floor overlap on screen at any
    /// zoom showing both, and the hiker is aiming at the pixels under their
    /// thumb rather than at whichever the query returned first. This is the
    /// reason the pick is nearest rather than first.
    @Test("the nearest of two overlapping lines wins")
    func theNearestLineWins() {
        let far = [CGPoint(x: 0, y: 90), CGPoint(x: 300, y: 90)]
        let near = [CGPoint(x: 0, y: 108), CGPoint(x: 300, y: 108)]

        let index = CommunityRouteHitTest.nearest(
            to: CGPoint(x: 150, y: 110),
            among: [far, near],
            tolerance: Self.tolerance
        )

        #expect(index == 1)
    }

    /// A tie goes to the earlier line rather than to the later one. Nothing
    /// depends on which, but something does depend on it being decided: two
    /// lines an equal distance away must not open a different hike on each
    /// tap.
    @Test("an exact tie keeps the first line")
    func aTieIsStable() {
        let above = [CGPoint(x: 0, y: 90), CGPoint(x: 300, y: 90)]
        let below = [CGPoint(x: 0, y: 110), CGPoint(x: 300, y: 110)]

        let index = CommunityRouteHitTest.nearest(
            to: CGPoint(x: 150, y: 100),
            among: [above, below],
            tolerance: Self.tolerance
        )

        #expect(index == 0)
    }

    /// A bend is where a per-segment measure and a first-and-last one
    /// disagree, and a trail is mostly bends.
    @Test("a tap on the far leg of a bend hits it")
    func aBendIsMeasuredPerSegment() {
        let bend = [
            CGPoint.zero,
            CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 200),
        ]

        let index = CommunityRouteHitTest.nearest(
            to: CGPoint(x: 102, y: 150),
            among: [bend],
            tolerance: Self.tolerance
        )

        #expect(index == 0)
    }

    /// Zoomed far enough out, a whole route projects onto one pixel. It is
    /// still somewhere, and dividing by its length is still not allowed.
    @Test("a line collapsed onto one point is still measured")
    func aDegenerateLineIsMeasured() {
        let collapsed = Array(repeating: CGPoint(x: 50, y: 50), count: 8)

        let index = CommunityRouteHitTest.nearest(
            to: CGPoint(x: 55, y: 50),
            among: [collapsed],
            tolerance: Self.tolerance
        )

        #expect(index == 0)
    }

    @Test("nothing drawn is nothing hit")
    func nothingDrawnIsNothingHit() {
        #expect(
            CommunityRouteHitTest.nearest(
                to: CGPoint(x: 10, y: 10),
                among: [],
                tolerance: Self.tolerance
            ) == nil
        )
        #expect(CommunityRouteHitTest.distance(from: CGPoint(x: 10, y: 10), to: []) == nil)
    }
}
