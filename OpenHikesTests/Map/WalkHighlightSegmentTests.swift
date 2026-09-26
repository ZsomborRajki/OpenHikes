//
//  WalkHighlightSegmentTests.swift
//  OpenHikesTests
//
//  *Show on Map* turns a finished walk's covered distances into stretches of
//  the drawn route, and this is the arithmetic that does it.
//
//  Worth pinning down because what it produces is a claim about where somebody
//  walked, drawn over the trail they were following. Coverage is kept as
//  distances along the route — see ``TrailWalkCoverage`` — and the route is a list
//  of points at whatever spacing the GPS happened to produce, so the two ends
//  of a covered range almost never land on a track point. A stretch that
//  snapped to the nearest one instead would start and stop up to a track
//  point away from where the walk did, which on a sparse recording is a
//  hundred metres of trail drawn as walked that was not.
//
//  The other half is ``WalkHighlight`` itself, whose whole reason for being a
//  reference type is that the map observes ``WalkHighlight/revision`` and
//  reads the segments in the same pass: a clear that did not bump it would
//  leave last selection's stretches drawn over this one's route.
//

import CoreLocation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Walk highlight segments")
struct WalkHighlightSegmentTests {
    /// The ridge fixture is a straight line due north at a constant longitude,
    /// which is what makes an interpolated end checkable: every point on it
    /// shares one longitude, and latitude rises monotonically with distance.
    private let profile = RouteProfile(route: Fixture.ridgeRoute)

    private var routeLength: Double {
        profile.distances.last ?? 0
    }

    // MARK: The ends

    /// The case the interpolation exists for: a range whose ends fall between
    /// track points is drawn from where the walk started, not from the point
    /// before it.
    @Test("a stretch starts and stops where the coverage did")
    func endsAreInterpolatedOntoTheRoute() async throws {
        let lower = routeLength * 0.3
        let upper = routeLength * 0.7
        let segments = await WalkHighlight.segments(covering: [lower...upper], along: profile)

        let stretch = try #require(segments.first)
        let expectedStart = try #require(profile.coordinate(atDistance: lower))
        let expectedEnd = try #require(profile.coordinate(atDistance: upper))
        let drawnStart = try #require(stretch.first)
        let drawnEnd = try #require(stretch.last)

        #expect(drawnStart.latitude.isApproximatelyEqual(to: expectedStart.latitude, absoluteTolerance: 1e-9))
        #expect(drawnEnd.latitude.isApproximatelyEqual(to: expectedEnd.latitude, absoluteTolerance: 1e-9))
        // Interpolated rather than snapped: a fixture point at exactly 30% of
        // a six-point route would make the assertion above pass for free.
        #expect(!profile.distances.contains(lower))
        #expect(!profile.distances.contains(upper))
    }

    /// Everything the range spans travels with it, in route order, so the
    /// polyline follows the trail's bends rather than cutting the corner
    /// between its two ends.
    @Test("every route point inside the range is kept, in order")
    func interiorPointsSurviveInOrder() async throws {
        let segments = await WalkHighlight.segments(
            covering: [0...routeLength],
            along: profile
        )
        let stretch = try #require(segments.first)

        // The whole route, drawn once. Both interpolated ends land exactly on
        // the route's own first and last points — `coordinate(atDistance:)`
        // clamps outside the track — and the interior contributes everything
        // between them, so a whole-route range is the route and no more.
        #expect(stretch.count == profile.coordinates.count)
        let first = try #require(stretch.first)
        let last = try #require(stretch.last)
        #expect(first.latitude == profile.coordinates.first?.latitude)
        #expect(last.latitude == profile.coordinates.last?.latitude)

        let latitudes = stretch.map(\.latitude)
        #expect(latitudes == latitudes.sorted(), "the ridge climbs north throughout")
    }

    /// Several ranges are several polylines rather than one joined through
    /// the gap: the gap is trail the walk did not cover.
    @Test("each covered range becomes its own stretch")
    func rangesStaySeparate() async throws {
        let segments = await WalkHighlight.segments(
            covering: [0...(routeLength * 0.2), (routeLength * 0.8)...routeLength],
            along: profile
        )

        #expect(segments.count == 2)
        let firstEnd = try #require(segments.first?.last)
        let secondStart = try #require(segments.last?.first)
        #expect(firstEnd.latitude < secondStart.latitude)
    }

    // MARK: What is not drawn

    /// A range with no length is a coverage entry for a hiker who stopped,
    /// and there is nothing to draw for it. Dropped rather than emitted as a
    /// one-point polyline, which MapKit renders as nothing anyway while still
    /// costing an overlay.
    @Test("an empty range draws nothing")
    func zeroLengthRangesAreDropped() async {
        let point = routeLength / 2
        let segments = await WalkHighlight.segments(covering: [point...point], along: profile)
        #expect(segments.isEmpty)
    }

    /// The degenerate route, which reaches here whenever a walk is shown
    /// against a hike whose track never loaded.
    @Test("a route with no points draws nothing")
    func emptyProfileDrawsNothing() async {
        let empty = RouteProfile(route: [])
        let segments = await WalkHighlight.segments(covering: [0...100], along: empty)
        #expect(segments.isEmpty)
    }

    @Test("no coverage draws nothing")
    func noRangesDrawNothing() async {
        let segments = await WalkHighlight.segments(covering: [], along: profile)
        #expect(segments.isEmpty)
    }

    // MARK: The revision the map watches

    @Test("showing stretches bumps the revision the map observes")
    @MainActor
    func showingBumpsRevision() async {
        let highlight = WalkHighlight()
        let segments = await WalkHighlight.segments(
            covering: [0...(routeLength / 2)],
            along: profile
        )

        highlight.show(segments)

        #expect(highlight.revision == 1)
        #expect(highlight.segments.count == segments.count)
    }

    /// Clearing has to wake the map for the same reason showing does — a
    /// selection change leaves the previous hike's stretches drawn otherwise.
    @Test("clearing drawn stretches bumps the revision")
    @MainActor
    func clearingBumpsRevision() async {
        let highlight = WalkHighlight()
        highlight.show(await WalkHighlight.segments(covering: [0...routeLength], along: profile))

        highlight.clear()

        #expect(highlight.segments.isEmpty)
        #expect(highlight.revision == 2)
    }

    /// And clearing what is already clear must not, which is the guard that
    /// keeps a selection change from waking the map for nothing.
    @Test("clearing nothing leaves the map alone")
    @MainActor
    func clearingWhenEmptyIsInert() {
        let highlight = WalkHighlight()
        highlight.clear()
        #expect(highlight.revision == 0)
    }
}
