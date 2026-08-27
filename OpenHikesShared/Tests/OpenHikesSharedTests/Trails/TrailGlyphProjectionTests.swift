//
//  TrailGlyphProjectionTests.swift
//  OpenHikesSharedTests
//
//  `TrailGlyphView.project` is the whole of the widget's fallback drawing:
//  when no basemap has rendered yet, the shape a walker recognises as their
//  trail comes from this function and nothing else. It divides by three
//  separately-floored quantities — a bounding box width, a height, and a
//  cosine — and a `Canvas` cannot be asked afterwards where it put the line,
//  so the arithmetic is asserted here rather than looked at.
//
//  The fit is the claim: the route fills the frame it is given, centred, the
//  right way up, at its own aspect ratio. Everything below is one of those
//  four, or one of the degenerate inputs the floors exist for.
//

import Foundation
@testable import OpenHikesShared
import SwiftUI
import Testing

@MainActor
@Suite("Trail glyph projection")
struct TrailGlyphProjectionTests {
    typealias Coordinate = SharedTrailSnapshot.CodableCoordinate

    /// Bigger than any rounding this arithmetic does, far smaller than any
    /// placement error a reader would call a bug.
    private static let tolerance = 1e-6

    private static let size = CGSize(width: 100, height: 100)
    private static let inset: CGFloat = 6

    private func project(
        _ polyline: [Coordinate],
        liveFix: Coordinate? = nil,
        into size: CGSize = Self.size,
        inset: CGFloat = Self.inset
    ) -> TrailGlyphView.Projected? {
        TrailGlyphView.project(polyline: polyline, liveFix: liveFix, into: size, inset: inset)
    }

    private func bounds(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Degenerate input

    @Test("an empty route projects to nothing at all")
    func emptyRouteIsNil() {
        #expect(project([]) == nil)
    }

    /// The floors exist to stop a division by zero, and a NaN would propagate
    /// silently into `Path.addLines` — a blank glyph with no diagnostic. Every
    /// degenerate shape the floors were written for is checked for finiteness
    /// in one place, so a fourth one added later has somewhere obvious to go.
    @Test(
        "no degenerate route can produce a coordinate that isn't a number",
        arguments: [
            [Coordinate(latitude: 47.6, longitude: 12.8)],
            Array(repeating: Coordinate(latitude: 47.6, longitude: 12.8), count: 5),
            [Coordinate(latitude: 47.6, longitude: 12.8), Coordinate(latitude: 47.7, longitude: 12.8)],
            [Coordinate(latitude: 47.6, longitude: 12.8), Coordinate(latitude: 47.6, longitude: 12.9)],
            [Coordinate(latitude: 89.999, longitude: 0), Coordinate(latitude: 89.999, longitude: 179)],
            [Coordinate(latitude: -89.999, longitude: -179), Coordinate(latitude: 89.999, longitude: 179)],
        ]
    )
    func degenerateRoutesStayFinite(polyline: [Coordinate]) throws {
        let projected = try #require(project(polyline, liveFix: polyline.first))
        for point in projected.points {
            #expect(point.x.isFinite && point.y.isFinite)
        }
        let liveFixPoint = try #require(projected.liveFixPoint)
        #expect(liveFixPoint.x.isFinite && liveFixPoint.y.isFinite)
    }

    /// A walker standing still publishes a snapshot whose every fix is the
    /// same coordinate. There is no extent to fit, so the only sensible answer
    /// is the middle of the glyph — the corner it used to land in read as a
    /// route that had gone off the edge of the frame.
    @Test("a route with no extent is drawn in the middle, not in a corner")
    func stationaryRouteIsCentred() throws {
        let stationary = Array(repeating: Coordinate(latitude: 47.6, longitude: 12.8), count: 4)

        let projected = try #require(project(stationary))

        for point in projected.points {
            #expect(abs(point.x - Self.size.width / 2) < Self.tolerance)
            #expect(abs(point.y - Self.size.height / 2) < Self.tolerance)
        }
    }

    /// One point is below `TrailGlyphView`'s own `count > 1` guard, so it only
    /// reaches here through a live fix — but it takes the same path, and a
    /// single point that landed off-frame would take the fix dot with it.
    @Test("a single point is treated as a route with no extent")
    func singlePointIsCentred() throws {
        let projected = try #require(project([Coordinate(latitude: 0, longitude: 0)]))

        let point = try #require(projected.points.first)
        #expect(abs(point.x - Self.size.width / 2) < Self.tolerance)
        #expect(abs(point.y - Self.size.height / 2) < Self.tolerance)
    }

    // MARK: - The fit

    /// A route wider than it is tall is limited by the width, and must use all
    /// of it: an inset on each side and nothing more. The height it is *not*
    /// limited by stays centred, which is the half of "fitted" that a test
    /// asserting only the constraining axis would miss.
    @Test("a wide route fills the width and stays centred in the height")
    func wideRouteIsWidthLimited() throws {
        let wide = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0.1, longitude: 1),
        ]

        let projected = try #require(project(wide))
        let box = bounds(of: projected.points)

        #expect(abs(box.width - (Self.size.width - Self.inset * 2)) < Self.tolerance)
        #expect(box.height < box.width)
        #expect(abs(box.midX - Self.size.width / 2) < Self.tolerance)
        #expect(abs(box.midY - Self.size.height / 2) < Self.tolerance)
        #expect(abs(box.minX - Self.inset) < Self.tolerance)
    }

    @Test("a tall route fills the height and stays centred in the width")
    func tallRouteIsHeightLimited() throws {
        let tall = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 1, longitude: 0.1),
        ]

        let projected = try #require(project(tall))
        let box = bounds(of: projected.points)

        #expect(abs(box.height - (Self.size.height - Self.inset * 2)) < Self.tolerance)
        #expect(box.width < box.height)
        #expect(abs(box.midX - Self.size.width / 2) < Self.tolerance)
        #expect(abs(box.midY - Self.size.height / 2) < Self.tolerance)
        #expect(abs(box.minY - Self.inset) < Self.tolerance)
    }

    /// Uniform scale, both axes: the point of a fit-to-bounds projection is
    /// that the trail keeps its shape. Two different scales would still fill
    /// the frame and still pass every bound above, while drawing a stretched
    /// route that no longer matches the one on the map.
    @Test("the projection scales both axes by the same factor")
    func aspectRatioIsPreserved() throws {
        let route = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0.25, longitude: 1),
            Coordinate(latitude: 0.1, longitude: 0.4),
        ]

        let projected = try #require(project(route, into: CGSize(width: 200, height: 100)))
        let box = bounds(of: projected.points)

        // The flat projection the fit is derived from, recomputed here rather
        // than taken from the function under test.
        let centreLat = 0.125
        let cosLat = cos(centreLat * .pi / 180)
        let flatWidth = 1 * cosLat
        let flatHeight = 0.25

        #expect(abs(box.width / box.height - flatWidth / flatHeight) < Self.tolerance)
    }

    /// Screen y grows downward and latitude grows north, so the northernmost
    /// fix has to come out with the *smallest* y. Getting this backwards would
    /// draw every trail mirrored, which is exactly the sort of thing that
    /// looks plausible in a 60-point glyph.
    @Test("north is up and east is right")
    func orientationMatchesTheWorld() throws {
        let southWest = Coordinate(latitude: 47.5, longitude: 12.7)
        let northEast = Coordinate(latitude: 47.6, longitude: 12.8)

        let projected = try #require(project([southWest, northEast]))
        let first = try #require(projected.points.first)
        let last = try #require(projected.points.last)

        #expect(last.y < first.y, "the northern fix is nearer the top")
        #expect(last.x > first.x, "the eastern fix is nearer the right")
    }

    @Test("an inset of zero lets the route touch the frame")
    func zeroInsetFillsTheFrame() throws {
        let route = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 1, longitude: 1),
        ]

        let projected = try #require(project(route, inset: 0))
        let box = bounds(of: projected.points)

        #expect(abs(box.minY) < Self.tolerance)
        #expect(abs(box.maxY - Self.size.height) < Self.tolerance)
    }

    /// `availableWidth`/`availableHeight` floor at 1, so an inset larger than
    /// the frame cannot invert the scale and turn the route inside out.
    @Test("an inset wider than the frame still projects a forward route")
    func oversizedInsetDoesNotInvert() throws {
        let route = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 1, longitude: 1),
        ]

        let projected = try #require(project(route, inset: 500))
        let first = try #require(projected.points.first)
        let last = try #require(projected.points.last)

        #expect(last.y < first.y)
        #expect(first.x.isFinite && last.x.isFinite)
    }

    // MARK: - The near-polar floor

    /// `minCosLat` stops a near-polar route from being stretched east-west by
    /// a cosine approaching zero. Two routes with identical spans either side
    /// of the floor must therefore come out congruent — which is a claim about
    /// the floor being applied, not merely about the result being finite.
    @Test("two routes past the cosine floor are projected identically")
    func nearPolarRoutesShareTheFlooredCosine() throws {
        let flooredLatitudes = [89.9, 89.0]
        #expect(
            flooredLatitudes.allSatisfy { cos($0 * .pi / 180) < TrailGlyphView.minCosLat },
            "precondition: both centres are past the floor"
        )

        let projections = try flooredLatitudes.map { centre in
            try #require(
                project([
                    Coordinate(latitude: centre - 0.01, longitude: 0),
                    Coordinate(latitude: centre + 0.01, longitude: 0.05),
                ])
            ).points
        }

        let first = try #require(projections.first)
        let second = try #require(projections.last)
        for (lhs, rhs) in zip(first, second) {
            #expect(abs(lhs.x - rhs.x) < Self.tolerance)
            #expect(abs(lhs.y - rhs.y) < Self.tolerance)
        }
    }

    /// And below the floor the cosine is still live, so the same longitude
    /// span is genuinely narrower further north. Without this, the test above
    /// would pass just as well against a cosine hard-coded to the floor.
    @Test("below the floor the centre latitude still narrows the route")
    func temperateRoutesKeepTheirOwnCosine() throws {
        func aspect(centredAt centre: Double) throws -> Double {
            let projected = try #require(
                project([
                    Coordinate(latitude: centre - 0.05, longitude: 0),
                    Coordinate(latitude: centre + 0.05, longitude: 0.2),
                ])
            )
            let box = bounds(of: projected.points)
            return Double(box.width / box.height)
        }

        #expect(cos(60 * Double.pi / 180) > TrailGlyphView.minCosLat, "precondition: both are below the floor")

        // cos(60°) is exactly half cos(0°), so the same longitude span has to
        // come out exactly half as wide relative to the latitude span.
        let ratio = try aspect(centredAt: 0) / aspect(centredAt: 60)
        #expect(abs(ratio - 2) < 1e-3)
    }

    // MARK: - The live fix

    /// The dot and the line come from one transform, so a fix that repeats a
    /// route coordinate has to land exactly on it. A second transform, or the
    /// same one recomputed from a bounding box that included the fix, would
    /// put the walker a few points off their own trail.
    @Test("a live fix on the route lands on the route")
    func liveFixSharesTheRouteTransform() throws {
        let route = [
            Coordinate(latitude: 47.5, longitude: 12.7),
            Coordinate(latitude: 47.6, longitude: 12.8),
            Coordinate(latitude: 47.55, longitude: 12.9),
        ]

        let projected = try #require(project(route, liveFix: route[1]))
        let fixPoint = try #require(projected.liveFixPoint)

        #expect(abs(fixPoint.x - projected.points[1].x) < Self.tolerance)
        #expect(abs(fixPoint.y - projected.points[1].y) < Self.tolerance)
    }

    /// The fit is computed from the route alone, so a fix off the end of it
    /// projects outside the frame rather than rescaling the trail to include
    /// it. That is the intended behaviour — the trail's shape must not change
    /// because a walker wandered — and it is only safe because `Canvas` clips.
    @Test("a live fix beyond the route projects outside the frame")
    func liveFixOutsideTheRouteIsNotFittedIn() throws {
        let route = [
            Coordinate(latitude: 47.5, longitude: 12.7),
            Coordinate(latitude: 47.6, longitude: 12.8),
        ]
        let strayed = Coordinate(latitude: 47.4, longitude: 12.6)

        let projected = try #require(project(route, liveFix: strayed))
        let fixPoint = try #require(projected.liveFixPoint)
        let box = bounds(of: projected.points)

        #expect(fixPoint.x < box.minX)
        #expect(fixPoint.y > box.maxY)
    }

    @Test("no live fix means no dot")
    func absentLiveFixProjectsToNothing() throws {
        let projected = try #require(
            project([
                Coordinate(latitude: 47.5, longitude: 12.7),
                Coordinate(latitude: 47.6, longitude: 12.8),
            ])
        )

        #expect(projected.liveFixPoint == nil)
    }

    // MARK: - Shape

    @Test("every coordinate is projected, in order")
    func everyCoordinateSurvives() throws {
        let route = (0..<12).map { index in
            Coordinate(latitude: 47.5 + Double(index) * 0.01, longitude: 12.7 + Double(index) * 0.02)
        }

        let projected = try #require(project(route))

        #expect(projected.points.count == route.count)
        // Monotonic in both axes, because the route is: the order the walker
        // walked it is the order the line is drawn in.
        #expect(zip(projected.points, projected.points.dropFirst()).allSatisfy { $0.x < $1.x })
        #expect(zip(projected.points, projected.points.dropFirst()).allSatisfy { $0.y > $1.y })
    }
}
